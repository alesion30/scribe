import Foundation

/// Information about a downloaded whisper model.
struct ModelInfo {
    let name: String
    let size: UInt64
    let path: String

    /// Human-readable file size string.
    var formattedSize: String {
        ModelManager.formatBytes(size)
    }
}

/// Manages whisper model files: download, list, and remove.
enum ModelManager {

    // MARK: - Path Resolution

    /// Resolve a model name or path to an absolute file path.
    /// If the input starts with `/` or `~`, treat it as a direct path.
    /// Otherwise, look for it in the models directory as {name}.bin.
    static func resolveModelPath(_ nameOrPath: String) -> String {
        if nameOrPath.hasPrefix("/") {
            return nameOrPath
        }
        if nameOrPath.hasPrefix("~") {
            return (nameOrPath as NSString).expandingTildeInPath
        }
        let name = nameOrPath.hasSuffix(".bin") ? String(nameOrPath.dropLast(4)) : nameOrPath
        return (ScribeConfig.modelsDir as NSString).appendingPathComponent("\(name).bin")
    }

    // MARK: - Known Models

    /// Standard whisper.cpp models downloadable by name alone, with approximate sizes.
    static let knownModels: [(name: String, approxSize: String)] = [
        ("tiny", "74 MB"),
        ("base", "141 MB"),
        ("small", "465 MB"),
        ("medium", "1.4 GB"),
        ("large-v3-turbo", "1.5 GB"),
        ("large-v3", "2.9 GB")
    ]

    /// Silero VAD for skipping silence, kept out of the model lists since it cannot transcribe.
    static let vadModel = (name: "silero-v5.1.2", approxSize: "865 KB")

    /// Download URL for a known model name, or nil if the name is not a standard model.
    static func knownModelURL(for name: String) -> URL? {
        if name == vadModel.name {
            return URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-\(name).bin")
        }
        guard knownModels.contains(where: { $0.name == name }) else { return nil }
        return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")
    }

    /// Approximate download size for a known model name.
    private static func knownModelSize(for name: String) -> String? {
        if name == vadModel.name { return vadModel.approxSize }
        return knownModels.first { $0.name == name }?.approxSize
    }

    /// Resolve a model to a local file path, downloading known models that are missing.
    /// Prompts for confirmation when stdin is a terminal.
    ///
    /// - Parameter isCancelled: polled while downloading, so Ctrl+C ends a fetch that would
    ///   otherwise have to be waited out. Throws `RunAborted` when it says so.
    static func ensureModel(_ nameOrPath: String, isCancelled: (@Sendable () -> Bool)? = nil) async throws -> String {
        let path = resolveModelPath(nameOrPath)
        if FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard let url = knownModelURL(for: nameOrPath) else {
            throw ModelManagerError.modelFileMissing(nameOrPath, path)
        }

        let size = knownModelSize(for: nameOrPath) ?? "?"
        if isatty(STDIN_FILENO) != 0 {
            FileHandle.standardError.write(Data("Model '\(nameOrPath)' is not downloaded (\(size)). Download now? [Y/n] ".utf8))
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if answer == "n" || answer == "no" {
                throw ModelManagerError.downloadDeclined(nameOrPath)
            }
        } else {
            Log.status("Model '\(nameOrPath)' is not downloaded (\(size)). Downloading...")
        }

        try await download(name: nameOrPath, url: url, isCancelled: isCancelled)
        return path
    }

    // MARK: - Download

    /// Download a model from the given URL and save it to the models directory.
    ///
    /// - Parameter isCancelled: see `ensureModel(_:isCancelled:)`.
    static func download(name: String, url: URL, isCancelled: (@Sendable () -> Bool)? = nil) async throws {
        let fm = FileManager.default
        let modelsDir = ScribeConfig.modelsDir

        if !fm.fileExists(atPath: modelsDir) {
            Log.debug("Creating models directory: \(modelsDir)")
            try fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        }

        let destPath = (modelsDir as NSString).appendingPathComponent("\(name).bin")

        if fm.fileExists(atPath: destPath) {
            Log.warning("Model '\(name)' already exists at \(destPath), overwriting")
            try fm.removeItem(atPath: destPath)
        }

        Log.status("Downloading model '\(name)' from \(url.absoluteString)")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)

        let totalBytes = (response as? HTTPURLResponse)
            .flatMap { Int64($0.value(forHTTPHeaderField: "Content-Length") ?? "") }

        let tempPath = destPath + ".download"
        fm.createFile(atPath: tempPath, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        defer { try? fileHandle.close() }

        var downloadedBytes: Int64 = 0
        let bufferSize = 256 * 1024
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                // Checked per buffer rather than per byte: still well inside a second, and a
                // multi-gigabyte fetch is the longest thing Ctrl+C has to get out of.
                if isCancelled?() == true {
                    eprintln("")
                    try? fm.removeItem(atPath: tempPath)
                    throw RunAborted()
                }

                fileHandle.write(buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if let total = totalBytes, total > 0 {
                    let pct = Double(downloadedBytes) / Double(total) * 100.0
                    Log.progress("Downloading \(name): \(formatBytes(UInt64(downloadedBytes)))/\(formatBytes(UInt64(total))) (\(String(format: "%.1f", pct))%)")
                } else {
                    Log.progress("Downloading \(name): \(formatBytes(UInt64(downloadedBytes)))")
                }
            }
        }

        if !buffer.isEmpty {
            fileHandle.write(buffer)
            downloadedBytes += Int64(buffer.count)
        }

        try fileHandle.close()
        try fm.moveItem(atPath: tempPath, toPath: destPath)

        // Print newline after progress overwrites
        FileHandle.standardError.write(Data("\n".utf8))
        Log.status("Model '\(name)' downloaded to \(destPath) (\(formatBytes(UInt64(downloadedBytes))))")
    }

    // MARK: - List

    /// List all downloaded models in the models directory.
    static func list() throws -> [ModelInfo] {
        let fm = FileManager.default
        let modelsDir = ScribeConfig.modelsDir

        guard fm.fileExists(atPath: modelsDir) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(atPath: modelsDir)
        return contents
            .filter { $0.hasSuffix(".bin") && $0 != "\(vadModel.name).bin" }
            .sorted()
            .compactMap { filename -> ModelInfo? in
                let path = (modelsDir as NSString).appendingPathComponent(filename)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64 else {
                    return nil
                }
                let name = String(filename.dropLast(4)) // remove .bin
                return ModelInfo(name: name, size: size, path: path)
            }
    }

    // MARK: - Remove

    /// Remove a downloaded model by name.
    static func remove(name: String) throws {
        let fm = FileManager.default
        let path = (ScribeConfig.modelsDir as NSString).appendingPathComponent("\(name).bin")

        guard fm.fileExists(atPath: path) else {
            throw ModelManagerError.modelNotFound(name)
        }

        try fm.removeItem(atPath: path)
        Log.status("Removed model '\(name)'")
    }

    // MARK: - Helpers

    /// Format a byte count into a human-readable string.
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

enum ModelManagerError: LocalizedError {
    case modelNotFound(String)
    case modelFileMissing(String, String)
    case downloadDeclined(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Model '\(name)' not found in \(ScribeConfig.modelsDir)"
        case .modelFileMissing(let name, let path):
            let known = ModelManager.knownModels.map(\.name).joined(separator: ", ")
            return """
                Model '\(name)' not found at \(path)
                Standard models (\(known)) can be downloaded with: scribe model download <name>
                For other models, specify a URL: scribe model download \(name) -u <url>
                """
        case .downloadDeclined(let name):
            return "Download declined. Download it later with: scribe model download \(name)"
        }
    }
}

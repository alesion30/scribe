@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Accelerate

/// Captures microphone (via AVAudioEngine) and/or system audio (via ScreenCaptureKit).
///
/// Microphone capture deliberately does NOT go through ScreenCaptureKit:
/// running a display-scoped SCStream blocks other apps (e.g. Google Meet)
/// from initiating screen sharing while scribe is recording. By isolating
/// mic capture to AVAudioEngine, mic-only sessions touch ScreenCaptureKit
/// not at all, and mic+system sessions only run an audio-only SCStream.
///
/// Samples are streamed to one WAV per source as they arrive, so memory stays
/// flat and a crash leaves everything recorded so far on disk.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let captureMic: Bool
    let captureSystem: Bool

    /// How long to wait for ScreenCaptureKit to answer before giving up on system audio.
    static let shareableContentTimeout: Duration = .seconds(10)

    private let paths: RecordingPaths

    // ScreenCaptureKit — system audio only
    private var stream: SCStream?
    private var systemRecorder: SourceRecorder?
    private var sourceSampleRate: Double = 48000
    private var didWarnSampleRateMismatch = false

    // AVAudioEngine — microphone
    private var audioEngine: AVAudioEngine?
    private var micRecorder: SourceRecorder?

    private var continuation: CheckedContinuation<Void, any Error>?

    init(captureMic: Bool = true, captureSystem: Bool = true, paths: RecordingPaths) {
        self.captureMic = captureMic
        self.captureSystem = captureSystem
        self.paths = paths
        super.init()
    }

    // MARK: - Public API

    /// Start capturing audio. Suspends until stopCapture() is called.
    ///
    /// - Parameter onStarted: called once every requested source is live, so the caller
    ///   only claims to be recording after setup actually succeeded.
    func startCapture(onStarted: () -> Void = {}) async throws {
        Log.info("Starting audio capture (mic: \(captureMic), system: \(captureSystem))")

        if captureMic {
            try startMicrophoneCapture()
        }

        if captureSystem {
            try await startSystemAudioCapture()
        }

        onStarted()

        // Suspend until stopCapture() resumes the continuation
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.continuation = cont
        }
    }

    /// Stop capturing and close the per-source recordings.
    func stopCapture() -> CaptureResult {
        Log.info("Stopping audio capture...")

        // Stop microphone (AVAudioEngine)
        if let engine = self.audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.audioEngine = nil

        // Stop system audio stream (ScreenCaptureKit)
        if let stream = self.stream {
            // Fire and forget the async stop - samples are already captured
            let streamToStop = stream
            Task { @Sendable in
                do {
                    try await streamToStop.stopCapture()
                } catch {
                    Log.warning("Error stopping stream: \(error.localizedDescription)")
                }
            }
        }
        self.stream = nil

        // Resume the continuation so startCapture() returns
        continuation?.resume()
        continuation = nil

        let mic = micRecorder?.finish()
        let system = systemRecorder?.finish()
        micRecorder = nil
        systemRecorder = nil

        return CaptureResult(mic: mic, system: system)
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw AudioCaptureError.invalidMicrophoneFormat
        }

        let channelCount = Int(format.channelCount)
        Log.debug("Microphone format: \(format.sampleRate) Hz, \(channelCount) channel(s)")

        let recorder = try SourceRecorder(
            label: "Mic",
            path: paths.mic,
            sampleRate: format.sampleRate,
            channels: channelCount
        )
        self.micRecorder = recorder

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handleMicBuffer(buffer, at: time)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recorder.discard()
            self.micRecorder = nil
            handleMicrophonePermissionError(error)
            throw error
        }

        self.audioEngine = engine
        Log.info("Microphone capture started (AVAudioEngine)")
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameCount > 0, channels > 0 else { return }

        let samples: [Float]
        if channels == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            // Interleave (L,R,L,R,...) so the resampler can deinterleave.
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for ch in 0..<channels {
                let src = channelData[ch]
                for frame in 0..<frameCount {
                    interleaved[frame * channels + ch] = src[frame]
                }
            }
            samples = interleaved
        }

        let startSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
        micRecorder?.append(samples, startingAt: startSeconds)
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        // Asking ScreenCaptureKit without the grant shows the prompt and then hangs, so check first.
        guard CGPreflightScreenCaptureAccess() else {
            // Puts scribe's terminal in the settings list even if the prompt is dismissed.
            CGRequestScreenCaptureAccess()
            throw AudioCaptureError.screenRecordingPermissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await Self.shareableContent(timeout: Self.shareableContentTimeout)
        } catch {
            handlePermissionError(error)
            throw error
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        Log.debug("Using display: \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        // Mic is captured via AVAudioEngine — keep ScreenCaptureKit audio-only.
        config.captureMicrophone = false

        config.sampleRate = 48000
        sourceSampleRate = 48000
        Log.debug("System audio sample rate: \(sourceSampleRate) Hz")

        // We don't need video
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum

        let recorder = try SourceRecorder(
            label: "System",
            path: paths.system,
            sampleRate: sourceSampleRate,
            channels: Int(config.channelCount)
        )
        self.systemRecorder = recorder

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = captureStream

        let queue = DispatchQueue(label: "com.scribe.audio-capture", qos: .userInitiated)
        do {
            try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            Log.debug("Added system audio output")
            try await captureStream.startCapture()
        } catch {
            self.stream = nil
            recorder.discard()
            self.systemRecorder = nil
            handlePermissionError(error)
            throw error
        }

        Log.info("System audio capture started (ScreenCaptureKit)")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        // Mic comes from AVAudioEngine; only system audio flows through SCStream now.
        guard type == .audio else { return }

        guard let samples = AudioWriter.extractSamples(from: sampleBuffer) else { return }

        // The resampler is built for the configured rate, so a mismatch would skew playback speed.
        if !didWarnSampleRateMismatch,
           let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
           asbd.pointee.mSampleRate != sourceSampleRate {
            didWarnSampleRateMismatch = true
            Log.warning("System audio arrived at \(asbd.pointee.mSampleRate) Hz, expected \(sourceSampleRate) Hz")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startSeconds = pts.isValid
            ? AVAudioTime.seconds(forHostTime: CMClockConvertHostTimeToSystemUnits(pts))
            : nil
        systemRecorder?.append(samples, startingAt: startSeconds)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.error("Stream stopped with error: \(error.localizedDescription)")
        handlePermissionError(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - Private

    /// Ask ScreenCaptureKit for the displays, giving up after `timeout`.
    ///
    /// Only displays are needed, so the window list is kept as small as possible:
    /// enumerating every off-screen window can take well over ten seconds on a busy Mac.
    private static func shareableContent(timeout: Duration) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AudioCaptureError.screenRecordingUnavailable
            }

            guard let content = try await group.next() else {
                throw AudioCaptureError.screenRecordingUnavailable
            }
            group.cancelAll()
            return content
        }
    }

    private func handlePermissionError(_ error: any Error) {
        // Our own errors already spell out the fix; this is for ScreenCaptureKit's opaque ones.
        guard !(error is AudioCaptureError) else { return }

        let nsError = error as NSError
        // SCStream permission errors are typically in the SCStreamError domain
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" ||
           nsError.localizedDescription.lowercased().contains("permission") ||
           nsError.code == -3801 {
            Log.error("Screen recording permission denied.")
            Log.status("To grant permission, open:")
            Log.status("  System Settings > Privacy & Security > Screen & System Audio Recording")
            Log.status("Then enable access for your terminal application (e.g., Terminal, iTerm2).")
        }
    }

    private func handleMicrophonePermissionError(_ error: any Error) {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("permission") || description.contains("microphone") || nsError.code == 561017449 {
            Log.error("Microphone permission denied.")
            Log.status("To grant permission, open:")
            Log.status("  System Settings > Privacy & Security > Microphone")
            Log.status("Then enable access for your terminal application (e.g., Terminal, iTerm2).")
        }
    }
}

// MARK: - Source Recorder

/// Resamples one capture source to 16 kHz mono and streams it to its own WAV.
///
/// Conversion and file I/O run on a private queue, so the audio callbacks only
/// copy their buffer and return and a slow disk can't stall capture.
final class SourceRecorder: @unchecked Sendable {
    let label: String
    let path: String

    private let queue: DispatchQueue
    private let resampler: StreamingResampler
    private let writer: StreamingWAVWriter

    // Running levels, so the mix gains can be chosen without re-reading the file.
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var levels = LevelMeter()

    private var timeline = CaptureTimeline()
    private var silenceFilled = 0

    private var writeFailure: (any Error)?
    private var lastLoggedSampleCount = 0

    init(label: String, path: String, sampleRate: Double, channels: Int) throws {
        guard let resampler = StreamingResampler(sampleRate: sampleRate, channels: channels) else {
            throw AudioCaptureError.unsupportedSourceFormat(label)
        }

        self.label = label
        self.path = path
        self.resampler = resampler
        self.writer = try StreamingWAVWriter(path: path)
        self.queue = DispatchQueue(label: "com.scribe.recorder.\(label.lowercased())", qos: .userInitiated)

        Log.debug("\(label) recording to \(path) (\(sampleRate) Hz, \(channels)ch -> 16 kHz mono)")
    }

    /// Hand off one interleaved buffer, stamped with the host-clock instant of its first frame.
    func append(_ interleaved: [Float], startingAt hostSeconds: Double? = nil) {
        guard !interleaved.isEmpty else { return }
        queue.async { [self] in process(interleaved, startingAt: hostSeconds) }
    }

    /// Drain pending writes, close the file, and report what was captured.
    func finish() -> CapturedSource? {
        queue.sync {}

        do {
            try writer.finalize()
        } catch {
            Log.error("Failed to finalize \(label) recording: \(error.localizedDescription)")
        }

        levels.finalize()

        let count = writer.sampleCount
        guard count > 0 else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        let duration = Double(count) / AudioWriter.sampleRate
        Log.debug("\(label) captured: \(count) samples (\(String(format: "%.1f", duration))s)")

        if silenceFilled > 0 {
            let seconds = Double(silenceFilled) / AudioWriter.sampleRate
            Log.debug("\(label) capture dropped \(String(format: "%.2f", seconds))s, filled with silence")
        }

        return CapturedSource(
            path: path,
            sampleCount: count,
            peak: peak,
            rms: Float((sumSquares / Double(count)).squareRoot()),
            activeLevel: levels.activeLevel,
            startSeconds: timeline.startSeconds
        )
    }

    /// Close and delete the file, for a source that failed to start.
    func discard() {
        queue.sync {}
        try? writer.finalize()
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private

    private func process(_ interleaved: [Float], startingAt hostSeconds: Double?) {
        guard writeFailure == nil else { return }

        // Worked out before resampling so the first buffer sets the origin even if its conversion fails.
        let missing = timeline.silenceNeeded(before: hostSeconds, written: writer.sampleCount)

        guard let resampled = resampler.resample(interleaved), !resampled.isEmpty else { return }

        var chunkPeak: Float = 0
        vDSP_maxmgv(resampled, 1, &chunkPeak, vDSP_Length(resampled.count))
        peak = max(peak, chunkPeak)

        var sumSq: Float = 0
        vDSP_svesq(resampled, 1, &sumSq, vDSP_Length(resampled.count))
        sumSquares += Double(sumSq)

        // Only real samples are metered: the silence filled below stands for audio that never arrived.
        levels.add(resampled)

        do {
            // Restore the hole a dropped buffer left, so what follows stays where the clock says it was.
            if missing > 0 {
                silenceFilled += missing
                try writer.append([Float](repeating: 0, count: missing))
            }
            try writer.append(resampled)
        } catch {
            // Stop writing but keep the file: what already reached disk is still worth having.
            writeFailure = error
            Log.error("\(label) recording stopped writing: \(error.localizedDescription)")
            return
        }

        if writer.sampleCount - lastLoggedSampleCount >= 100000 {
            lastLoggedSampleCount = writer.sampleCount
            Log.debug("\(label) audio: \(writer.sampleCount) samples written")
        }
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case invalidMicrophoneFormat
    case unsupportedSourceFormat(String)
    case screenRecordingPermissionDenied
    case screenRecordingUnavailable

    /// A missing grant surfaces as a denied preflight or no display, so both point at the same fix.
    private static let screenRecordingHelp = """
        Open System Settings > Privacy & Security > Screen & System Audio Recording and enable access \
        for your terminal application (e.g., Terminal, iTerm2), then restart the terminal and run scribe again.
        To record without system audio, pass --no-system.
        """

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return """
                ScreenCaptureKit reported no display, which usually means screen recording permission is missing.
                \(Self.screenRecordingHelp)
                """
        case .invalidMicrophoneFormat:
            return "Microphone returned an invalid audio format (sample rate is 0)"
        case .unsupportedSourceFormat(let label):
            return "\(label) audio format cannot be converted to 16 kHz mono"
        case .screenRecordingPermissionDenied:
            return """
                Screen recording permission is not granted, so system audio cannot be captured.
                \(Self.screenRecordingHelp)
                """
        case .screenRecordingUnavailable:
            return """
                ScreenCaptureKit did not respond in time, so system audio cannot be captured.
                If you just granted screen recording permission, restart the terminal and try again.
                To record without system audio, pass --no-system.
                """
        }
    }
}

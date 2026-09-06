import Foundation
import whisper

enum WhisperError: LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper model from: \(path)"
        case .transcriptionFailed:
            return "Whisper transcription failed"
        }
    }
}

// MARK: - Options

/// Knobs for a transcription run.
struct TranscribeOptions {
    /// Language hint (ISO 639-1) or "auto" to let whisper detect it.
    var language: String = "auto"

    /// Seconds of audio per `whisper_full` call; zero or less feeds the whole recording at once.
    ///
    /// whisper normalizes the spectrogram over its whole input; one loud moment buries the rest.
    var chunkLength: TimeInterval = 600

    /// Seconds of the previous chunk replayed so a word split by a boundary still decodes whole.
    var chunkOverlap: TimeInterval = 2

    /// Path to a Silero VAD model, or nil to feed silence to the decoder as-is.
    var vadModelPath: String?
}

// MARK: - Context

/// Thread-safe whisper.cpp context wrapper.
final class WhisperContext {
    private let context: OpaquePointer

    /// Initialize from a model file path.
    init(modelPath: String) throws {
        var cparams = whisper_context_default_params()
        cparams.flash_attn = true
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.context = ctx
        Log.info("Whisper model loaded from \(modelPath)")
    }

    deinit {
        whisper_free(context)
        Log.debug("Whisper context freed")
    }

    /// Transcribe Float PCM samples (16 kHz mono), emitting each timestamped segment as it is decoded.
    ///
    /// - Parameter isCancelled: polled between chunks and from inside whisper.cpp, so Ctrl+C
    ///   ends a long transcription instead of waiting it out. Throws `RunAborted` when it does.
    func transcribe(
        samples: [Float],
        options: TranscribeOptions = TranscribeOptions(),
        showProgress: Bool = false,
        isCancelled: (() -> Bool)? = nil,
        onSegment: @escaping (TranscriptSegment) -> Void
    ) throws -> [TranscriptSegment] {
        let chunks = Self.chunks(sampleCount: samples.count, options: options)
        if chunks.count > 1 {
            Log.info("Split into \(chunks.count) chunks of \(String(format: "%.0f", options.chunkLength))s")
        }

        let cancel = isCancelled.map { CancelCheck($0) }
        let collector = SegmentCollector(onSegment: onSegment)
        for (index, chunk) in chunks.enumerated() {
            if cancel?.shouldStop() == true {
                throw RunAborted()
            }
            collector.startChunk(
                offset: TimeInterval(chunk.fed.lowerBound) / AudioWriter.sampleRate,
                ownedStart: TimeInterval(chunk.owned.lowerBound) / AudioWriter.sampleRate
            )
            try decode(
                samples: samples,
                range: chunk.fed,
                options: options,
                collector: collector,
                progress: showProgress ? ProgressReporter(chunkIndex: index, chunkCount: chunks.count) : nil,
                cancel: cancel
            )
        }

        if collector.droppedRepeats > 0 {
            Log.debug("Collapsed \(collector.droppedRepeats) repeated segments")
        }
        return collector.segments
    }

    /// Run `whisper_full` over one range of samples, feeding every decoded segment to `collector`.
    private func decode(
        samples: [Float],
        range: Range<Int>,
        options: TranscribeOptions,
        collector: SegmentCollector,
        progress: ProgressReporter?,
        cancel: CancelCheck?
    ) throws {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        params.n_threads = threadCount
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true

        // A loop latches onto non-speech tokens; whisper.cpp leaves them unsuppressed by default
        params.suppress_nst = true

        if progress != nil {
            params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, percent: Int32, userData: UnsafeMutableRawPointer?) in
                guard let userData else { return }
                Unmanaged<ProgressReporter>.fromOpaque(userData).takeUnretainedValue().report(percent)
            }
            params.progress_callback_user_data = progress.map { Unmanaged.passUnretained($0).toOpaque() }
        }

        // whisper.cpp asks before every graph computation, which is the only place a
        // blocking decode can be stopped without killing the process out from under it.
        if let cancel {
            params.abort_callback = { (userData: UnsafeMutableRawPointer?) -> Bool in
                guard let userData else { return false }
                return Unmanaged<CancelCheck>.fromOpaque(userData).takeUnretainedValue().shouldStop()
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(cancel).toOpaque()
        }

        params.new_segment_callback = { (ctx: OpaquePointer?, _: OpaquePointer?, newCount: Int32, userData: UnsafeMutableRawPointer?) in
            guard let ctx, let userData else { return }
            let collector = Unmanaged<SegmentCollector>.fromOpaque(userData).takeUnretainedValue()
            let total = whisper_full_n_segments(ctx)
            for i in max(0, total - newCount)..<total {
                guard let cStr = whisper_full_get_segment_text(ctx, i) else { continue }
                collector.append(
                    TranscriptSegment(
                        start: WhisperContext.seconds(from: whisper_full_get_segment_t0(ctx, i)),
                        end: WhisperContext.seconds(from: whisper_full_get_segment_t1(ctx, i)),
                        text: String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }
        params.new_segment_callback_user_data = Unmanaged.passUnretained(collector).toOpaque()

        let result: Int32 = try withExtendedLifetime((progress, cancel)) {
            // whisper.cpp maps timestamps back to the original audio after dropping silence
            try Self.withOptionalCString(options.vadModelPath) { vadPtr in
                if let vadPtr {
                    params.vad = true
                    params.vad_model_path = vadPtr
                    params.vad_params = whisper_vad_default_params()
                }

                return try options.language.withCString { langPtr in
                    params.language = langPtr

                    return try samples.withUnsafeBufferPointer { bufferPtr in
                        guard let baseAddress = bufferPtr.baseAddress else {
                            throw WhisperError.transcriptionFailed
                        }
                        return whisper_full(context, params, baseAddress + range.lowerBound, Int32(range.count))
                    }
                }
            }
        }

        // Checked before the return code: an aborted decode reports failure, and it isn't one.
        if cancel?.shouldStop() == true {
            throw RunAborted()
        }

        if result != 0 {
            throw WhisperError.transcriptionFailed
        }
    }

    // MARK: - Chunking

    /// One `whisper_full` call: the samples it decodes and the span it is responsible for.
    struct Chunk: Equatable {
        /// Samples handed to whisper, including the lead-in borrowed from the previous chunk.
        let fed: Range<Int>
        /// Samples this chunk owns; the lead-in belongs to its predecessor.
        let owned: Range<Int>
    }

    static func chunks(sampleCount: Int, options: TranscribeOptions) -> [Chunk] {
        let step = Int((options.chunkLength * AudioWriter.sampleRate).rounded())
        guard step > 0, sampleCount > step else {
            return [Chunk(fed: 0..<sampleCount, owned: 0..<sampleCount)]
        }

        let leadIn = max(0, Int((options.chunkOverlap * AudioWriter.sampleRate).rounded()))
        return stride(from: 0, to: sampleCount, by: step).map { start in
            let owned = start..<min(start + step, sampleCount)
            return Chunk(fed: max(0, start - leadIn)..<owned.upperBound, owned: owned)
        }
    }

    // MARK: - Helpers

    /// `String.withCString` that tolerates nil, so an optional path can be borrowed the same way.
    private static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> R
    ) rethrows -> R {
        guard let string else { return try body(nil) }
        return try string.withCString(body)
    }

    /// whisper reports segment boundaries in centiseconds.
    private static func seconds(from timestamp: Int64) -> TimeInterval {
        TimeInterval(timestamp) / 100.0
    }
}

// MARK: - Segment Collection

/// Bridges whisper.cpp's C segment callback back into Swift, placing each segment in the whole recording.
final class SegmentCollector {
    private let onSegment: (TranscriptSegment) -> Void
    private(set) var segments: [TranscriptSegment] = []

    /// Segments dropped for repeating the line before them.
    private(set) var droppedRepeats = 0

    private var lastText: String?
    private var offset: TimeInterval = 0
    private var ownedStart: TimeInterval = 0

    init(onSegment: @escaping (TranscriptSegment) -> Void) {
        self.onSegment = onSegment
    }

    /// whisper restarts timestamps at zero per chunk, so each chunk declares where it sits.
    func startChunk(offset: TimeInterval, ownedStart: TimeInterval) {
        self.offset = offset
        self.ownedStart = ownedStart
    }

    func append(_ segment: TranscriptSegment) {
        guard !segment.text.isEmpty else { return }

        let start = segment.start + offset
        let end = segment.end + offset

        // Assign by midpoint so the lead-in never emits the same line twice
        guard (start + end) / 2 >= ownedStart else { return }

        // whisper loops on audio it cannot resolve; the first occurrence still marks the stretch
        guard segment.text != lastText else {
            droppedRepeats += 1
            return
        }
        lastText = segment.text

        let placed = TranscriptSegment(start: start, end: end, text: segment.text)
        segments.append(placed)
        onSegment(placed)
    }
}

/// Carries the cancel check into the abort callback, a C function pointer that cannot capture.
final class CancelCheck {
    private let isCancelled: () -> Bool

    init(_ isCancelled: @escaping () -> Bool) {
        self.isCancelled = isCancelled
    }

    func shouldStop() -> Bool {
        isCancelled()
    }
}

/// Carries chunk position into the progress callback, a C function pointer that cannot capture.
private final class ProgressReporter {
    private let chunkIndex: Int
    private let chunkCount: Int

    init(chunkIndex: Int, chunkCount: Int) {
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }

    func report(_ percent: Int32) {
        if chunkCount > 1 {
            Log.progress("Transcribing chunk \(chunkIndex + 1)/\(chunkCount)... \(percent)%")
        } else {
            Log.progress("Transcribing... \(percent)%")
        }
    }
}

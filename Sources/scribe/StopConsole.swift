import Foundation

// MARK: - Prompt

/// What a keystroke means to a running recording.
enum StopAction: Equatable {
    /// The key means nothing here; the session is unchanged.
    case ignore
    /// Ask whether to stop. The recording keeps running while the question stands.
    case confirm
    /// Take the question back down and carry on recording.
    case resume
    /// Stop recording and move on to whatever comes after it.
    case stop
    /// End the whole run now.
    case abort
}

/// Decides what each key does while a recording runs.
///
/// `q` only asks. Recording continues until `y` confirms, so a key hit by accident
/// costs nothing: `n` or Esc puts the session straight back. Ctrl+C skips the question,
/// because someone reaching for it wants out of the run, not a dialogue about it.
struct StopPrompt {
    private enum Key {
        static let quit: UInt8 = 0x71      // q
        static let yes: UInt8 = 0x79       // y
        static let no: UInt8 = 0x6E        // n
        static let escape: UInt8 = 0x1B
        /// Ctrl+C, for input that arrives as a byte instead of a signal.
        static let interrupt: UInt8 = 0x03
    }

    /// True while the confirmation question is on screen.
    private(set) var isConfirming = false

    mutating func handle(_ key: UInt8) -> StopAction {
        if key == Key.interrupt {
            isConfirming = false
            return .abort
        }

        // Caps lock shouldn't change what a key means.
        let normalized = Self.lowercased(key)

        guard isConfirming else {
            guard normalized == Key.quit else { return .ignore }
            isConfirming = true
            return .confirm
        }

        switch normalized {
        case Key.yes:
            isConfirming = false
            return .stop
        case Key.no, Key.escape:
            isConfirming = false
            return .resume
        default:
            return .ignore
        }
    }

    private static func lowercased(_ key: UInt8) -> UInt8 {
        (0x41...0x5A).contains(key) ? key + 0x20 : key
    }
}

// MARK: - Terminal seam

/// The terminal work the stop console needs.
///
/// Behind a protocol so the console's own bookkeeping — above all, that it puts the
/// terminal back on every path out, including the ones that throw — can be tested
/// without a terminal to put back.
protocol TerminalOperations: AnyObject {
    /// False when the input isn't a terminal and the stop key could never be typed.
    var isTerminal: Bool { get }

    /// Switch to unbuffered, unechoed input. Throws if the terminal refuses.
    func enterSingleKeyMode() throws

    /// Start delivering keystrokes. `onEnd` fires if the input closes for good.
    func startReading(
        onKeys: @escaping @Sendable ([UInt8]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    )

    /// Stop reading and put back everything `enterSingleKeyMode` changed. Idempotent,
    /// and a no-op if that never got as far as changing anything.
    func restore()
}

/// `TerminalOperations` on a real file descriptor.
final class PosixTerminal: TerminalOperations, @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.scribe.stop-console")

    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    private var isRestored = false

    // Nil until captured, so nothing is ever "restored" onto a terminal that was
    // never changed: pushing a zeroed termios would wreck a working terminal.
    private var originalAttributes: termios?
    private var originalFlags: Int32?

    init(descriptor: Int32 = STDIN_FILENO) {
        self.descriptor = descriptor
    }

    deinit {
        restore()
    }

    var isTerminal: Bool {
        isatty(descriptor) == 1
    }

    /// Every change to the descriptor is made under `lock`, here, in `restore()` and in the
    /// read below, so the three can never overlap on it.
    func enterSingleKeyMode() throws {
        lock.lock()
        defer { lock.unlock() }

        // Nothing to take over: the console is already done with this terminal.
        guard !isRestored else { return }

        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else {
            throw StopConsoleError.rawModeUnavailable(Self.errnoDescription())
        }

        // Drop line buffering and echo so one keypress is a whole answer and typing it
        // doesn't scribble over the status lines. ISIG stays on: Ctrl+C has to keep being
        // a signal so it also ends the model load and the transcription that follow,
        // where no one is reading keys.
        var raw = attributes
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        guard tcsetattr(descriptor, TCSANOW, &raw) == 0 else {
            throw StopConsoleError.rawModeUnavailable(Self.errnoDescription())
        }
        originalAttributes = attributes

        // Non-blocking on top of that, so read() can never park the reader with a
        // recording running. That is what makes VMIN/VTIME irrelevant here, so a
        // terminal that refuses it is refused back rather than risked.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw StopConsoleError.rawModeUnavailable(Self.errnoDescription())
        }
        originalFlags = flags
    }

    func startReading(
        onKeys: @escaping @Sendable ([UInt8]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        let reading = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reading.setEventHandler { [weak self] in
            guard let self else { return }
            guard let keys = self.readAvailable() else {
                onEnd()
                return
            }
            guard !keys.isEmpty else { return }
            onKeys(keys)
        }

        lock.lock()
        let stopped = isRestored
        if !stopped {
            source = reading
        }
        lock.unlock()

        guard !stopped else { return }
        reading.resume()
    }

    func restore() {
        lock.lock()
        guard !isRestored else {
            lock.unlock()
            return
        }
        isRestored = true
        let reading = source
        source = nil

        // Put the descriptor back while the lock is held. cancel() below doesn't wait for a
        // read handler already in flight, and that read is inside this same lock: it either
        // ran while the descriptor was still non-blocking, or it sees the flag and doesn't
        // read at all. Restoring outside the lock leaves a third way — a read that starts on
        // a descriptor just put back to blocking, and parks on the user's next command.
        if let flags = originalFlags {
            _ = fcntl(descriptor, F_SETFL, flags)
        }
        if var attributes = originalAttributes {
            _ = tcsetattr(descriptor, TCSANOW, &attributes)
        }
        lock.unlock()

        reading?.cancel()
    }

    // MARK: - Private

    /// Read what is waiting. Nil means the input is closed for good.
    ///
    /// The lock is held across the read, not just the check before it, so `restore()` cannot
    /// take the descriptor back to blocking underneath one.
    private func readAvailable() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }

        // Nothing typed after the stop matters, and by then reads block again.
        guard !isRestored else { return [] }

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }

        if count < 0 {
            // The source only fires on readable data, so this is a hiccup, not a closed input.
            if errno != EAGAIN && errno != EINTR {
                Log.warning("Could not read the stop key: \(Self.errnoDescription())")
            }
            return []
        }

        guard count > 0 else { return nil }
        return Array(buffer.prefix(count))
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - Console

/// Reads the stop key from the terminal while a recording runs.
///
/// stdin is switched to single-key input so one keypress is a whole answer, and switched
/// back when the recording ends. Ctrl+C is deliberately left to the terminal's own signal
/// handling: it has to end the run from anywhere, including the transcription that
/// follows, where nothing is reading keys.
final class StopConsole: @unchecked Sendable {
    /// Shown once every requested source is live.
    static let recordingHint = "Recording... Press q to stop, Ctrl+C to abort."
    /// Shown while the confirmation stands. Recording continues underneath it.
    static let confirmHint = "Stop recording? Press y to stop, n or Esc to keep recording."
    /// Shown when the confirmation is dismissed.
    static let resumedHint = "Still recording... Press q to stop, Ctrl+C to abort."

    private let stopSignal: StopSignal
    private let terminal: any TerminalOperations
    private let announce: (String) -> Void

    private let lock = NSLock()
    private var prompt = StopPrompt()

    /// Take over the terminal on stdin and start reading.
    convenience init(stopSignal: StopSignal, input: Int32 = STDIN_FILENO) throws {
        try self.init(stopSignal: stopSignal, terminal: PosixTerminal(descriptor: input))
    }

    /// Throws when there is no terminal to take over, so a recording that could never
    /// be stopped from the keyboard is refused before it captures anything.
    init(
        stopSignal: StopSignal,
        terminal: any TerminalOperations,
        announce: @escaping (String) -> Void = { Log.status($0) }
    ) throws {
        self.stopSignal = stopSignal
        self.terminal = terminal
        self.announce = announce

        guard terminal.isTerminal else { throw StopConsoleError.notATerminal }

        do {
            try terminal.enterSingleKeyMode()
        } catch {
            // Half of the switch may have gone through before it gave up.
            terminal.restore()
            throw error
        }

        terminal.startReading(
            onKeys: { [weak self] keys in self?.receive(keys) },
            onEnd: { [weak self] in self?.endOfInput() }
        )
    }

    /// Backstop for a path that drops the console without stopping it: a terminal left
    /// in single-key mode would follow the user into their next command.
    deinit {
        terminal.restore()
    }

    /// Stop reading and give the terminal back. Safe to call more than once.
    func stop() {
        terminal.restore()
    }

    /// Feed keystrokes through the prompt.
    ///
    /// Internal rather than private so a test can drive the console the way a terminal
    /// would, without needing one.
    func receive(_ keys: [UInt8]) {
        for key in keys {
            lock.lock()
            let action = prompt.handle(key)
            lock.unlock()

            Self.apply(action, to: stopSignal, announce: announce)
        }
    }

    /// Carry out what a key meant.
    ///
    /// Kept off the instance so the decisions can be exercised without a terminal.
    static func apply(
        _ action: StopAction,
        to stopSignal: StopSignal,
        announce: (String) -> Void = { Log.status($0) }
    ) {
        switch action {
        case .ignore:
            break
        case .confirm:
            announce(confirmHint)
        case .resume:
            announce(resumedHint)
        case .stop:
            stopSignal.signal(.stopped)
        case .abort:
            stopSignal.signal(.aborted)
        }
    }

    // MARK: - Private

    private func endOfInput() {
        // stdin is gone, so q can never arrive. End the run rather than record with no way out.
        Log.warning("Standard input closed; ending the recording.")
        stop()
        stopSignal.signal(.aborted)
    }
}

// MARK: - Errors

enum StopConsoleError: LocalizedError {
    /// stdin isn't a terminal, so the stop key could never be typed.
    case notATerminal
    /// The terminal refused to hand over single-key input.
    case rawModeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notATerminal:
            return """
                Recording needs a terminal on stdin: the stop key (q) is read from it.
                Run scribe from a terminal, or transcribe a file that already exists: scribe transcribe <file>
                """
        case .rawModeUnavailable(let reason):
            return "Could not switch the terminal to single-key input: \(reason)"
        }
    }
}

import Foundation

/// Why a recording session ended.
enum StopReason {
    /// The user pressed q and confirmed with y.
    case stopped
    /// The user pressed Ctrl+C, which ends the whole run rather than just the recording.
    case aborted
    /// Capture could not be started; nothing was recorded.
    case failed(any Error)
}

/// Ctrl+C, on its way up to the command that can exit.
///
/// Carries no message. Whatever the abort left behind — the recording, the segments
/// already written — is reported where it is known, next to the path it names.
struct RunAborted: Error {}

/// One-shot handoff from whichever ends the recording first.
///
/// The signal can arrive from a signal-source handler, from the key reader, or from
/// the capture task, possibly before anyone is waiting, so the reason is held until it
/// is collected. Later signals are dropped: the first one is what stopped the recording.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StopReason, Never>?
    private var pending: StopReason?
    private var isSignalled = false

    /// Whether the session already has its reason, collected or not.
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }

    func signal(_ reason: StopReason) {
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true

        let waiting = continuation
        continuation = nil
        if waiting == nil {
            pending = reason
        }
        lock.unlock()

        waiting?.resume(returning: reason)
    }

    func wait() async -> StopReason {
        await withCheckedContinuation { (cont: CheckedContinuation<StopReason, Never>) in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                cont.resume(returning: pending)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

/// Holds SIGINT for as long as the run needs it, and gives it back exactly once.
///
/// Ordering matters more than it looks. The terminal is switched to single-key input
/// while this is installed, so a SIGINT still on its default action in between would
/// kill the process and leave the terminal that way for the next command. Install this
/// first, release it last.
final class InterruptGuard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.scribe.interrupt")
    private let source: any DispatchSourceSignal

    private let lock = NSLock()
    private var isReleased = false

    init(onInterrupt: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        source.setEventHandler(handler: onInterrupt)
        self.source = source

        // Take the default action off first: the source only ever sees signals the
        // process no longer dies on.
        signal(SIGINT, SIG_IGN)
        source.resume()
    }

    deinit {
        release()
    }

    /// Give SIGINT back to its default action. Safe to call more than once.
    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()

        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}

/// A raise-once cancel flag, set from a signal handler and polled from inside whisper.cpp.
///
/// Transcription is one blocking C call, so it cannot be ended by cancelling a task.
/// It has to be asked, between graph computations, whether it should still be running.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}

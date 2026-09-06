import Foundation

/// The start → run → stop lifecycle of a capture session, held apart from the frameworks
/// that do the capturing so what start and stop agree on can be tested without a microphone.
///
/// A stop can land while the session is still coming up: the ScreenCaptureKit wait alone is
/// ten seconds long, and Ctrl+C during it is exactly the case. Both ends meet on the one lock
/// here, so a stop is never the one that arrived too early to count:
///
/// - a stop before startup finishes is latched, so startup hands nothing else over and takes
///   back down what it already brought up — stop looked for it and found nothing
/// - a stop after startup finishes resumes the waiter, so the session ends rather than parking
///   on a continuation with nobody left to resume it
final class CaptureLifecycle: @unchecked Sendable {
    private enum State {
        case idle
        case starting
        case running
        case stopped
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var continuation: CheckedContinuation<Void, any Error>?

    /// Whether the session is over, however far it had got.
    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .stopped
    }

    /// Claim the right to bring sources up.
    ///
    /// False when the session is already past its start — stopped before it began, or started
    /// once already. Either way there is nothing to bring up.
    func beginStartup() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { return false }
        state = .starting
        return true
    }

    /// Hand a source that just came up to the session, `install` running under the lock so a
    /// stop cannot see half of it.
    ///
    /// False once the session is stopped, and then that source is the caller's to tear down:
    /// stop has already read the fields `install` would have set.
    func publish(_ install: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .starting else { return false }
        install()
        return true
    }

    /// Read what the capture callbacks share with start and stop.
    func withSession<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Declare every requested source live. False when a stop got in first, and then the
    /// session never was running and must not be announced as such.
    func beginRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .starting else { return false }
        state = .running
        return true
    }

    /// Suspend until the session is stopped.
    ///
    /// Returns straight away when the stop already landed: it found no continuation to resume,
    /// so suspending now would be suspending for good.
    func waitForStop() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.lock()
            guard state == .running else {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// End the session, `take` running under the lock to collect what has to be torn down.
    ///
    /// `take` runs on the first stop only, so whoever gets it owns the teardown; later stops
    /// find the session already over. True when this call is the one that ended it.
    @discardableResult
    func stop(_ take: () -> Void = {}) -> Bool {
        lock.lock()
        let wasStopped = state == .stopped
        state = .stopped
        if !wasStopped {
            take()
        }
        let waiting = continuation
        continuation = nil
        lock.unlock()

        waiting?.resume()
        return !wasStopped
    }

    /// End the session with the error that ended the capture, for whoever is waiting on it.
    ///
    /// A failure before anyone waits is dropped: startup is still on its way to reporting one
    /// of its own, and that is the one worth having.
    func fail(_ error: any Error) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()

        waiting?.resume(throwing: error)
    }
}

import Foundation
import Testing
@testable import scribe

/// Tests for what starting and stopping a capture session agree on.
///
/// The case worth pinning down is the stop that lands while the session is still coming up:
/// ScreenCaptureKit takes seconds to answer, and a Ctrl+C inside that window used to leave
/// startup finishing into a session nobody was left to end.
@Suite("Capture Lifecycle")
struct CaptureLifecycleTests {

    private struct StreamFailure: Error {}

    @Test("起動を引き受けるのは一度だけ")
    func startupIsClaimedOnce() {
        let lifecycle = CaptureLifecycle()

        #expect(lifecycle.beginStartup())
        #expect(!lifecycle.beginStartup())
    }

    @Test("起動前に停止していたら起動を始めない")
    func stopBeforeStartupRefusesToStart() {
        let lifecycle = CaptureLifecycle()

        lifecycle.stop()

        #expect(lifecycle.isStopped)
        #expect(!lifecycle.beginStartup())
    }

    @Test("起動中に立ち上がったソースは引き渡せる")
    func startupHandsSourcesOver() {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())

        var installed = false
        let handedOver = lifecycle.publish { installed = true }

        #expect(handedOver)
        #expect(installed)
    }

    @Test("停止後に立ち上がったソースは引き取らず、後始末は起動側に残す")
    func stopLeavesLateSourcesToTheStarter() {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        lifecycle.stop()

        var installed = false
        let handedOver = lifecycle.publish { installed = true }

        // Never handed over, so the stop cannot have taken it down: the starter has to.
        #expect(!handedOver)
        #expect(!installed)
    }

    @Test("起動中に停止したら録音開始を告げない")
    func stopDuringStartupNeverAnnouncesRecording() {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        lifecycle.stop()

        #expect(!lifecycle.beginRunning())
    }

    @Test("起動中に停止したら待機に入らずに返る")
    func waitReturnsWhenStopLandedDuringStartup() async {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        lifecycle.stop()

        // The stop found no continuation to resume, so waiting here would be waiting for good.
        let returned = await completes(within: .seconds(2)) { try? await lifecycle.waitForStop() }
        #expect(returned)
    }

    @Test("録音中の停止で待機が返る")
    func stopResumesTheWaiter() async {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        #expect(lifecycle.beginRunning())

        let returned = TestLatch<Bool>()
        let waiter = Task {
            try? await lifecycle.waitForStop()
            returned.set(true)
        }

        // Nothing but a stop ends the wait, so it is still parked here.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(returned.value == nil)

        lifecycle.stop()

        #expect(await returned.settled(within: .seconds(2)) == true)
        waiter.cancel()
    }

    @Test("ストリームの失敗は待機している側に届く")
    func failureReachesTheWaiter() async {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        #expect(lifecycle.beginRunning())

        let caught = TestLatch<Bool>()
        let waiter = Task {
            do {
                try await lifecycle.waitForStop()
                caught.set(false)
            } catch {
                caught.set(error is StreamFailure)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        lifecycle.fail(StreamFailure())

        #expect(await caught.settled(within: .seconds(2)) == true)
        waiter.cancel()
    }

    @Test("同時に停止しても後始末は一度だけ")
    func teardownHappensOnce() {
        let lifecycle = CaptureLifecycle()
        #expect(lifecycle.beginStartup())
        #expect(lifecycle.beginRunning())

        let teardowns = TestCounter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            lifecycle.stop { teardowns.increment() }
        }

        #expect(teardowns.value == 1)
    }
}

/// The same lifecycle through `AudioCapture`, with no source requested so it needs neither
/// a microphone nor a display.
///
/// What a stop before or during startup has to do is the same either way: end the session
/// instead of leaving `startCapture` suspended for the rest of the run.
@Suite("Audio Capture Lifecycle")
struct AudioCaptureLifecycleTests {

    private static func makeCapture() -> AudioCapture {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
            .appendingPathComponent("capture.wav")
        return AudioCapture(
            captureMic: false,
            captureSystem: false,
            paths: RecordingPaths(output: output.path)
        )
    }

    @Test("先に停止していたら startCapture は待たずに返る")
    func stopBeforeStartDoesNotSuspend() async {
        let capture = Self.makeCapture()
        _ = capture.stopCapture()

        let announced = TestLatch<Bool>()
        let returned = await completes(within: .seconds(2)) {
            try? await capture.startCapture { announced.set(true) }
        }

        #expect(returned)
        // Nothing was captured, so nothing should have claimed to be recording.
        #expect(announced.value == nil)
    }

    @Test("録音中の stopCapture で startCapture が返る")
    func stopEndsTheCapture() async {
        let capture = Self.makeCapture()
        let announced = TestLatch<Bool>()
        let returned = TestLatch<Bool>()

        let captureTask = Task {
            try? await capture.startCapture { announced.set(true) }
            returned.set(true)
        }

        #expect(await announced.settled(within: .seconds(2)) == true)
        #expect(returned.value == nil)

        _ = capture.stopCapture()

        #expect(await returned.settled(within: .seconds(2)) == true)
        captureTask.cancel()
    }

    @Test("stopCapture を二度呼んでも安全")
    func stoppingTwiceIsHarmless() {
        let capture = Self.makeCapture()

        #expect(capture.stopCapture().sources.isEmpty)
        #expect(capture.stopCapture().sources.isEmpty)
    }
}

// MARK: - Helpers

/// Run `body`, reporting whether it finished before `timeout`, so a lifecycle that never
/// resumes fails the test instead of hanging the suite.
private func completes(
    within timeout: Duration,
    _ body: @escaping @Sendable () async -> Void
) async -> Bool {
    let done = TestLatch<Bool>()
    let task = Task {
        await body()
        done.set(true)
    }

    let finished = await done.settled(within: timeout) == true
    task.cancel()
    return finished
}

/// A one-shot box a test can wait on, filled from whichever thread gets there.
private final class TestLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    /// The value once it lands, or nil at `timeout`.
    func settled(within timeout: Duration) async -> Value? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value
    }
}

/// Counts calls arriving from many threads at once.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

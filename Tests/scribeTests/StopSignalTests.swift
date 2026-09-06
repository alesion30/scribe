import Foundation
import Testing
@testable import scribe

/// Tests for the handoff that ends a recording, so a capture that never starts
/// stops the session instead of leaving it waiting for a stop key that means nothing.
@Suite("Stop Signal")
struct StopSignalTests {

    private struct CaptureFailure: Error {}

    @Test("待機中に届いた通知で wait が返る")
    func deliversToWaiter() async {
        let signal = StopSignal()

        Task {
            signal.signal(.stopped)
        }

        guard case .stopped = await signal.wait() else {
            Issue.record("Expected .stopped")
            return
        }
    }

    @Test("待機前に届いた通知も取りこぼさない")
    func holdsReasonUntilCollected() async {
        let signal = StopSignal()
        signal.signal(.failed(CaptureFailure()))

        guard case .failed(let error) = await signal.wait() else {
            Issue.record("Expected .failed")
            return
        }
        #expect(error is CaptureFailure)
    }

    @Test("最初の通知だけが採用される")
    func firstSignalWins() async {
        let signal = StopSignal()
        signal.signal(.failed(CaptureFailure()))
        signal.signal(.stopped)

        guard case .failed = await signal.wait() else {
            Issue.record("Expected the first reason to win")
            return
        }
    }

    @Test("停止と中断は取り違えない")
    func abortStaysAnAbort() async {
        let signal = StopSignal()
        signal.signal(.aborted)

        guard case .aborted = await signal.wait() else {
            Issue.record("Expected .aborted")
            return
        }
    }

    @Test("通知が決まったかどうかは回収前でも分かる")
    func reportsWhetherItIsSettled() async {
        let signal = StopSignal()
        #expect(!signal.isSettled)

        signal.signal(.stopped)
        #expect(signal.isSettled)

        _ = await signal.wait()
        #expect(signal.isSettled)
    }

    @Test("複数スレッドから同時に通知しても 1 つに決まる")
    func concurrentSignalsResolveToOne() async {
        let signal = StopSignal()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            signal.signal(index.isMultiple(of: 2) ? .stopped : .failed(CaptureFailure()))
        }

        // Any reason is fine; the point is that wait() returns exactly once without crashing.
        _ = await signal.wait()
    }
}

/// Tests for the flag Ctrl+C sets during transcription. whisper.cpp polls it from its
/// own threads while the decode blocks, so it has to latch and it has to be readable
/// from anywhere.
@Suite("Abort Flag")
struct AbortFlagTests {

    @Test("立てるまでは下りたまま")
    func startsDown() {
        #expect(!AbortFlag().isRaised)
    }

    @Test("一度立てたら下りない")
    func latchesOnceRaised() {
        let flag = AbortFlag()
        flag.raise()

        #expect(flag.isRaised)
        #expect(flag.isRaised)
    }

    @Test("別スレッドから立てても読み取れる")
    func isVisibleAcrossThreads() {
        let flag = AbortFlag()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            flag.raise()
            #expect(flag.isRaised)
        }

        #expect(flag.isRaised)
    }

    @Test("whisper に渡す確認は flag の状態をそのまま返す")
    func cancelCheckReportsTheFlag() {
        let flag = AbortFlag()
        let check = CancelCheck { flag.isRaised }

        #expect(!check.shouldStop())
        flag.raise()
        #expect(check.shouldStop())
    }
}

/// Tests for the guard that holds Ctrl+C through everything after the recording — fetching
/// a model, loading it, decoding — where a process dying on the spot would take the
/// transcript file's close with it.
@Suite("Interrupt Guard", .serialized)
struct InterruptGuardTests {

    @Test("保持中の SIGINT はプロセスを終わらせず中断として届く")
    func heldSigintBecomesAnAbort() async {
        let flag = AbortFlag()
        let interrupts = InterruptGuard { flag.raise() }
        defer { interrupts.release() }

        #expect(kill(getpid(), SIGINT) == 0)

        // Reaching this at all means the default action never ran.
        #expect(await flag.raises(within: .seconds(2)))
    }

    @Test("解放は二度呼んでも安全で、勝手に中断にはならない")
    func releasingTwiceIsHarmless() {
        let flag = AbortFlag()
        let interrupts = InterruptGuard { flag.raise() }

        // Both the explicit release and the deinit reach this on the way out of a run.
        interrupts.release()
        interrupts.release()

        #expect(!flag.isRaised)
    }
}

private extension AbortFlag {
    /// Wait for the signal handler to run, giving up at `timeout` so a guard that never
    /// fires fails the test instead of hanging the suite.
    func raises(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isRaised { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isRaised
    }
}

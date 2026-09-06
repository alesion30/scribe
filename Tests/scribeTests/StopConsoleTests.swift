import Foundation
import Testing
@testable import scribe

/// Tests for the terminal side of the stop key: a session it could never stop is
/// refused up front, and every decision has to reach the recording as itself.
@Suite("Stop Console")
struct StopConsoleTests {

    @Test("端末でない標準入力では録音を始めない")
    func refusesWithoutATerminal() {
        let terminal = FakeTerminal(isTerminal: false)

        #expect(throws: StopConsoleError.self) {
            _ = try StopConsole(stopSignal: StopSignal(), terminal: terminal)
        }
        // It gave up before changing anything, so there is nothing to put back.
        #expect(terminal.enterCount == 0)
        #expect(!terminal.isInSingleKeyMode)
    }

    @Test("確認を出しても取り下げても録音は続く")
    func askingLeavesTheRecordingRunning() {
        let stopSignal = StopSignal()
        var shown: [String] = []
        let announce: (String) -> Void = { shown.append($0) }

        StopConsole.apply(.confirm, to: stopSignal, announce: announce)
        StopConsole.apply(.resume, to: stopSignal, announce: announce)
        StopConsole.apply(.ignore, to: stopSignal, announce: announce)

        #expect(shown == [StopConsole.confirmHint, StopConsole.resumedHint])
        #expect(!stopSignal.isSettled)
    }

    @Test("確認後の停止は録音の停止として届く")
    func stopEndsTheRecording() async {
        let stopSignal = StopSignal()
        StopConsole.apply(.stop, to: stopSignal, announce: { _ in })

        #expect(stopSignal.isSettled)
        guard case .stopped = await stopSignal.wait() else {
            Issue.record("Expected .stopped")
            return
        }
    }

    @Test("中断は録音の停止と区別して届く")
    func abortEndsTheRun() async {
        let stopSignal = StopSignal()
        StopConsole.apply(.abort, to: stopSignal, announce: { _ in })

        guard case .aborted = await stopSignal.wait() else {
            Issue.record("Expected .aborted")
            return
        }
    }
}

/// The console driven end to end against a stand-in terminal.
///
/// This is where terminal restoration is pinned down: whichever way the session ends —
/// stopped, cancelled and stopped later, aborted, or refused outright — the terminal has
/// to come back. None of it needs a real terminal or a recording.
@Suite("Stop Console Lifecycle")
struct StopConsoleLifecycleTests {

    @Test("録音中は端末を単キー入力に切り替えている")
    func takesOverTheTerminalWhileRecording() throws {
        let harness = try ConsoleHarness()
        defer { harness.console.stop() }

        #expect(harness.terminal.enterCount == 1)
        #expect(harness.terminal.isInSingleKeyMode)
    }

    @Test("q → y で停止し、端末が元に戻る")
    func confirmingStopsAndRestores() async throws {
        let harness = try ConsoleHarness()

        harness.terminal.type("q")
        #expect(harness.shown.messages == [StopConsole.confirmHint])
        // The question alone must not end the recording.
        #expect(!harness.stopSignal.isSettled)
        #expect(harness.terminal.isInSingleKeyMode)

        harness.terminal.type("y")
        #expect(harness.stopSignal.isSettled)
        guard case .stopped = await harness.stopSignal.wait() else {
            Issue.record("Expected .stopped")
            return
        }

        harness.console.stop()
        #expect(harness.terminal.isRestored)
        #expect(!harness.terminal.isInSingleKeyMode)
    }

    @Test("q → n で録音に戻り、端末は単キー入力のまま")
    func cancellingKeepsRecordingAndTheTerminal() throws {
        let harness = try ConsoleHarness()
        defer { harness.console.stop() }

        harness.terminal.type("qn")

        #expect(harness.shown.messages == [StopConsole.confirmHint, StopConsole.resumedHint])
        #expect(!harness.stopSignal.isSettled)
        // Recording continues, so the terminal must stay taken over.
        #expect(harness.terminal.isInSingleKeyMode)
        #expect(!harness.terminal.isRestored)
    }

    @Test("取り下げたあとでも改めて q → y で停止できる")
    func canStopAfterCancelling() async throws {
        let harness = try ConsoleHarness()

        harness.terminal.type("qn")
        harness.terminal.type("qy")

        guard case .stopped = await harness.stopSignal.wait() else {
            Issue.record("Expected .stopped")
            return
        }
        harness.console.stop()
        #expect(!harness.terminal.isInSingleKeyMode)
    }

    @Test("Ctrl+C は確認を挟まず中断し、端末を元に戻す")
    func abortRestoresTheTerminal() async throws {
        let harness = try ConsoleHarness()

        harness.terminal.type("\u{03}")

        #expect(harness.shown.messages.isEmpty)
        guard case .aborted = await harness.stopSignal.wait() else {
            Issue.record("Expected .aborted")
            return
        }

        harness.console.stop()
        #expect(harness.terminal.isRestored)
        #expect(!harness.terminal.isInSingleKeyMode)
    }

    @Test("標準入力が閉じたら中断して端末を元に戻す")
    func closedInputAbortsAndRestores() async throws {
        let harness = try ConsoleHarness()
        defer { harness.console.stop() }

        harness.terminal.closeInput()

        guard case .aborted = await harness.stopSignal.wait() else {
            Issue.record("Expected .aborted")
            return
        }
        #expect(harness.terminal.isRestored)
    }

    @Test("単キー入力への切り替えに失敗しても端末を元に戻す")
    func failedTakeoverRestoresTheTerminal() {
        let terminal = FakeTerminal(enterError: StopConsoleError.rawModeUnavailable("nope"))

        #expect(throws: StopConsoleError.self) {
            _ = try StopConsole(stopSignal: StopSignal(), terminal: terminal)
        }
        // The switch may have half gone through before it gave up, so it is put back.
        #expect(terminal.isRestored)
        #expect(!terminal.isInSingleKeyMode)
    }

    @Test("stop を二度呼んでも安全に元のまま")
    func stoppingTwiceIsHarmless() throws {
        let harness = try ConsoleHarness()

        harness.console.stop()
        harness.console.stop()

        #expect(harness.terminal.isRestored)
        #expect(harness.terminal.restoreCallCount == 2)
    }
}

/// The same thing against a real terminal, because the seam above can only prove the
/// bookkeeping — not that termios actually comes back.
///
/// Skipped where a pseudo terminal cannot be opened, the way the transcription tests
/// skip without a model, so a restricted environment doesn't fail the suite.
@Suite("Stop Console Terminal", .enabled(if: PseudoTerminal.isAvailable))
struct StopConsoleTerminalTests {

    @Test("実際の端末で単キー入力に切り替わる")
    func switchesTheRealTerminal() throws {
        let terminal = try #require(PseudoTerminal())
        defer { terminal.release() }

        let console = try StopConsole(stopSignal: StopSignal(), input: terminal.device)
        defer { console.stop() }

        var attributes = termios()
        let readAttributes = tcgetattr(terminal.device, &attributes)
        #expect(readAttributes == 0)
        #expect((attributes.c_lflag & tcflag_t(ICANON)) == 0)
        #expect((attributes.c_lflag & tcflag_t(ECHO)) == 0)
    }

    @Test("実際に打鍵した q → y で録音が止まる")
    func realKeystrokesStopTheRecording() async throws {
        let terminal = try #require(PseudoTerminal())
        defer { terminal.release() }

        let stopSignal = StopSignal()
        let console = try StopConsole(stopSignal: stopSignal, input: terminal.device)
        defer { console.stop() }

        // Ask, take it back, then ask again: the recording only ends on the y.
        terminal.type("qn")
        terminal.type("qy")

        let settled = await stopSignal.settles(within: .seconds(5))
        #expect(settled)
        guard case .stopped = await stopSignal.wait() else {
            Issue.record("Expected .stopped")
            return
        }
    }

    @Test("実際の端末で q → n では止まらない")
    func realCancelKeepsRecording() async throws {
        let terminal = try #require(PseudoTerminal())
        defer { terminal.release() }

        let stopSignal = StopSignal()
        let console = try StopConsole(stopSignal: stopSignal, input: terminal.device)
        defer { console.stop() }

        terminal.type("qn")

        let settled = await stopSignal.settles(within: .milliseconds(300))
        #expect(!settled)
    }

    @Test("録音を終えたあとに打った文字は次の読み手に残る")
    func restoreLeavesLaterInputForTheNextReader() throws {
        // A reader still inside read() would swallow this. That is what putting the descriptor
        // back to blocking underneath a read already in flight leaves behind: the stop key
        // reader outliving the recording and eating what the user types next.
        for _ in 0..<25 {
            let terminal = try #require(PseudoTerminal())
            defer { terminal.release() }

            let console = try StopConsole(stopSignal: StopSignal(), input: terminal.device)
            // Wake the reader, then stop while its handler may still be running.
            terminal.type("n")
            console.stop()

            // Line-buffered again by now, so the newline is what makes this readable at all.
            terminal.type("Z\n")
            #expect(readWaiting(terminal.device, within: 500).contains(UInt8(ascii: "Z")))
        }
    }

    @Test("録音を終えると termios とフラグが元に戻る")
    func restoresTheRealTerminalAfterwards() throws {
        let terminal = try #require(PseudoTerminal())
        defer { terminal.release() }

        var before = termios()
        let readBefore = tcgetattr(terminal.device, &before)
        #expect(readBefore == 0)
        let flagsBefore = fcntl(terminal.device, F_GETFL)

        let console = try StopConsole(stopSignal: StopSignal(), input: terminal.device)
        console.stop()
        // The abort paths can reach stop() twice; the second must not undo the first.
        console.stop()

        var after = termios()
        let readAfter = tcgetattr(terminal.device, &after)
        #expect(readAfter == 0)
        #expect(after.c_lflag == before.c_lflag)
        #expect(after.c_iflag == before.c_iflag)
        #expect(after.c_oflag == before.c_oflag)

        let flagsAfter = fcntl(terminal.device, F_GETFL)
        #expect(flagsAfter == flagsBefore)
    }
}

// MARK: - Test doubles

/// One console wired to a terminal the test can type on and inspect.
private struct ConsoleHarness {
    let terminal: FakeTerminal
    let stopSignal: StopSignal
    let shown: Announcements
    let console: StopConsole

    init() throws {
        let terminal = FakeTerminal()
        let stopSignal = StopSignal()
        let shown = Announcements()

        console = try StopConsole(
            stopSignal: stopSignal,
            terminal: terminal,
            announce: { shown.append($0) }
        )
        self.terminal = terminal
        self.stopSignal = stopSignal
        self.shown = shown
    }
}

/// Collects what the console printed, so the prompts can be asserted without stderr.
final class Announcements: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ message: String) {
        lock.lock()
        collected.append(message)
        lock.unlock()
    }
}

/// A terminal the test types on, standing in for the real one.
final class FakeTerminal: TerminalOperations, @unchecked Sendable {
    let isTerminal: Bool

    private let enterError: (any Error)?
    private let lock = NSLock()
    private var keyHandler: (@Sendable ([UInt8]) -> Void)?
    private var endHandler: (@Sendable () -> Void)?

    private(set) var enterCount = 0
    /// Every call, redundant ones included.
    private(set) var restoreCallCount = 0
    /// Whether the terminal has been handed back, however many calls it took.
    private(set) var isRestored = false

    /// True while the console holds the terminal, which is what "recording continues"
    /// looks like from the terminal's side.
    var isInSingleKeyMode: Bool {
        enterCount > 0 && !isRestored
    }

    init(isTerminal: Bool = true, enterError: (any Error)? = nil) {
        self.isTerminal = isTerminal
        self.enterError = enterError
    }

    func enterSingleKeyMode() throws {
        // Mirrors the real one: a failure can still leave part of the switch applied,
        // so the console has to put it back either way.
        if let enterError { throw enterError }
        enterCount += 1
    }

    func startReading(
        onKeys: @escaping @Sendable ([UInt8]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        keyHandler = onKeys
        endHandler = onEnd
        lock.unlock()
    }

    /// Idempotent in effect, matching the contract `PosixTerminal` has to keep.
    func restore() {
        restoreCallCount += 1
        isRestored = true
    }

    /// Deliver keystrokes the way a terminal would.
    func type(_ keys: String) {
        lock.lock()
        let handler = keyHandler
        lock.unlock()
        handler?(Array(keys.utf8))
    }

    func closeInput() {
        lock.lock()
        let handler = endHandler
        lock.unlock()
        handler?()
    }
}

// MARK: - Helpers

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

/// Read what is waiting on `descriptor`, giving up at `milliseconds` rather than blocking
/// the test on input someone else took.
private func readWaiting(_ descriptor: Int32, within milliseconds: Int32) -> [UInt8] {
    var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptors, 1, milliseconds) > 0 else { return [] }

    var buffer = [UInt8](repeating: 0, count: 64)
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    guard count > 0 else { return [] }
    return Array(buffer.prefix(count))
}

extension StopSignal {
    /// Wait for the console to decide, giving up at `timeout` so a reader that never
    /// answers fails the test instead of hanging the suite.
    func settles(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isSettled { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isSettled
    }
}

/// A pseudo terminal pair, so the console can be driven the way a terminal drives it.
struct PseudoTerminal {
    /// The end a person types on.
    let controller: Int32
    /// The end scribe reads, standing in for stdin.
    let device: Int32

    static var isAvailable: Bool {
        guard let terminal = Self() else { return false }
        terminal.release()
        return true
    }

    init?() {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0 else { return nil }

        guard grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else {
            closeDescriptor(primary)
            return nil
        }

        let secondary = open(name, O_RDWR | O_NOCTTY)
        guard secondary >= 0 else {
            closeDescriptor(primary)
            return nil
        }

        controller = primary
        device = secondary
    }

    func type(_ keys: String) {
        let bytes = Array(keys.utf8)
        _ = bytes.withUnsafeBytes { write(controller, $0.baseAddress, $0.count) }
    }

    func release() {
        closeDescriptor(device)
        closeDescriptor(controller)
    }
}

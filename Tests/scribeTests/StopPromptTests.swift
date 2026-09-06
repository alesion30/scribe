import Foundation
import Testing
@testable import scribe

/// Tests for the keys that end a recording, so one stray keypress cannot throw a
/// session away and Ctrl+C still gets out without answering anything first.
@Suite("Stop Prompt")
struct StopPromptTests {

    private static let quit = UInt8(ascii: "q")
    private static let yes = UInt8(ascii: "y")
    private static let no = UInt8(ascii: "n")
    private static let escape: UInt8 = 0x1B
    private static let interrupt: UInt8 = 0x03

    @Test("q は確認を出すだけで録音は止めない")
    func quitOnlyAsks() {
        var prompt = StopPrompt()

        #expect(prompt.handle(Self.quit) == .confirm)
        #expect(prompt.isConfirming)
    }

    @Test("確認中の y で停止する")
    func yesStops() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(Self.yes) == .stop)
        #expect(!prompt.isConfirming)
    }

    @Test("確認中の n で録音に戻る")
    func noResumes() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(Self.no) == .resume)
        #expect(!prompt.isConfirming)
    }

    @Test("確認中の Esc で録音に戻る")
    func escapeResumes() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(Self.escape) == .resume)
        #expect(!prompt.isConfirming)
    }

    @Test("確認を出していないときの y は何も起こさない")
    func answersAloneDoNothing() {
        var prompt = StopPrompt()

        #expect(prompt.handle(Self.yes) == .ignore)
        #expect(prompt.handle(Self.no) == .ignore)
        #expect(prompt.handle(Self.escape) == .ignore)
        #expect(!prompt.isConfirming)
    }

    @Test("大文字でも同じ意味になる")
    func acceptsUppercase() {
        var prompt = StopPrompt()

        #expect(prompt.handle(UInt8(ascii: "Q")) == .confirm)
        #expect(prompt.handle(UInt8(ascii: "Y")) == .stop)
    }

    @Test("確認中に関係ないキーを押しても質問は消えない")
    func unrelatedKeysKeepTheQuestion() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(UInt8(ascii: "a")) == .ignore)
        #expect(prompt.handle(Self.quit) == .ignore)
        #expect(prompt.isConfirming)
        #expect(prompt.handle(Self.yes) == .stop)
    }

    @Test("録音に戻ったあとでも改めて停止できる")
    func canAskAgainAfterResuming() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(Self.no) == .resume)
        #expect(prompt.handle(Self.quit) == .confirm)
        #expect(prompt.handle(Self.yes) == .stop)
    }

    @Test("Ctrl+C は確認を挟まずに中断する")
    func interruptSkipsTheQuestion() {
        var prompt = StopPrompt()

        #expect(prompt.handle(Self.interrupt) == .abort)
        #expect(!prompt.isConfirming)
    }

    @Test("確認中の Ctrl+C も中断になる")
    func interruptWinsOverTheQuestion() {
        var prompt = StopPrompt()
        _ = prompt.handle(Self.quit)

        #expect(prompt.handle(Self.interrupt) == .abort)
        #expect(!prompt.isConfirming)
    }
}

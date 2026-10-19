import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal software text input")
struct SSHTerminalTextInputTests {
    /// The shell's line as the grid's writes leave it, after whatever the
    /// line held before (`earlier`).
    private struct ShellLine {
        var earlier = "$ "
        var typed = ""
        var line: String { earlier + typed }

        mutating func apply(_ actions: [SSHTerminalTextInputStorage.Action]) {
            for action in actions {
                switch action {
                case .insert(let text):
                    typed += text
                case .backspace:
                    erase(1)
                case .edit(let deleting, let text):
                    erase(deleting)
                    typed += text
                }
            }
        }

        private mutating func erase(_ count: Int) {
            for _ in 0..<count {
                if typed.isEmpty { earlier.removeLast() } else { typed.removeLast() }
            }
        }
    }

    /// The range of the last `text` before the caret, as dictation finds
    /// its guess.
    private func guess(_ text: String, in storage: SSHTerminalTextInputStorage) -> Range<Int> {
        let end = storage.selectedUTF16.lowerBound
        let range = (end - text.utf16.count)..<end
        #expect(storage.text(in: range) == text)
        return range
    }

    @Test func keystrokesAndWordsGoAtOnceAndDeleteKeepsRepeating() {
        var storage = SSHTerminalTextInputStorage()
        var shell = ShellLine()
        #expect(storage.insertText("a", hardwareKeysDown: false) == [.insert("a")])
        // A suggestion or slide-typed word is one write, sent now.
        #expect(storage.insertText("bc", hardwareKeysDown: false) == [.edit(deleting: 0, text: "bc")])
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
        shell.apply([.insert("a"), .edit(deleting: 0, text: "bc"), .backspace])
        #expect(shell.line == "$ ab")
        // ⌫ past what this keyboard typed still deletes, and never runs dry.
        for _ in 0..<4 {
            let actions = storage.deleteBackward(hardwareKeysDown: false)
            #expect(actions == [.backspace])
            shell.apply(actions)
            #expect(storage.selectedUTF16.lowerBound > 0)
        }
        #expect(shell.line == "")
        #expect(storage.text == SSHTerminalTextInputStorage.filler)
    }

    /// The reported bug: dictation streamed into the shell, then the mic tap
    /// put its final text in a second time with spaces in front. Each way
    /// iOS can finish a guess must leave the final text in the shell once.
    @Test func dictationFollowsEachRevisionAndEndsWithItsFinalTextOnce() {
        let final = "Hello hello, what are we talking about here?"
        let finishes: [(String, (inout SSHTerminalTextInputStorage, String) -> [SSHTerminalTextInputStorage.Action])] = [
            ("replace the guess", { storage, last in
                storage.replace(utf16Range: self.guess(last, in: storage), with: final, hardwareKeysDown: false)
            }),
            ("placeholder over the guess", { storage, last in
                storage.select(utf16Range: self.guess(last, in: storage))
                var actions = storage.setMarkedText(String(repeating: " ", count: 12), selectedRange: NSRange(location: 12, length: 0))
                actions += storage.insertText(final, hardwareKeysDown: false)
                actions += storage.unmarkText(hardwareKeysDown: false)
                return actions
            }),
            ("remove the guess, insert the result", { storage, last in
                var actions = storage.replace(utf16Range: self.guess(last, in: storage), with: "", hardwareKeysDown: false)
                actions += storage.insertText(final, hardwareKeysDown: false)
                return actions
            }),
        ]
        for (name, finish) in finishes {
            var storage = SSHTerminalTextInputStorage()
            var shell = ShellLine()
            shell.apply(storage.insertText("hello", hardwareKeysDown: false))
            #expect(shell.line == "$ hello", "\(name)")
            // Words a revision adds reach the shell at once.
            shell.apply(storage.replace(utf16Range: guess("hello", in: storage), with: "hello hello what", hardwareKeysDown: false))
            #expect(shell.line == "$ hello hello what", "\(name)")
            // A revision of words already sent rewrites them in the shell.
            let revised = "Hello hello, what are we talking"
            shell.apply(storage.replace(utf16Range: guess("hello hello what", in: storage), with: revised, hardwareKeysDown: false))
            #expect(shell.line == "$ " + revised, "\(name)")
            shell.apply(finish(&storage, revised))
            #expect(shell.line == "$ " + final, "\(name)")
            // The next utterance goes after it.
            shell.apply(storage.insertText(" Is this good?", hardwareKeysDown: false))
            #expect(shell.line == "$ " + final + " Is this good?", "\(name)")
        }
    }

    /// After an arrow or a tap resets the document, a revision of the guess
    /// typed before it names text that is gone; it must not type it again.
    @Test func aRevisionOfTextFromBeforeAResetIsDropped() {
        var storage = SSHTerminalTextInputStorage()
        var shell = ShellLine()
        shell.apply(storage.insertText("Hello world", hardwareKeysDown: false))
        let stale = guess("Hello world", in: storage)
        storage.restart()
        shell.apply(storage.replace(utf16Range: stale, with: "Hello world.", hardwareKeysDown: false))
        #expect(shell.line == "$ Hello world")
    }

    @Test func anEditReachingBeforeTheTypedTextDeletesWhatTheShellHadThere() {
        var storage = SSHTerminalTextInputStorage()
        var shell = ShellLine()
        shell.apply(storage.insertText("ls", hardwareKeysDown: false))
        // The filler stands for the shell's last character before the typed text.
        shell.apply(storage.replace(utf16Range: 0..<storage.utf16Count, with: "pwd", hardwareKeysDown: false))
        #expect(shell.line == "$pwd")
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
    }

    @Test func hardwarePressSwallowsInsertAndDelete() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.insertText("a", hardwareKeysDown: true).isEmpty)
        #expect(storage.deleteBackward(hardwareKeysDown: true).isEmpty)
        #expect(storage.insertText("a", hardwareKeysDown: false) == [.insert("a")])
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
    }

    @Test func markedTextDoesNotSendUntilInsertThenUnmark() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0)).isEmpty)
        #expect(storage.markedText == "に")
        #expect(storage.insertText("に", hardwareKeysDown: false) == [.insert("に")])
        #expect(storage.unmarkText(hardwareKeysDown: false).isEmpty)
        #expect(storage.markedText == nil)
        // The same character typed next is a new keystroke, not an echo.
        #expect(storage.insertText("に", hardwareKeysDown: false) == [.insert("に")])
    }

    @Test func unmarkThenEchoedInsertSendsOnceAndLaterRepeatsSend() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0)).isEmpty)
        #expect(storage.unmarkText(hardwareKeysDown: false) == [.insert("に")])
        #expect(storage.insertText("に", hardwareKeysDown: false).isEmpty)
        #expect(storage.insertText("に", hardwareKeysDown: false) == [.insert("に")])

        // An echo that never comes expires on the owner's next turn.
        #expect(storage.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0)).isEmpty)
        #expect(storage.unmarkText(hardwareKeysDown: false) == [.insert("に")])
        let stale = storage.commitEchoGeneration
        #expect(storage.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0)).isEmpty)
        #expect(storage.unmarkText(hardwareKeysDown: false) == [.insert("に")])
        // The first commit's expiry must not drop the second commit's guard.
        storage.expireCommitEcho(generation: stale)
        #expect(storage.awaitsCommitEcho)
        storage.expireCommitEcho(generation: storage.commitEchoGeneration)
        #expect(storage.insertText("に", hardwareKeysDown: false) == [.insert("に")])
    }

    @Test func caretStaysAfterTheFillerSoDeleteKeepsRepeating() throws {
        var storage = SSHTerminalTextInputStorage()
        storage.select(utf16Range: 0..<0)
        #expect(storage.selectedUTF16.lowerBound == SSHTerminalTextInputStorage.filler.utf16.count)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
        #expect(storage.selectedUTF16.lowerBound > 0)
        // Inside a composition the IME still moves its own caret.
        #expect(storage.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0)).isEmpty)
        let inside = try #require(storage.markedUTF16).lowerBound + 1
        storage.select(utf16Range: inside..<inside)
        #expect(storage.selectedUTF16 == inside..<inside)
    }

    @Test func deleteDuringMarkedTextEditsCompositionOnly() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0)).isEmpty)
        #expect(storage.deleteBackward(hardwareKeysDown: false).isEmpty)
        #expect(storage.markedText == "n")
        #expect(storage.deleteBackward(hardwareKeysDown: false).isEmpty)
        #expect(storage.markedText == nil)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
    }

    @Test func trackpadSendsOneArrowPerWholeCellOfTravelOnEachAxis() {
        var pad = SSHTerminalTrackpadArrows()
        let cell = CGSize(width: 8, height: 17)
        func move(_ x: CGFloat, _ y: CGFloat) -> SSHTerminalTrackpadArrows.Steps {
            pad.update(to: CGPoint(x: x, y: y), cell: cell)
            return pad.takePending()
        }
        #expect(move(400, 400).isEmpty) // no drag began
        pad.begin(at: CGPoint(x: 100, y: 100))
        #expect(move(107.9, 116.9).isEmpty) // under one cell each way
        // Moves within a frame add up into one batch.
        pad.update(to: CGPoint(x: 120, y: 100), cell: cell)
        #expect(move(128, 135) == .init(columns: 3, rows: 2))
        // Back past the start: three back to the origin, one more beyond it.
        #expect(move(92, 100) == .init(columns: -4, rows: -2))
        pad.end()
        #expect(move(300, 300).isEmpty)
        // A new drag measures from its own start.
        pad.begin(at: CGPoint(x: 300, y: 300))
        #expect(move(284, 300) == .init(columns: -2, rows: 0))
    }

    @Test func heldSoftwareDeleteTurnsIntoWordDeleteAfterASecondAndTapsNever() {
        var delete = SSHTerminalDeleteAcceleration()
        // Press, the first repeat half a second later, then one every 0.1 s.
        var times: [TimeInterval] = [0]
        times += stride(from: 0.5, through: 1.6, by: 0.1).map { $0 }
        let words = times.map { delete.softwareDeletesWord(at: $0) }
        let firstWord = words.firstIndex(of: true).map { times[$0] }
        #expect(firstWord.map { abs($0 - 1.0) < 0.01 } == true)
        #expect(words.drop(while: { !$0 }).allSatisfy { $0 }) // stays in words until release
        // Release, then press again: characters again.
        let again = [2.5, 3.0].map { delete.softwareDeletesWord(at: $0) }
        #expect(again == [false, false])
        // Fast taps, 0.15 s apart for two seconds, are presses, not a hold.
        delete.reset()
        let taps = stride(from: 10.0, through: 12.0, by: 0.15).map { delete.softwareDeletesWord(at: $0) }
        #expect(!taps.contains(true))
        #expect(!SSHTerminalDeleteAcceleration.hardwareDeletesWord(heldFor: 0.95))
        #expect(SSHTerminalDeleteAcceleration.hardwareDeletesWord(heldFor: 1.0))
    }

    @Test func onlyCommandCAndKAreGridShortcuts() {
        #expect(SSHTerminalHardwareShortcut.matching(input: "c", modifiers: .command) == .copy)
        #expect(SSHTerminalHardwareShortcut.matching(input: "K", modifiers: [.command, .alphaShift]) == .clearScreen)
        // iOS turns ⌘. into Esc itself; ⌘V keeps its press path;
        // other ⌘ letters type as before.
        #expect(SSHTerminalHardwareShortcut.matching(input: ".", modifiers: .command) == nil)
        #expect(SSHTerminalHardwareShortcut.matching(input: "v", modifiers: .command) == nil)
        #expect(SSHTerminalHardwareShortcut.matching(input: "a", modifiers: .command) == nil)
        // Another modifier makes it a different chord.
        #expect(SSHTerminalHardwareShortcut.matching(input: "c", modifiers: [.command, .shift]) == nil)
        #expect(SSHTerminalHardwareShortcut.matching(input: "c", modifiers: .control) == nil)
        #expect(SSHTerminalHardwareShortcut.matching(input: ".", modifiers: [.command, .alternate]) == nil)
    }

    @Test func optionShiftSendsOnlyAnASCIILetterUppercasedTheSameEverywhere() {
        #expect(SSHTerminalGridView.metaCharacters(base: "b", shift: false) == "b")
        #expect(SSHTerminalGridView.metaCharacters(base: "b", shift: true) == "B")
        // Turkish uppercases i to a dotted capital; Meta must not.
        #expect("i".uppercased(with: Locale(identifier: "tr_TR")) != "I")
        #expect(SSHTerminalGridView.metaCharacters(base: "i", shift: true) == "I")
        for base in ["\u{df}", "\u{e9}", "[", "1", "ab", ""] {
            #expect(SSHTerminalGridView.metaCharacters(base: base, shift: true) == nil, "\(base)")
        }
    }
}

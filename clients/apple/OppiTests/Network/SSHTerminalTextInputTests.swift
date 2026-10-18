import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal software text input")
struct SSHTerminalTextInputTests {
    @Test func keystrokesSendAtOnceAndAPhraseWaitsToBeTakenOnce() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.insertText("a", hardwareKeysDown: false) == [.insert("a")])
        #expect(storage.insertText("bc", hardwareKeysDown: false).isEmpty)
        #expect(storage.markedText == nil)
        #expect(storage.takeUnsentPhrase() == [.insert("bc")])
        #expect(storage.takeUnsentPhrase().isEmpty)
        // An unsent phrase goes before whatever comes next.
        #expect(storage.insertText("de", hardwareKeysDown: false).isEmpty)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.insert("de"), .backspace])
        #expect(storage.insertText("fg", hardwareKeysDown: false).isEmpty)
        #expect(storage.finishPhrase() == [.insert("fg")])
        #expect(storage.text == SSHTerminalTextInputStorage.filler)
    }

    /// iOS streaming dictation inserts a guess, then replaces it by finding
    /// it before the caret. Each revision must find the last one, and the
    /// shell gets each settled word once.
    @Test func dictationRevisionsFindTheirGuessAndSendSettledWordsOnce() {
        var storage = SSHTerminalTextInputStorage()
        let start = SSHTerminalTextInputStorage.filler.utf16.count
        func revise(_ last: String, _ next: String) -> [SSHTerminalTextInputStorage.Action] {
            let end = storage.utf16Count
            let range = (end - last.utf16.count)..<end
            #expect(storage.text(in: range) == last)
            #expect(storage.selectedUTF16 == end..<end)
            return storage.replace(utf16Range: range, with: next, hardwareKeysDown: false)
        }
        #expect(storage.insertText("Hello", hardwareKeysDown: false).isEmpty)
        #expect(revise("Hello", "Hello word").isEmpty)
        #expect(revise("Hello word", "Hello world").isEmpty)
        #expect(storage.takeUnsentPhrase() == [.insert("Hello world")])
        // Dictation keeps going after a pause: only the new words go.
        #expect(revise("Hello world", "Hello world how are you").isEmpty)
        #expect(storage.takeUnsentPhrase() == [.insert(" how are you")])
        // A revision of words already sent cannot be taken back: dropped.
        #expect(revise("Hello world how are you", "Hello world. How are you?").isEmpty)
        #expect(storage.takeUnsentPhrase().isEmpty)
        #expect(revise("Hello world. How are you?", "Hello world. How are you? Fine").isEmpty)
        #expect(storage.takeUnsentPhrase() == [.insert(" Fine")])
        // The filler stays in front, so held ⌫ still has text to delete.
        #expect(storage.text(in: 0..<start) == SSHTerminalTextInputStorage.filler)
        // A single-character guess is sent like a keystroke and can still grow.
        #expect(storage.insertText("I", hardwareKeysDown: false) == [.insert("I")])
        #expect(revise("I", "I am").isEmpty)
        #expect(storage.takeUnsentPhrase() == [.insert(" am")])
    }

    @Test func deleteOnFilledStorageEmitsBackspaceAndRefills() {
        var storage = SSHTerminalTextInputStorage()
        #expect(!storage.text.isEmpty)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
        #expect(!storage.text.isEmpty)
    }

    @Test func deleteOnEmptyStorageStillEmitsAndRefills() {
        var storage = SSHTerminalTextInputStorage(text: "")
        #expect(storage.text.isEmpty)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
        #expect(!storage.text.isEmpty)
    }

    @Test func repeatedDeleteKeepsDummyTextAndEmitsEachBackspace() {
        var storage = SSHTerminalTextInputStorage()
        for _ in 0..<8 {
            #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
            #expect(!storage.text.isEmpty)
        }
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

    @Test func caretStaysAtTheEndSoDeleteKeepsRepeating() {
        var storage = SSHTerminalTextInputStorage()
        let end = storage.utf16Count
        storage.select(utf16Range: 0..<0)
        #expect(storage.selectedUTF16 == end..<end)
        #expect(storage.deleteBackward(hardwareKeysDown: false) == [.backspace])
        #expect(storage.selectedUTF16.lowerBound > 0)
        // Inside a composition the IME still moves its own caret.
        #expect(storage.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0)).isEmpty)
        storage.select(utf16Range: 1..<1)
        #expect(storage.selectedUTF16 == 1..<1)
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

    @Test func replaceWithoutMarkedTextMapsDeleteAndInsert() {
        var storage = SSHTerminalTextInputStorage()
        let whole = 0..<storage.utf16Count
        #expect(storage.replace(utf16Range: whole, with: "", hardwareKeysDown: false) == [.backspace])
        #expect(!storage.text.isEmpty)
        #expect(storage.replace(utf16Range: whole, with: "z", hardwareKeysDown: false) == [.insert("z")])
        #expect(storage.replace(utf16Range: whole, with: "z", hardwareKeysDown: true).isEmpty)
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
}

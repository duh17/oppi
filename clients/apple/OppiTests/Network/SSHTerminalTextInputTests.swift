import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal software text input")
struct SSHTerminalTextInputTests {
    @Test func insertLeavesDummyTextAndEmitsOnce() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.insertText("ab", hardwareKeysDown: false) == [.insert("ab")])
        #expect(!storage.text.isEmpty)
        #expect(storage.markedText == nil)
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
}

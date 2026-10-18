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
    }

    @Test func markedTextDoesNotSendUntilUnmarkThenMatchingInsert() {
        var storage = SSHTerminalTextInputStorage()
        #expect(storage.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0)).isEmpty)
        #expect(storage.unmarkText(hardwareKeysDown: false) == [.insert("に")])
        #expect(storage.insertText("に", hardwareKeysDown: false).isEmpty)
        #expect(storage.insertText("x", hardwareKeysDown: false) == [.insert("x")])
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

import UIKit

/// Dummy document the software keyboard can delete from so held ⌫ repeats.
/// The grid never paints this storage; each mutation maps to terminal keys.
struct SSHTerminalTextInputStorage {
    enum Action: Equatable {
        case insert(String)
        case backspace
    }

    /// One character so UIKit always has something to delete and repeat on.
    static let filler = " "

    private(set) var text: String
    private(set) var markedText: String?
    /// UTF-16 selection in `text`. Pinned to the end unless text is marked.
    private(set) var selectedUTF16: Range<Int>
    /// A commit `unmarkText` already sent. The keyboard may echo it through
    /// `insertText` in the same call stack; only that echo is dropped. The
    /// owner calls `expireCommitEcho` on the next main turn so a later,
    /// identical keystroke still sends.
    private var unmarkedCommit: String?
    private(set) var commitEchoGeneration = 0

    var utf16Count: Int { text.utf16.count }
    var awaitsCommitEcho: Bool { unmarkedCommit != nil }

    init(text: String = Self.filler) {
        self.text = text
        markedText = nil
        unmarkedCommit = nil
        let end = text.utf16.count
        selectedUTF16 = end..<end
    }

    mutating func insertText(_ string: String, hardwareKeysDown: Bool) -> [Action] {
        let pending = markedText
        let echo = unmarkedCommit
        unmarkedCommit = nil
        refill()
        guard !hardwareKeysDown else { return [] }
        if pending == nil, echo == string { return [] }
        return string.isEmpty ? [] : [.insert(string)]
    }

    mutating func deleteBackward(hardwareKeysDown: Bool) -> [Action] {
        unmarkedCommit = nil
        if let marked = markedText, !marked.isEmpty {
            var next = marked
            next.removeLast()
            if next.isEmpty {
                markedText = nil
                refill()
            } else {
                markedText = next
                text = next
                let end = utf16Count
                selectedUTF16 = end..<end
            }
            return []
        }
        refill()
        guard !hardwareKeysDown else { return [] }
        return [.backspace]
    }

    mutating func setMarkedText(_ markedText: String?, selectedRange: NSRange) -> [Action] {
        unmarkedCommit = nil
        let next = markedText ?? ""
        if next.isEmpty {
            self.markedText = nil
            refill()
        } else {
            self.markedText = next
            text = next
            let length = next.utf16.count
            let location = min(max(selectedRange.location, 0), length)
            let lengthInMarked = min(max(selectedRange.length, 0), length - location)
            selectedUTF16 = location..<(location + lengthInMarked)
        }
        return []
    }

    /// A commit already sent by `insertText` cleared the mark, so the
    /// `unmarkText` that follows it finds nothing and sends nothing.
    mutating func unmarkText(hardwareKeysDown: Bool) -> [Action] {
        let committed = markedText
        unmarkedCommit = nil
        refill()
        guard !hardwareKeysDown, let committed, !committed.isEmpty else { return [] }
        unmarkedCommit = committed
        commitEchoGeneration &+= 1
        return [.insert(committed)]
    }

    mutating func expireCommitEcho(generation: Int) {
        if generation == commitEchoGeneration { unmarkedCommit = nil }
    }

    mutating func replace(utf16Range: Range<Int>, with string: String, hardwareKeysDown: Bool) -> [Action] {
        if markedText != nil {
            return setMarkedText(
                string,
                selectedRange: NSRange(location: string.utf16.count, length: 0)
            )
        }
        unmarkedCommit = nil
        refill()
        guard !hardwareKeysDown else { return [] }
        if string.isEmpty { return [.backspace] }
        return [.insert(string)]
    }

    /// Outside a composition the caret stays after the filler, so ⌫ always
    /// has a character to delete and keeps repeating. The space-bar trackpad
    /// and hit tests would otherwise park it at 0, where UIKit stops deleting.
    mutating func select(utf16Range: Range<Int>) {
        guard markedText != nil else { return }
        let end = utf16Count
        let lower = min(max(utf16Range.lowerBound, 0), end)
        let upper = min(max(utf16Range.upperBound, 0), end)
        selectedUTF16 = min(lower, upper)..<max(lower, upper)
    }

    mutating func reset() {
        unmarkedCommit = nil
        refill()
    }

    func text(in utf16Range: Range<Int>) -> String? {
        let end = utf16Count
        let lower = min(max(utf16Range.lowerBound, 0), end)
        let upper = min(max(utf16Range.upperBound, 0), end)
        guard lower <= upper else { return nil }
        let start = String.Index(utf16Offset: lower, in: text)
        let stop = String.Index(utf16Offset: upper, in: text)
        return String(text[start..<stop])
    }

    private mutating func refill() {
        text = Self.filler
        markedText = nil
        let end = text.utf16.count
        selectedUTF16 = end..<end
    }
}

final class SSHTerminalTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = max(0, offset) }
}

final class SSHTerminalTextRange: UITextRange {
    let from: SSHTerminalTextPosition
    let to: SSHTerminalTextPosition
    override var start: UITextPosition { from.offset <= to.offset ? from : to }
    override var end: UITextPosition { from.offset <= to.offset ? to : from }
    override var isEmpty: Bool { from.offset == to.offset }
    var startOffset: Int { min(from.offset, to.offset) }
    var endOffset: Int { max(from.offset, to.offset) }

    init(_ from: Int, _ to: Int) {
        self.from = SSHTerminalTextPosition(from)
        self.to = SSHTerminalTextPosition(to)
        super.init()
    }
}

extension SSHTerminalGridView {
    var selectedTextRange: UITextRange? {
        get {
            SSHTerminalTextRange(
                textInputStorage.selectedUTF16.lowerBound,
                textInputStorage.selectedUTF16.upperBound
            )
        }
        set {
            guard let range = newValue as? SSHTerminalTextRange else { return }
            textInputStorage.select(utf16Range: range.startOffset..<range.endOffset)
        }
    }

    var markedTextRange: UITextRange? {
        guard textInputStorage.markedText != nil else { return nil }
        return SSHTerminalTextRange(0, textInputStorage.utf16Count)
    }

    var beginningOfDocument: UITextPosition { SSHTerminalTextPosition(0) }
    var endOfDocument: UITextPosition { SSHTerminalTextPosition(textInputStorage.utf16Count) }
    var tokenizer: UITextInputTokenizer { textInputTokenizer }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        applyTextInput(textInputStorage.setMarkedText(markedText, selectedRange: selectedRange))
    }

    func unmarkText() {
        applyTextInput(textInputStorage.unmarkText(hardwareKeysDown: ignoresSoftwareKeyEcho))
        guard textInputStorage.awaitsCommitEcho else { return }
        let generation = textInputStorage.commitEchoGeneration
        Task { @MainActor [weak self] in
            self?.textInputStorage.expireCommitEcho(generation: generation)
        }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? SSHTerminalTextPosition,
              let to = toPosition as? SSHTerminalTextPosition else { return nil }
        return SSHTerminalTextRange(from.offset, to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let start = (position as? SSHTerminalTextPosition)?.offset ?? 0
        let next = start + offset
        guard next >= 0, next <= textInputStorage.utf16Count else { return nil }
        return SSHTerminalTextPosition(next)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let left = (position as? SSHTerminalTextPosition)?.offset ?? 0
        let right = (other as? SSHTerminalTextPosition)?.offset ?? 0
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? SSHTerminalTextPosition)?.offset ?? 0)
            - ((from as? SSHTerminalTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .right, .down: range.end
        default: range.start
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? SSHTerminalTextPosition else { return nil }
        let other: Int
        switch direction {
        case .right, .down: other = min(position.offset + 1, textInputStorage.utf16Count)
        default: other = max(position.offset - 1, 0)
        }
        return SSHTerminalTextRange(position.offset, other)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }

    func caretRect(for position: UITextPosition) -> CGRect {
        CGRect(x: bounds.minX, y: max(bounds.maxY - 1, bounds.minY), width: 1, height: 1)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    /// Hit tests never move the dummy caret off the end; see `select`.
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let position = closestPosition(to: point) else { return nil }
        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        let current = offset(from: beginningOfDocument, to: position)
        if current < min(start, end) { return start <= end ? range.start : range.end }
        if current > max(start, end) { return start <= end ? range.end : range.start }
        return position
    }

    // The space-bar trackpad drives these. No-ops keep the dummy caret at the
    // end, so the trackpad cannot stop held ⌫ from repeating. Moving the
    // shell cursor with it is not supported.
    func beginFloatingCursor(at point: CGPoint) {}
    func updateFloatingCursor(at point: CGPoint) {}
    func endFloatingCursor() {}

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) else { return nil }
        return characterRange(byExtending: position, in: .right)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? SSHTerminalTextRange else { return nil }
        return textInputStorage.text(in: range.startOffset..<range.endOffset)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? SSHTerminalTextRange else { return }
        applyTextInput(textInputStorage.replace(
            utf16Range: range.startOffset..<range.endOffset,
            with: text,
            hardwareKeysDown: ignoresSoftwareKeyEcho
        ))
    }
}

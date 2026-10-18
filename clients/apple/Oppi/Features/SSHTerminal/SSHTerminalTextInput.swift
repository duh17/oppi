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
    /// The last text the keyboard inserted, kept after the filler. Streaming
    /// dictation inserts a guess, then replaces it by finding it before the
    /// caret; without it here iOS cancels dictation after the first guess.
    /// `sent` is the start of it already in the shell. A phrase of more than
    /// one character waits until the owner takes it, so the shell gets the
    /// words iOS settled on, once.
    private(set) var phrase = ""
    private var sent = ""

    var utf16Count: Int { text.utf16.count }
    var awaitsCommitEcho: Bool { unmarkedCommit != nil }
    var hasUnsentPhrase: Bool { phrase.count > sent.count }

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
        let earlier = takeUnsentPhrase()
        refill()
        guard !hardwareKeysDown else { return earlier }
        if pending == nil, echo == string { return earlier }
        guard !string.isEmpty else { return earlier }
        // An IME commit is final; only plain insertions can be revised.
        guard pending == nil else { return earlier + [.insert(string)] }
        keepPhrase(string)
        // A keystroke goes at once. Several characters at once (dictation,
        // slide typing) wait for `takeUnsentPhrase`.
        guard string.count == 1 else { return earlier }
        sent = phrase
        return earlier + [.insert(string)]
    }

    /// The unsent rest of the phrase. The phrase stays, so dictation can
    /// still extend it; characters already sent are never sent again.
    mutating func takeUnsentPhrase() -> [Action] {
        guard hasUnsentPhrase else { return [] }
        let unsent = String(phrase.dropFirst(sent.count))
        sent = phrase
        return [.insert(unsent)]
    }

    /// Input that bypasses this document (an arrow, a paste, a hardware key)
    /// may move the shell's cursor, so the phrase ends after its unsent rest.
    mutating func finishPhrase() -> [Action] {
        guard markedText == nil, !phrase.isEmpty else { return [] }
        let rest = takeUnsentPhrase()
        refill()
        return rest
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
        let earlier = takeUnsentPhrase()
        refill()
        guard !hardwareKeysDown else { return earlier }
        return earlier + [.backspace]
    }

    mutating func setMarkedText(_ markedText: String?, selectedRange: NSRange) -> [Action] {
        unmarkedCommit = nil
        let earlier = takeUnsentPhrase()
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
            phrase = ""
            sent = ""
        }
        return earlier
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
        let fillerEnd = Self.filler.utf16.count
        if !hardwareKeysDown, !phrase.isEmpty, utf16Range.lowerBound >= fillerEnd, utf16Range.upperBound <= utf16Count {
            // Dictation revising its guess. What follows the sent text is
            // the new unsent rest. A guess that rewrites sent text cannot be
            // taken back from the shell, so that revision is dropped and
            // later words continue from it.
            let start = String.Index(utf16Offset: utf16Range.lowerBound - fillerEnd, in: phrase)
            let stop = String.Index(utf16Offset: utf16Range.upperBound - fillerEnd, in: phrase)
            var revised = phrase
            revised.replaceSubrange(start..<stop, with: string)
            let kept = sent
            keepPhrase(revised)
            sent = revised.hasPrefix(kept) ? kept : revised
            return []
        }
        let earlier = takeUnsentPhrase()
        refill()
        guard !hardwareKeysDown else { return earlier }
        if string.isEmpty { return earlier + [.backspace] }
        return earlier + [.insert(string)]
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

    private mutating func keepPhrase(_ string: String) {
        phrase = string
        sent = ""
        text = Self.filler + string
        let end = utf16Count
        selectedUTF16 = end..<end
    }

    private mutating func refill() {
        text = Self.filler
        markedText = nil
        phrase = ""
        sent = ""
        let end = text.utf16.count
        selectedUTF16 = end..<end
    }
}

/// The space-bar trackpad as arrow keys: one ←/→ per cell of horizontal
/// travel and one ↑/↓ per row of vertical travel from where the drag began.
/// Steps wait in `pending` so one write carries a frame's travel.
struct SSHTerminalTrackpadArrows: Equatable {
    struct Steps: Equatable {
        var columns = 0
        var rows = 0
        var isEmpty: Bool { columns == 0 && rows == 0 }
    }

    private var origin: CGPoint?
    private var counted = Steps()
    private(set) var pending = Steps()
    var isTracking: Bool { origin != nil }

    mutating func begin(at point: CGPoint) {
        origin = point
        counted = Steps()
    }

    mutating func update(to point: CGPoint, cell: CGSize) {
        guard let origin, cell.width > 0, cell.height > 0 else { return }
        // Whole cells only, rounded toward the start, so a drag that comes
        // back to where it began has sent equal and opposite steps.
        let columns = Int((point.x - origin.x) / cell.width)
        let rows = Int((point.y - origin.y) / cell.height)
        pending.columns += columns - counted.columns
        pending.rows += rows - counted.rows
        counted = Steps(columns: columns, rows: rows)
    }

    mutating func end() {
        origin = nil
        counted = Steps()
    }

    mutating func takePending() -> Steps {
        defer { pending = Steps() }
        return pending
    }
}

/// Held ⌫ deletes words after about a second, as iOS text fields do. The
/// owner sends Ctrl-W for a word only on the primary screen, where shells and
/// agent prompts read it as delete-word; a full-screen app may bind it to
/// something else (nano search, Emacs kill-region, a vim window command).
struct SSHTerminalDeleteAcceleration: Equatable {
    static let wordDeleteAfter: TimeInterval = 1.0
    /// The software keyboard sends its first repeat about this long after
    /// the press, then one every 0.1 s.
    static let softwareRepeatDelay: TimeInterval = 0.5
    /// Deletes further apart than this are separate presses. A tap rate
    /// that fast cannot be kept up for long, so taps do not accelerate.
    static let softwareRepeatGap: TimeInterval = 0.13

    private var runStart: TimeInterval?
    private var lastDelete: TimeInterval?

    /// Software ⌫: UIKit delivers each repeat like a press, so a hold is a
    /// run of deletes one repeat apart. The run starts at the first repeat,
    /// one repeat delay after the finger went down.
    mutating func softwareDeletesWord(at now: TimeInterval) -> Bool {
        defer { lastDelete = now }
        guard let lastDelete, let runStart, now - lastDelete <= Self.softwareRepeatGap else {
            runStart = now
            return false
        }
        return now - runStart + Self.softwareRepeatDelay >= Self.wordDeleteAfter
    }

    /// Hardware ⌫: our own repeater knows when the key went down.
    static func hardwareDeletesWord(heldFor duration: TimeInterval) -> Bool {
        duration >= wordDeleteAfter
    }

    mutating func reset() {
        runStart = nil
        lastDelete = nil
    }
}

/// ⌘ shortcuts the grid owns, offered to UIKit as key commands so they show
/// in the ⌘ overlay. UIKit delivers the press too; the press path leaves
/// these to the commands, so a shortcut never also types its letter. ⌘V
/// stays on the press path. ⌘. needs no command: iOS hands it over as Esc.
enum SSHTerminalHardwareShortcut: Int, CaseIterable {
    case copy
    case clearScreen

    var input: String {
        switch self {
        case .copy: "c"
        case .clearScreen: "k"
        }
    }

    var title: String {
        switch self {
        case .copy: "Copy"
        case .clearScreen: "Clear Screen"
        }
    }

    static func matching(input: String, modifiers: UIKeyModifierFlags) -> Self? {
        let chord = modifiers.intersection([.command, .control, .alternate, .shift])
        guard chord == .command else { return nil }
        let input = input.lowercased()
        return allCases.first { $0.input == input }
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

    // The space-bar trackpad drives these. They send arrow keys and never
    // move the dummy caret, so the trackpad cannot stop held ⌫ from
    // repeating. A composition in progress keeps its own caret.
    func beginFloatingCursor(at point: CGPoint) {
        guard textInputStorage.markedText == nil else { return }
        finishPhrase()
        trackpadArrows.begin(at: point)
    }

    func updateFloatingCursor(at point: CGPoint) {
        guard trackpadArrows.isTracking else { return }
        trackpadArrows.update(to: point, cell: cellSize)
        if !trackpadArrows.pending.isEmpty { requestDisplayLink() }
    }

    func endFloatingCursor() {
        trackpadArrows.end()
        flushTrackpadArrows()
    }

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

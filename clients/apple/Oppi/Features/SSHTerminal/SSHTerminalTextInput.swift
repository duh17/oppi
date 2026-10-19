import UIKit

/// The document the software keyboard edits, kept equal to what it typed
/// into the shell since the last reset, so the keyboard can edit it the way
/// it edits a text field. Streaming dictation inserts a guess and rewrites it
/// as you speak, then puts in its final text when you stop; each edit
/// reaches the shell as the backspaces and text that make the shell's line
/// match. The grid never paints this storage.
///
/// A filler character stands in front for whatever the shell already had,
/// so UIKit always has something to delete and held ⌫ keeps repeating.
/// Input that bypasses this document (an arrow, a paste, a hardware key,
/// Return) resets it to the filler.
struct SSHTerminalTextInputStorage: Equatable {
    enum Action: Equatable {
        /// Keys, one per character; a one-shot Ctrl or Alt applies.
        case insert(String)
        /// ⌫ on the keyboard; held, it speeds up to whole words.
        case backspace
        /// The keyboard rewrote the line (a suggestion, a slide-typed word,
        /// dictation): `deleting` backspaces, then `text`, in one write with
        /// no modifier.
        case edit(deleting: Int, text: String)
    }

    static let filler = " "

    private(set) var text: String
    /// UTF-16 range of an input method's composition. The shell gets it
    /// only once it is committed.
    private(set) var markedUTF16: Range<Int>?
    private(set) var selectedUTF16: Range<Int>
    /// UTF-16 length of the filler still at the front: 0 once an edit took
    /// it, and that edit sent the backspace it stands for.
    private var fillerUTF16: Int
    /// A commit `unmarkText` already sent. The keyboard may echo it through
    /// `insertText` in the same call stack; only that echo is dropped. The
    /// owner calls `expireCommitEcho` on the next main turn so a later,
    /// identical keystroke still sends.
    private var unmarkedCommit: String?
    private(set) var commitEchoGeneration = 0

    var utf16Count: Int { text.utf16.count }
    var markedText: String? { markedUTF16.map { slice($0) } }
    var awaitsCommitEcho: Bool { unmarkedCommit != nil }

    init(text: String = Self.filler) {
        self.text = text
        markedUTF16 = nil
        unmarkedCommit = nil
        fillerUTF16 = text.hasPrefix(Self.filler) ? Self.filler.utf16.count : 0
        let end = text.utf16.count
        selectedUTF16 = end..<end
    }

    mutating func insertText(_ string: String, hardwareKeysDown: Bool) -> [Action] {
        let echo = unmarkedCommit
        unmarkedCommit = nil
        guard !hardwareKeysDown else {
            reset()
            return []
        }
        if markedUTF16 == nil, echo == string { return [] }
        guard !string.isEmpty else { return [] }
        let composed = markedUTF16 != nil
        let change = replaceDocument(markedUTF16 ?? selectedUTF16, with: string)
        // A keystroke or an input method's commit spends a one-shot modifier
        // like a key does; anything else the keyboard puts in is one write.
        if change.deleting == 0, change.text == string, composed || string.count == 1 {
            return [.insert(string)]
        }
        return Self.actions(change)
    }

    mutating func deleteBackward(hardwareKeysDown: Bool) -> [Action] {
        unmarkedCommit = nil
        if let marked = markedUTF16 {
            // ⌫ edits the composition only.
            let caret = min(max(selectedUTF16.lowerBound, marked.lowerBound), marked.upperBound)
            let target = selectedUTF16.isEmpty ? characterRange(before: caret, from: marked.lowerBound) : selectedUTF16
            if let target {
                text = slice(0..<target.lowerBound) + slice(target.upperBound..<utf16Count)
                let length = marked.count - target.count
                markedUTF16 = length > 0 ? marked.lowerBound..<(marked.lowerBound + length) : nil
                selectedUTF16 = target.lowerBound..<target.lowerBound
            }
            if markedUTF16 == nil, text.isEmpty { reset() }
            return []
        }
        guard !hardwareKeysDown else {
            reset()
            return []
        }
        let target = selectedUTF16.isEmpty ? characterRange(before: selectedUTF16.lowerBound, from: 0) : selectedUTF16
        guard let target else {
            reset()
            return [.backspace]
        }
        let change = replaceDocument(target, with: "")
        if change.deleting == 1, change.text.isEmpty { return [.backspace] }
        return Self.actions(change)
    }

    mutating func setMarkedText(_ markedText: String?, selectedRange: NSRange) -> [Action] {
        unmarkedCommit = nil
        let next = markedText ?? ""
        let change = replaceDocument(markedUTF16 ?? selectedUTF16, with: next, marking: true)
        if let marked = markedUTF16 {
            let location = min(max(selectedRange.location, 0), marked.count)
            let length = min(max(selectedRange.length, 0), marked.count - location)
            let start = marked.lowerBound + location
            selectedUTF16 = start..<(start + length)
        }
        return Self.actions(change)
    }

    /// A commit already sent by `insertText` cleared the mark, so the
    /// `unmarkText` that follows it finds nothing and sends nothing.
    mutating func unmarkText(hardwareKeysDown: Bool) -> [Action] {
        unmarkedCommit = nil
        guard let marked = markedUTF16 else { return [] }
        guard !hardwareKeysDown else {
            reset()
            return []
        }
        let committed = slice(marked)
        let before = shellText
        markedUTF16 = nil
        selectedUTF16 = marked.upperBound..<marked.upperBound
        let change = Self.change(from: before, to: shellText)
        guard !committed.isEmpty else { return Self.actions(change) }
        unmarkedCommit = committed
        commitEchoGeneration &+= 1
        guard change.deleting == 0, change.text == committed else { return Self.actions(change) }
        return [.insert(committed)]
    }

    mutating func expireCommitEcho(generation: Int) {
        if generation == commitEchoGeneration { unmarkedCommit = nil }
    }

    mutating func replace(utf16Range: Range<Int>, with string: String, hardwareKeysDown: Bool) -> [Action] {
        if markedUTF16 != nil {
            return setMarkedText(
                string,
                selectedRange: NSRange(location: string.utf16.count, length: 0)
            )
        }
        unmarkedCommit = nil
        guard !hardwareKeysDown else {
            reset()
            return []
        }
        // A range from before a reset (dictation still revising the guess
        // it typed) no longer names text the shell has; clamped, it would
        // type the guess a second time.
        guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16Count else { return [] }
        return Self.actions(replaceDocument(utf16Range, with: string))
    }

    /// The caret stays at or after the filler, so ⌫ always has a character
    /// to delete and keeps repeating. The space-bar trackpad and hit tests
    /// would otherwise park it at 0, where UIKit stops deleting.
    mutating func select(utf16Range: Range<Int>) {
        let floor = markedUTF16 == nil ? fillerUTF16 : 0
        let end = utf16Count
        let lower = min(max(utf16Range.lowerBound, floor), end)
        let upper = min(max(utf16Range.upperBound, floor), end)
        selectedUTF16 = min(lower, upper)..<max(lower, upper)
    }

    /// Back to the filler alone. A commit echo still pending stays
    /// guarded: the reset may come from sending that commit.
    mutating func reset() {
        text = Self.filler
        markedUTF16 = nil
        fillerUTF16 = Self.filler.utf16.count
        let end = text.utf16.count
        selectedUTF16 = end..<end
    }

    /// Starts over after input that bypassed this document, keeping an
    /// input method's composition and its caret: the composition is not in
    /// the shell yet, and the input method is still editing it.
    mutating func restart() {
        guard let marked = markedUTF16 else {
            reset()
            return
        }
        let composition = slice(marked)
        let caret = min(max(selectedUTF16.lowerBound, marked.lowerBound), marked.upperBound) - marked.lowerBound
        reset()
        let start = utf16Count
        text += composition
        markedUTF16 = start..<utf16Count
        selectedUTF16 = (start + caret)..<(start + caret)
    }

    func text(in utf16Range: Range<Int>) -> String? {
        let end = utf16Count
        let lower = min(max(utf16Range.lowerBound, 0), end)
        let upper = min(max(utf16Range.upperBound, 0), end)
        guard lower <= upper else { return nil }
        return slice(lower..<upper)
    }

    /// What the shell has of this document: the text after the filler,
    /// without an uncommitted composition.
    private var shellText: String {
        let start = fillerUTF16
        guard let marked = markedUTF16 else { return slice(start..<utf16Count) }
        return slice(start..<max(start, marked.lowerBound)) + slice(max(start, marked.upperBound)..<utf16Count)
    }

    /// Replaces `range` and returns what the shell needs to match. The caret
    /// follows the edit as in a text field. `marking` makes `string` the
    /// composition; otherwise any composition ends and `string` is typed.
    private mutating func replaceDocument(
        _ range: Range<Int>,
        with string: String,
        marking: Bool = false
    ) -> (deleting: Int, text: String) {
        let end = utf16Count
        var lower = min(max(range.lowerBound, 0), end)
        var upper = min(max(range.upperBound, lower), end)
        // Nothing the shell has comes before the filler, so text put in
        // there goes after it.
        if lower == upper, lower < fillerUTF16 {
            lower = fillerUTF16
            upper = fillerUTF16
        }
        let before = shellText
        // An edit that takes the filler deletes the shell's character it
        // stands for.
        let tookFiller = lower < fillerUTF16
        text = slice(0..<lower) + string + slice(upper..<end)
        let inserted = string.utf16.count
        let delta = inserted - (upper - lower)
        if upper <= selectedUTF16.lowerBound {
            selectedUTF16 = (selectedUTF16.lowerBound + delta)..<(selectedUTF16.upperBound + delta)
        } else if lower < selectedUTF16.upperBound {
            selectedUTF16 = (lower + inserted)..<(lower + inserted)
        }
        markedUTF16 = marking && inserted > 0 ? lower..<(lower + inserted) : nil
        if tookFiller { fillerUTF16 = 0 }
        let change = tookFiller
            ? (deleting: before.count + 1, text: shellText)
            : Self.change(from: before, to: shellText)
        if text.isEmpty { reset() }
        return change
    }

    /// One backspace per character (grapheme), as ⌫ sends: agent editors
    /// such as pi delete a grapheme per backspace. readline deletes a code
    /// point, so a rewritten emoji with a modifier can leave a stray one.
    private static func change(from old: String, to new: String) -> (deleting: Int, text: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return (old.count - common, String(new.dropFirst(common)))
    }

    private static func actions(_ change: (deleting: Int, text: String)) -> [Action] {
        guard change.deleting > 0 || !change.text.isEmpty else { return [] }
        return [.edit(deleting: change.deleting, text: change.text)]
    }

    /// The last character before `offset`, not reaching before `floor`.
    private func characterRange(before offset: Int, from floor: Int) -> Range<Int>? {
        guard offset > floor else { return nil }
        let head = slice(floor..<offset)
        guard let last = head.last else { return nil }
        return (offset - String(last).utf16.count)..<offset
    }

    private func slice(_ range: Range<Int>) -> String {
        let units = text.utf16
        let start = units.index(units.startIndex, offsetBy: range.lowerBound)
        let stop = units.index(units.startIndex, offsetBy: range.upperBound)
        return String(decoding: units[start..<stop], as: UTF16.self)
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
        guard let marked = textInputStorage.markedUTF16 else { return nil }
        return SSHTerminalTextRange(marked.lowerBound, marked.upperBound)
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
        guard textInputStorage.markedUTF16 == nil else { return }
        resetTextInput()
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

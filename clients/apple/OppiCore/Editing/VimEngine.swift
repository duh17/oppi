import Foundation

/// One key as the Vim engine sees it. Printable keys arrive as `.char`,
/// whether typed on the software keyboard, a hardware keyboard, or the
/// editor's key bar.
enum VimKey: Equatable, Hashable, Sendable {
    case char(Character)
    case ctrl(Character)
    case escape
    case enter
    case backspace
    case tab
    case left
    case right
    case up
    case down

    /// Keys the engine accepts from a typed string (`insertText`).
    static func keys(for text: String) -> [VimKey] {
        text.map { character in
            switch character {
            case "\n", "\r", "\r\n": .enter
            case "\t": .tab
            default: .char(character)
            }
        }
    }

    var display: String {
        switch self {
        case .char(let character): String(character)
        case .ctrl(let character): "^" + character.uppercased()
        case .escape: "⎋"
        case .enter: "⏎"
        case .backspace: "⌫"
        case .tab: "⇥"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
    }
}

enum VimMode: Equatable, Sendable {
    case normal
    case insert
    case visual
    case visualLine

    var label: String {
        switch self {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "V-LINE"
        }
    }

    var isVisual: Bool { self == .visual || self == .visualLine }
}

/// Work the engine asks the editor to do.
enum VimHostRequest: Equatable, Sendable {
    case save
    case quit
    case saveAndQuit
    /// Open the command line with this prompt: `:`, `/`, or `?`.
    case commandLine(Character)
    case scrollCaret(VimScrollPosition)
}

enum VimScrollPosition: Equatable, Sendable {
    case top
    case center
    case bottom
}

/// The text the engine edits. Offsets are UTF-16. In Normal mode the caret
/// is a collapsed selection at the character under the block cursor.
@MainActor
protocol VimBuffer: AnyObject {
    var vimText: NSString { get }
    var vimSelection: NSRange { get }
    var vimVisibleLineCount: Int { get }
    var vimIndentation: CodeIndentation { get }
    func vimSelect(_ range: NSRange)
    func vimReplace(_ range: NSRange, with text: String)
    @discardableResult func vimUndo() -> Bool
    @discardableResult func vimRedo() -> Bool
}

/// Modal Vim editing over a `VimBuffer`.
///
/// Supported: counts; motions `h j k l w W b B e E ge gE 0 ^ $ g_ gg G { } %
/// f F t T ; , n N * # + - _ ⌃d ⌃u ⌃f ⌃b`; operators `d c y > < gu gU g~`
/// with motions, doubled for lines, and text objects `iw aw iW aW i" a" i'
/// a' i` a` i( a( ib i[ a[ i{ a{ iB i< a< ip ap`; `x X s S D C Y p P J gJ r
/// ~ u ⌃r .`; Insert entry `i a I A o O`; Visual `v V gv o`; `zz zt zb`;
/// command line `/ ? :w :q :wq :x :N :s :%s`. One unnamed register
/// (`"_` discards); yanks are mirrored to `onYank`.
@MainActor
final class VimEngine {
    private(set) var mode: VimMode = .normal
    private(set) var pendingKeys: [VimKey] = []
    /// Status-line message from the last command (`Pattern not found`, …).
    private(set) var message: String?

    weak var buffer: (any VimBuffer)?
    /// Called with every yanked or deleted text so the editor can mirror it
    /// to the system clipboard.
    var onYank: (String) -> Void = { _ in }

    private struct Register {
        var text = ""
        var linewise = false
    }

    private enum FindKind { case f, F, t, T }

    private var register = Register()
    private var lastFind: (character: Character, kind: FindKind)?
    private var lastSearch: (pattern: String, forward: Bool)?
    private var lastChange: (keys: [VimKey], inserted: String?)?
    private var changeKeys: [VimKey]?
    private var desiredColumn: Int?
    private var anchor = 0
    private var cursor = 0
    private var lastVisual: (anchor: Int, cursor: Int, mode: VimMode)?
    private var insertStart: (offset: Int, length: Int)?
    private var replaying = false

    init(buffer: (any VimBuffer)? = nil) {
        self.buffer = buffer
    }

    var pendingDisplay: String { pendingKeys.map(\.display).joined() }

    /// Typed counts stop at seven digits so count arithmetic cannot overflow;
    /// this is not a behavior limit (a file holds far fewer lines).
    static let maxLineCount = 9_999_999
    /// Largest text a single paste or Visual indent may build (a file is at
    /// most 1 MiB).
    static let maxEditLength = 2_097_152

    /// The Vim cursor. In Visual mode the selection's moving end, which the
    /// buffer's selection range alone does not tell.
    var cursorOffset: Int { cursor }

    // MARK: - Entry points

    /// Start in Normal mode on the current caret.
    func reset(to mode: VimMode = .normal) {
        pendingKeys = []
        message = nil
        guard let buffer else { return }
        if mode == .insert {
            enterInsert(at: buffer.vimSelection.location)
            return
        }
        self.mode = .normal
        place(clampNormal(buffer.vimSelection.location))
    }

    @discardableResult
    func handle(_ key: VimKey) -> [VimHostRequest] {
        guard buffer != nil else { return [] }
        if !replaying { message = nil }
        switch mode {
        case .insert:
            if key == .escape || key == .ctrl("[") || key == .ctrl("c") {
                leaveInsert()
            }
            return []
        case .normal, .visual, .visualLine:
            if key == .escape || key == .ctrl("[") || key == .ctrl("c") {
                pendingKeys = []
                if mode.isVisual { exitVisual() }
                return []
            }
            pendingKeys.append(key)
            switch parse(pendingKeys) {
            case .incomplete:
                return []
            case .invalid:
                pendingKeys = []
                return []
            case .command(let command):
                let keys = pendingKeys
                pendingKeys = []
                return execute(command, keys: keys)
            }
        }
    }

    /// The editor moved the selection itself (tap, drag, find).
    func selectionDidChange() {
        guard let buffer, mode != .insert else { return }
        let selection = buffer.vimSelection
        let text = buffer.vimText
        if selection.length > 0 {
            if mode == .normal { mode = .visual }
            anchor = selection.location
            cursor = previous(NSMaxRange(selection), in: text)
            return
        }
        if mode.isVisual { mode = .normal }
        let clamped = clampNormal(selection.location)
        cursor = clamped
        desiredColumn = nil
        if clamped != selection.location { buffer.vimSelect(NSRange(location: clamped, length: 0)) }
    }

    /// Run a command-line entry. `prompt` is `:`, `/`, or `?`.
    @discardableResult
    func runCommandLine(_ prompt: Character, _ entry: String) -> [VimHostRequest] {
        guard let buffer else { return [] }
        message = nil
        let wasVisual = mode.isVisual
        let visualLines = wasVisual ? visualRange(linewise: true) : nil
        if wasVisual { exitVisual() }
        switch prompt {
        case "/", "?":
            let pattern = entry.isEmpty ? (lastSearch?.pattern ?? "") : entry
            guard !pattern.isEmpty else { return [] }
            lastSearch = (pattern, prompt == "/")
            if let target = search(pattern, forward: prompt == "/", from: cursor) {
                place(target)
            }
            return []
        default:
            break
        }
        let command = entry.trimmingCharacters(in: .whitespaces)
        switch command {
        case "w", "write", "w!": return [.save]
        case "q", "quit": return [.quit]
        case "q!", "quit!":
            // Nothing to abandon: edits are already autosaving.
            message = "Edits autosave; use u to undo, or :q to close"
            return []
        case "wq", "wq!", "x", "x!", "xit", "exit": return [.saveAndQuit]
        case "noh", "nohlsearch", "": return []
        case "$":
            let lines = CodeLineIndex(buffer.vimText)
            place(firstNonBlank(lines.starts[lines.lineCount - 1]))
            return []
        default:
            break
        }
        if let number = Int(command) {
            let lines = CodeLineIndex(buffer.vimText)
            let line = min(max(1, number), lines.lineCount) - 1
            place(firstNonBlank(lines.starts[line]))
            return []
        }
        var rest = Substring(command)
        var scope: NSRange?
        if rest.hasPrefix("%") {
            scope = NSRange(location: 0, length: buffer.vimText.length)
            rest = rest.dropFirst()
        } else if rest.hasPrefix("'<,'>") {
            scope = visualLines ?? lastVisual.map { _ in visualRange(linewise: true, from: lastVisual) }
            rest = rest.dropFirst(5)
        }
        if rest.hasPrefix("s"), rest.count > 1, let delimiter = rest.dropFirst().first, !delimiter.isLetter {
            substitute(String(rest.dropFirst()), scope: scope ?? lineRangeIncludingBreak(cursor))
            return []
        }
        message = "Not an editor command: \(command)"
        return []
    }

    // MARK: - Parsing

    private enum Operator: Equatable {
        case delete, change, yank, indent, outdent, lower, upper, toggleCase
    }

    private enum Motion: Equatable {
        case left, right, down, up
        case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool), wordEndBackward(big: Bool)
        case lineStart, firstNonBlank, lineEnd, lastNonBlank
        case documentStart, documentEnd
        case paragraphForward, paragraphBackward
        case matchPair
        case find(Character, FindKind)
        case repeatFind(reverse: Bool)
        case searchNext(reverse: Bool)
        case searchWord(forward: Bool)
        case nextLine, previousLine, currentLine
        case halfPageDown, halfPageUp, pageDown, pageUp
    }

    private enum TextObject: Equatable {
        case word(big: Bool, around: Bool)
        case quote(Character, around: Bool)
        case pair(open: Character, close: Character, around: Bool)
        case paragraph(around: Bool)
    }

    private enum Action: Equatable {
        case motion(Motion)
        case operatorMotion(Operator, Motion)
        case operatorObject(Operator, TextObject)
        case operatorLines(Operator)
        case object(TextObject)
        case visualOperator(Operator, linewise: Bool)
        case insert(InsertPoint)
        case paste(after: Bool)
        case join(spaces: Bool)
        case replaceCharacter(Character)
        case toggleCaseUnderCursor
        case undo, redo, repeatChange
        case visual(VimMode)
        case reselect
        case swapVisualEnds
        case commandLine(Character)
        case scroll(VimScrollPosition)
    }

    private enum InsertPoint: Equatable {
        case beforeCursor, afterCursor, lineStart, lineEnd, lineBelow, lineAbove
    }

    private struct Command: Equatable {
        var count: Int?
        var action: Action
        var discardsRegister = false
    }

    private enum ParseResult: Equatable {
        case incomplete
        case invalid
        case command(Command)
    }

    private func parse(_ keys: [VimKey]) -> ParseResult {
        var index = 0
        var discards = false
        func next() -> VimKey? {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            return keys[index]
        }
        func peekCount() -> Int? {
            var digits = ""
            while index < keys.count, case .char(let character) = keys[index], character.isASCII, character.isNumber,
                  !(digits.isEmpty && character == "0") {
                digits.append(character)
                index += 1
            }
            // Kept as typed; `maxLineCount` only guards the count arithmetic.
            return digits.isEmpty ? nil : min(Int(digits.prefix(7)) ?? 1, Self.maxLineCount)
        }

        if case .char("\"") = keys.first {
            index = 1
            guard let register = next() else { return .incomplete }
            discards = register == .char("_")
        }
        let count = peekCount()
        guard let key = next() else { return .incomplete }
        func done(_ action: Action, count: Int? = count) -> ParseResult {
            index == keys.count ? .command(Command(count: count, action: action, discardsRegister: discards)) : .invalid
        }

        let visual = mode.isVisual

        // Motions. A key that is not a motion is re-read below.
        let afterKey = index
        switch parseMotion(first: key, next: next) {
        case .incomplete: return .incomplete
        case .motion(let motion): return done(.motion(motion))
        case .none: index = afterKey
        }

        if visual {
            switch key {
            case .char("i"), .char("a"):
                guard let objectKey = next() else { return .incomplete }
                guard let object = textObject(around: key == .char("a"), key: objectKey) else { return .invalid }
                return done(.object(object))
            case .char("d"), .char("x"): return done(.visualOperator(.delete, linewise: false))
            case .char("X"), .char("D"): return done(.visualOperator(.delete, linewise: true))
            case .char("c"), .char("s"): return done(.visualOperator(.change, linewise: false))
            case .char("C"), .char("S"), .char("R"): return done(.visualOperator(.change, linewise: true))
            case .char("y"): return done(.visualOperator(.yank, linewise: false))
            case .char("Y"): return done(.visualOperator(.yank, linewise: true))
            case .char(">"): return done(.visualOperator(.indent, linewise: true))
            case .char("<"): return done(.visualOperator(.outdent, linewise: true))
            case .char("~"): return done(.visualOperator(.toggleCase, linewise: false))
            case .char("u"): return done(.visualOperator(.lower, linewise: false))
            case .char("U"): return done(.visualOperator(.upper, linewise: false))
            case .char("J"): return done(.join(spaces: true))
            case .char("p"): return done(.paste(after: true))
            case .char("P"): return done(.paste(after: false))
            case .char("o"), .char("O"): return done(.swapVisualEnds)
            case .char("v"): return done(.visual(.visual))
            case .char("V"): return done(.visual(.visualLine))
            case .char(":"): return done(.commandLine(":"))
            case .char("r"):
                guard let replacement = next() else { return .incomplete }
                guard case .char(let character) = replacement else { return .invalid }
                return done(.replaceCharacter(character))
            case .char("g"):
                guard let second = next() else { return .incomplete }
                switch second {
                case .char("J"): return done(.join(spaces: false))
                case .char("u"): return done(.visualOperator(.lower, linewise: false))
                case .char("U"): return done(.visualOperator(.upper, linewise: false))
                case .char("~"): return done(.visualOperator(.toggleCase, linewise: false))
                default: return .invalid
                }
            default:
                return .invalid
            }
        }

        // Operators.
        var op: Operator?
        var opKey = key
        switch key {
        case .char("d"): op = .delete
        case .char("c"): op = .change
        case .char("y"): op = .yank
        case .char(">"): op = .indent
        case .char("<"): op = .outdent
        case .char("g"):
            guard index < keys.count else { return .incomplete }
            switch keys[index] {
            case .char("u"): op = .lower
            case .char("U"): op = .upper
            case .char("~"): op = .toggleCase
            default: break
            }
            if op != nil { opKey = keys[index]; index += 1 }
        default: break
        }
        if let op {
            let secondCount = peekCount()
            let total: Int? = switch (count, secondCount) {
            case let (first?, second?): min(first * second, Self.maxLineCount)
            case let (first?, nil): first
            case let (nil, second?): second
            case (nil, nil): nil
            }
            guard let motionKey = next() else { return .incomplete }
            if motionKey == opKey || (key == .char("g") && motionKey == .char("g") && index < keys.count && keys[index] == opKey) {
                if motionKey == .char("g") { index += 1 }
                return done(.operatorLines(op), count: total)
            }
            if key == .char("g"), motionKey == .char("g"), index == keys.count { return .incomplete }
            switch motionKey {
            case .char("i"), .char("a"):
                guard let objectKey = next() else { return .incomplete }
                guard let object = textObject(around: motionKey == .char("a"), key: objectKey) else { return .invalid }
                return done(.operatorObject(op, object), count: total)
            default:
                switch parseMotion(first: motionKey, next: next) {
                case .incomplete: return .incomplete
                case .motion(let motion): return done(.operatorMotion(op, motion), count: total)
                case .none: return .invalid
                }
            }
        }

        switch key {
        case .char("x"): return done(.operatorMotion(.delete, .right))
        case .char("X"): return done(.operatorMotion(.delete, .left))
        case .char("s"): return done(.operatorMotion(.change, .right))
        case .char("S"): return done(.operatorLines(.change))
        case .char("C"): return done(.operatorMotion(.change, .lineEnd))
        case .char("D"): return done(.operatorMotion(.delete, .lineEnd))
        case .char("Y"): return done(.operatorLines(.yank))
        case .char("p"): return done(.paste(after: true))
        case .char("P"): return done(.paste(after: false))
        case .char("J"): return done(.join(spaces: true))
        case .char("~"): return done(.toggleCaseUnderCursor)
        case .char("u"): return done(.undo)
        case .ctrl("r"): return done(.redo)
        case .char("."): return done(.repeatChange)
        case .char("i"): return done(.insert(.beforeCursor))
        case .char("a"): return done(.insert(.afterCursor))
        case .char("I"): return done(.insert(.lineStart))
        case .char("A"): return done(.insert(.lineEnd))
        case .char("o"): return done(.insert(.lineBelow))
        case .char("O"): return done(.insert(.lineAbove))
        case .char("v"): return done(.visual(.visual))
        case .char("V"): return done(.visual(.visualLine))
        case .char(":"): return done(.commandLine(":"))
        case .char("/"): return done(.commandLine("/"))
        case .char("?"): return done(.commandLine("?"))
        case .char("r"):
            guard let replacement = next() else { return .incomplete }
            guard case .char(let character) = replacement else { return .invalid }
            return done(.replaceCharacter(character))
        case .char("z"):
            guard let second = next() else { return .incomplete }
            switch second {
            case .char("z"), .char("."): return done(.scroll(.center))
            case .char("t"), .enter: return done(.scroll(.top))
            case .char("b"), .char("-"): return done(.scroll(.bottom))
            default: return .invalid
            }
        case .char("g"):
            guard let second = next() else { return .incomplete }
            switch second {
            case .char("J"): return done(.join(spaces: false))
            case .char("v"): return done(.reselect)
            default: return .invalid
            }
        default:
            return .invalid
        }
    }

    private enum MotionParse {
        case motion(Motion)
        case incomplete
        case none
    }

    private func parseMotion(first key: VimKey, next: () -> VimKey?) -> MotionParse {
        switch key {
        case .char("h"), .left, .backspace: return .motion(.left)
        case .char("l"), .right, .char(" "): return .motion(.right)
        case .char("j"), .down, .ctrl("n"): return .motion(.down)
        case .char("k"), .up, .ctrl("p"): return .motion(.up)
        case .char("w"): return .motion(.wordForward(big: false))
        case .char("W"): return .motion(.wordForward(big: true))
        case .char("b"): return .motion(.wordBackward(big: false))
        case .char("B"): return .motion(.wordBackward(big: true))
        case .char("e"): return .motion(.wordEnd(big: false))
        case .char("E"): return .motion(.wordEnd(big: true))
        case .char("0"): return .motion(.lineStart)
        case .char("^"): return .motion(.firstNonBlank)
        case .char("$"): return .motion(.lineEnd)
        case .char("G"): return .motion(.documentEnd)
        case .char("}"): return .motion(.paragraphForward)
        case .char("{"): return .motion(.paragraphBackward)
        case .char("%"): return .motion(.matchPair)
        case .char(";"): return .motion(.repeatFind(reverse: false))
        case .char(","): return .motion(.repeatFind(reverse: true))
        case .char("n"): return .motion(.searchNext(reverse: false))
        case .char("N"): return .motion(.searchNext(reverse: true))
        case .char("*"): return .motion(.searchWord(forward: true))
        case .char("#"): return .motion(.searchWord(forward: false))
        case .char("+"), .enter: return .motion(.nextLine)
        case .char("-"): return .motion(.previousLine)
        case .char("_"): return .motion(.currentLine)
        case .ctrl("d"): return .motion(.halfPageDown)
        case .ctrl("u"): return .motion(.halfPageUp)
        case .ctrl("f"): return .motion(.pageDown)
        case .ctrl("b"): return .motion(.pageUp)
        case .char("f"), .char("F"), .char("t"), .char("T"):
            guard let target = next() else { return .incomplete }
            guard case .char(let character) = target else { return .none }
            let kind: FindKind = switch key {
            case .char("f"): .f
            case .char("F"): .F
            case .char("t"): .t
            default: .T
            }
            return .motion(.find(character, kind))
        case .char("g"):
            // Only `g` motions; other `g` commands fall through to the caller,
            // which re-reads the keys from the start.
            guard let second = next() else { return .incomplete }
            switch second {
            case .char("g"): return .motion(.documentStart)
            case .char("e"): return .motion(.wordEndBackward(big: false))
            case .char("E"): return .motion(.wordEndBackward(big: true))
            case .char("_"): return .motion(.lastNonBlank)
            case .char("j"): return .motion(.down)
            case .char("k"): return .motion(.up)
            default: return .none
            }
        default:
            return .none
        }
    }

    private func textObject(around: Bool, key: VimKey) -> TextObject? {
        guard case .char(let character) = key else { return nil }
        switch character {
        case "w": return .word(big: false, around: around)
        case "W": return .word(big: true, around: around)
        case "\"", "'", "`": return .quote(character, around: around)
        case "(", ")", "b": return .pair(open: "(", close: ")", around: around)
        case "[", "]": return .pair(open: "[", close: "]", around: around)
        case "{", "}", "B": return .pair(open: "{", close: "}", around: around)
        case "<", ">": return .pair(open: "<", close: ">", around: around)
        case "p": return .paragraph(around: around)
        default: return nil
        }
    }

    // MARK: - Execution

    private func execute(_ command: Command, keys: [VimKey]) -> [VimHostRequest] {
        guard let buffer else { return [] }
        // Counts are never clamped. Every counted command makes at most one
        // buffer edit, and its loops stop when they stop making progress, so
        // work is bounded by the text, not the count. Only paste and Visual
        // indent can grow the text past the document; both check
        // `maxEditLength` before building anything.
        let count = max(1, command.count ?? 1)
        switch command.action {
        case .motion(let motion) where Self.isVertical(motion):
            // `j`/`k` remember the column they started from.
            if desiredColumn == nil { desiredColumn = cursor - lineStart(cursor) }
        case .motion:
            break
        default:
            desiredColumn = nil
        }
        switch command.action {
        case .motion(let motion):
            guard let target = motionTarget(motion, count: command.count, from: cursor, forOperator: false) else { return [] }
            moveCursor(to: target.position, motion: motion)
            if motion == .halfPageDown || motion == .pageDown || motion == .halfPageUp || motion == .pageUp {
                return [.scrollCaret(.center)]
            }
        case .operatorMotion(let op, var motion):
            // `cw` on a word changes to its end, like `ce`.
            if op == .change, case .wordForward(let big) = motion, !isBlank(at: cursor) {
                motion = .wordEnd(big: big)
            }
            guard let target = motionTarget(motion, count: command.count, from: cursor, forOperator: true) else { return [] }
            beginChange(op, keys: keys)
            let (range, linewise) = operatorRange(from: cursor, to: target)
            apply(op, range: range, linewise: linewise, discard: command.discardsRegister, count: 1)
        case .operatorObject(let op, let object):
            guard let (range, linewise) = objectRange(object, at: cursor) else { return [] }
            beginChange(op, keys: keys)
            apply(op, range: range, linewise: linewise, discard: command.discardsRegister, count: 1)
        case .operatorLines(let op):
            let text = buffer.vimText
            let startLine = lineStart(cursor)
            var end = startLine
            for _ in 1..<count {
                let nextLine = lineEnd(end)
                guard nextLine > end, nextLine < text.length else { break }
                end = nextLine
            }
            beginChange(op, keys: keys)
            apply(op, range: linewiseRange(from: startLine, to: end), linewise: true, discard: command.discardsRegister, count: 1)
        case .object(let object):
            guard let (range, linewise) = objectRange(object, at: cursor), range.length > 0 else { return [] }
            if linewise, mode == .visual { mode = .visualLine }
            anchor = range.location
            cursor = previous(NSMaxRange(range), in: buffer.vimText)
            showVisual()
        case .visualOperator(let op, let forceLinewise):
            let linewise = forceLinewise || mode == .visualLine
            let range = visualRange(linewise: linewise)
            lastVisual = (anchor, cursor, mode)
            mode = .normal
            apply(op, range: range, linewise: linewise, discard: command.discardsRegister, count: count)
        case .insert(let point):
            beginChange(nil, keys: keys)
            insert(at: point)
        case .paste(let after):
            if mode.isVisual {
                replaceVisualWithRegister(keepRegister: !after)
            } else {
                beginChange(nil, keys: keys)
                paste(after: after, count: count)
                endChange()
            }
        case .join(let spaces):
            if mode.isVisual {
                let range = visualRange(linewise: true)
                let lines = CodeTextEditing.lineContents(buffer.vimText, in: range).count
                exitVisual()
                place(range.location)
                join(lines: max(2, lines), spaces: spaces)
            } else {
                beginChange(nil, keys: keys)
                join(lines: max(2, count), spaces: spaces)
                endChange()
            }
        case .replaceCharacter(let character):
            if mode.isVisual {
                let range = visualRange(linewise: mode == .visualLine)
                exitVisual()
                let source = buffer.vimText.substring(with: range)
                let replaced = String(source.map { $0.isNewline ? $0 : character })
                buffer.vimReplace(range, with: replaced)
                place(clampNormal(range.location))
            } else {
                beginChange(nil, keys: keys)
                replaceCharacters(with: character, count: count)
                endChange()
            }
        case .toggleCaseUnderCursor:
            beginChange(nil, keys: keys)
            let text = buffer.vimText
            var end = cursor
            var toggled = 0
            while toggled < count, end < contentsEnd(cursor) {
                end = next(end, in: text)
                toggled += 1
            }
            guard end > cursor else { return [] }
            let range = NSRange(location: cursor, length: end - cursor)
            buffer.vimReplace(range, with: Self.toggledCase(text.substring(with: range)))
            place(clampNormal(end))
            endChange()
        case .undo:
            var undone = 0
            while undone < count, buffer.vimUndo() { undone += 1 }
            place(clampNormal(min(buffer.vimSelection.location, buffer.vimText.length)))
        case .redo:
            var redone = 0
            while redone < count, buffer.vimRedo() { redone += 1 }
            place(clampNormal(min(buffer.vimSelection.location, buffer.vimText.length)))
        case .repeatChange:
            repeatLastChange(count: command.count)
        case .visual(let target):
            if mode == target {
                exitVisual()
            } else {
                if !mode.isVisual {
                    anchor = cursor
                }
                mode = target
                showVisual()
            }
        case .reselect:
            guard let lastVisual else { return [] }
            let length = buffer.vimText.length
            anchor = min(lastVisual.anchor, max(0, length - 1))
            cursor = min(lastVisual.cursor, max(0, length - 1))
            mode = lastVisual.mode
            showVisual()
        case .swapVisualEnds:
            swap(&anchor, &cursor)
            showVisual()
        case .commandLine(let prompt):
            return [.commandLine(prompt)]
        case .scroll(let position):
            return [.scrollCaret(position)]
        }
        return []
    }

    // MARK: - Change recording

    private func beginChange(_ op: Operator?, keys: [VimKey]) {
        guard !replaying, op != .yank else { return }
        changeKeys = keys
    }

    private func endChange() {
        guard !replaying, let keys = changeKeys else { return }
        lastChange = (keys, nil)
        changeKeys = nil
    }

    private func repeatLastChange(count: Int?) {
        guard let lastChange, let buffer else { return }
        var keys = lastChange.keys
        if let count {
            while let first = keys.first, case .char(let character) = first, character.isNumber { keys.removeFirst() }
            keys = String(count).map { VimKey.char($0) } + keys
        }
        replaying = true
        defer { replaying = false }
        for key in keys { handle(key) }
        if mode == .insert {
            if let inserted = lastChange.inserted, !inserted.isEmpty {
                let selection = buffer.vimSelection
                buffer.vimReplace(selection, with: inserted)
                buffer.vimSelect(NSRange(location: selection.location + (inserted as NSString).length, length: 0))
            }
            leaveInsert()
        }
    }

    // MARK: - Insert

    private func insert(at point: InsertPoint) {
        guard let buffer else { return }
        let text = buffer.vimText
        switch point {
        case .beforeCursor:
            enterInsert(at: cursor)
        case .afterCursor:
            enterInsert(at: cursor < contentsEnd(cursor) ? next(cursor, in: text) : cursor)
        case .lineStart:
            enterInsert(at: firstNonBlank(cursor))
        case .lineEnd:
            enterInsert(at: contentsEnd(cursor))
        case .lineBelow:
            let edit = CodeTextEditing.insertLine(text, selection: NSRange(location: cursor, length: 0), below: true)
            buffer.vimReplace(edit.range, with: edit.replacement)
            enterInsert(at: edit.selection.location)
        case .lineAbove:
            let edit = CodeTextEditing.insertLine(text, selection: NSRange(location: cursor, length: 0), below: false)
            buffer.vimReplace(edit.range, with: edit.replacement)
            enterInsert(at: edit.selection.location)
        }
    }

    private func enterInsert(at offset: Int) {
        guard let buffer else { return }
        mode = .insert
        buffer.vimSelect(NSRange(location: offset, length: 0))
        insertStart = (offset, buffer.vimText.length)
    }

    private func leaveInsert() {
        guard let buffer else { return }
        let caret = buffer.vimSelection.location
        let text = buffer.vimText
        var inserted: String?
        if let start = insertStart {
            let grown = text.length - start.length
            if grown >= 0, caret == start.offset + grown, caret <= text.length {
                inserted = text.substring(with: NSRange(location: start.offset, length: grown))
            }
        }
        if !replaying, let keys = changeKeys {
            lastChange = (keys, inserted)
            changeKeys = nil
        }
        insertStart = nil
        mode = .normal
        let target = caret > lineStart(caret) ? previous(caret, in: text) : caret
        place(clampNormal(target))
    }

    // MARK: - Operators

    private func apply(_ op: Operator, range: NSRange, linewise: Bool, discard: Bool, count: Int) {
        guard let buffer else { return }
        let text = buffer.vimText
        let start = range.location
        switch op {
        case .yank:
            store(text.substring(with: range), linewise: linewise, discard: discard, isYank: true)
            // `yy` keeps the cursor; a yank that reaches back moves to its start.
            if !linewise || lineStart(start) < lineStart(cursor) { place(clampNormal(start)) }
        case .delete:
            store(text.substring(with: range), linewise: linewise, discard: discard)
            var removed = range
            // Deleting an unterminated last line takes the break before it,
            // so no blank line is left behind.
            if linewise, NSMaxRange(range) == text.length, range.location > 0, range.length > 0,
               !CodeText.isLineBreak(text.character(at: NSMaxRange(range) - 1)) {
                let breakLength = range.location >= 2 && text.character(at: range.location - 2) == CodeText.carriageReturn ? 2 : 1
                removed = NSRange(location: range.location - breakLength, length: range.length + breakLength)
            }
            buffer.vimReplace(removed, with: "")
            if linewise {
                let after = min(removed.location, buffer.vimText.length)
                place(firstNonBlank(lineStart(after)))
            } else {
                place(clampNormal(start))
            }
            endChange()
        case .change:
            store(text.substring(with: range), linewise: linewise, discard: discard)
            if linewise {
                var body = range
                while body.length > 0, CodeText.isLineBreak(text.character(at: NSMaxRange(body) - 1)) {
                    body.length -= 1
                }
                let indent = text.substring(with: CodeTextEditing.leadingWhitespace(
                    text,
                    line: NSRange(location: lineStart(body.location), length: contentsEnd(body.location) - lineStart(body.location))
                ))
                let lineBody = NSRange(location: lineStart(body.location), length: NSMaxRange(body) - lineStart(body.location))
                buffer.vimReplace(lineBody, with: indent)
                enterInsert(at: lineBody.location + (indent as NSString).length)
            } else {
                buffer.vimReplace(range, with: "")
                enterInsert(at: start)
            }
        case .indent, .outdent:
            // `{count}>` indents `count` levels in one edit.
            let indentation = buffer.vimIndentation
            if op == .indent {
                let lineCount = CodeTextEditing.lineContents(text, in: CodeTextEditing.lineBlock(text, selection: range)).count
                guard lineCount * count * (indentation.unit as NSString).length <= Self.maxEditLength else {
                    message = "Too much to indent"
                    place(clampNormal(cursor))
                    return
                }
            }
            let edit = op == .indent
                ? CodeTextEditing.indent(text, selection: range, indentation: indentation, levels: count)
                : CodeTextEditing.outdent(text, selection: range, indentation: indentation, levels: count)
            if let edit { buffer.vimReplace(edit.range, with: edit.replacement) }
            place(firstNonBlank(lineStart(start)))
            endChange()
        case .lower, .upper, .toggleCase:
            let source = text.substring(with: range)
            let changed: String = switch op {
            case .lower: source.lowercased()
            case .upper: source.uppercased()
            default: Self.toggledCase(source)
            }
            buffer.vimReplace(range, with: changed)
            place(clampNormal(start))
            endChange()
        }
    }

    /// Fill the unnamed register. Only explicit yanks reach `onYank` (the
    /// system clipboard); deletes and changes stay inside the editor.
    private func store(_ text: String, linewise: Bool, discard: Bool, isYank: Bool = false) {
        guard !discard else { return }
        var stored = text
        if linewise, !(stored.last?.isNewline ?? false) { stored += "\n" }
        register = Register(text: stored, linewise: linewise)
        if isYank { onYank(stored) }
    }

    private static func toggledCase(_ text: String) -> String {
        String(text.map { character in
            let upper = character.uppercased()
            return upper == String(character) ? Character(character.lowercased()) : Character(upper)
        })
    }

    /// Range an operator covers between `start` and a motion target.
    private func operatorRange(from start: Int, to target: MotionTarget) -> (NSRange, Bool) {
        guard let buffer else { return (NSRange(location: start, length: 0), false) }
        let text = buffer.vimText
        let low = min(start, target.position)
        let high = max(start, target.position)
        switch target.kind {
        case .linewise:
            return (linewiseRange(from: lineStart(low), to: lineStart(high)), true)
        case .inclusive:
            let end = high < contentsEnd(high) ? next(high, in: text) : high
            return (NSRange(location: low, length: end - low), false)
        case .exclusive:
            var end = high
            // An exclusive motion that lands at the start of a later line
            // stops at the end of the line before it.
            if end > low, end == lineStart(end), lineStart(low) != lineStart(end) {
                end = contentsEnd(end - 1)
                if low <= firstNonBlank(lineStart(low)) {
                    return (linewiseRange(from: low, to: end), true)
                }
            }
            return (NSRange(location: low, length: max(0, end - low)), false)
        }
    }

    /// Lines from the one at `first` through the one at `last`, with the last
    /// line's break when it has one.
    private func linewiseRange(from first: Int, to last: Int) -> NSRange {
        let start = lineStart(first)
        return NSRange(location: start, length: lineEnd(last) - start)
    }

    private func lineRangeIncludingBreak(_ offset: Int) -> NSRange {
        NSRange(location: lineStart(offset), length: lineEnd(offset) - lineStart(offset))
    }

    // MARK: - Paste, join, replace

    private func paste(after: Bool, count: Int) {
        guard let buffer, !register.text.isEmpty else { return }
        // A file can be at most 1 MiB; never build a paste far past that.
        guard (register.text as NSString).length * count <= Self.maxEditLength else {
            message = "Too much to paste"
            return
        }
        let text = buffer.vimText
        let payload = String(repeating: register.text, count: count)
        if register.linewise {
            if after {
                let end = lineEnd(cursor)
                if end == text.length, !hasTrailingBreak(cursor) {
                    var body = payload
                    if body.last?.isNewline ?? false { body.removeLast() }
                    buffer.vimReplace(NSRange(location: end, length: 0), with: "\n" + body)
                    place(firstNonBlank(end + 1))
                } else {
                    buffer.vimReplace(NSRange(location: end, length: 0), with: payload)
                    place(firstNonBlank(end))
                }
            } else {
                let start = lineStart(cursor)
                buffer.vimReplace(NSRange(location: start, length: 0), with: payload)
                place(firstNonBlank(start))
            }
            return
        }
        let at = after && cursor < contentsEnd(cursor) ? next(cursor, in: text) : cursor
        buffer.vimReplace(NSRange(location: at, length: 0), with: payload)
        let length = (payload as NSString).length
        if payload.contains(where: \.isNewline) {
            place(at)
        } else {
            place(clampNormal(previous(at + length, in: buffer.vimText)))
        }
    }

    private func replaceVisualWithRegister(keepRegister: Bool) {
        guard let buffer else { return }
        let linewise = mode == .visualLine
        let range = visualRange(linewise: linewise)
        let saved = register
        let replaced = buffer.vimText.substring(with: range)
        lastVisual = (anchor, cursor, mode)
        mode = .normal
        var payload = saved.text
        if saved.linewise, !linewise, payload.last?.isNewline ?? false {
            payload = "\n" + payload
        }
        let rangeHasBreak = range.length > 0 && CodeText.isLineBreak(buffer.vimText.character(at: NSMaxRange(range) - 1))
        if linewise, rangeHasBreak, !(payload.last?.isNewline ?? false) {
            payload += "\n"
        } else if linewise, !rangeHasBreak, payload.last?.isNewline ?? false {
            payload.removeLast()
        }
        buffer.vimReplace(range, with: payload)
        if !keepRegister { store(replaced, linewise: linewise, discard: false) }
        place(clampNormal(range.location))
    }

    /// Join `lines` lines starting at the cursor's as one edit. `J` drops the
    /// next line's indentation and the current trailing blanks and puts one
    /// space between (none before `)` or an empty line); `gJ` joins as is.
    /// The cursor lands on the last join.
    private func join(lines: Int, spaces: Bool) {
        guard let buffer else { return }
        let text = buffer.vimText
        let first = lineStart(cursor)
        var line = first
        var joined = text.substring(with: NSRange(location: first, length: contentsEnd(first) - first))
        // UTF-16 length kept alongside: re-measuring a growing non-ASCII
        // String each pass would make `9999J` quadratic.
        var joinedLength = contentsEnd(first) - first
        var lastJoin: Int?
        var count = 1
        while count < lines {
            let next = lineEnd(line)
            guard next > contentsEnd(line), contentsEnd(line) < text.length else { break }
            line = next
            var body = text.substring(with: NSRange(location: line, length: contentsEnd(line) - line))
            if spaces {
                body = String(body.drop { $0 == " " || $0 == "\t" })
                while let last = joined.last, last == " " || last == "\t" {
                    joined.removeLast()
                    joinedLength -= 1
                }
            }
            let separator = spaces && !body.isEmpty && !body.hasPrefix(")") && !joined.isEmpty ? " " : ""
            lastJoin = first + joinedLength
            joined += separator + body
            joinedLength += separator.utf16.count + body.utf16.count
            count += 1
        }
        guard let lastJoin else { return }
        buffer.vimReplace(NSRange(location: first, length: contentsEnd(line) - first), with: joined)
        place(clampNormal(lastJoin))
    }

    private func replaceCharacters(with character: Character, count: Int) {
        guard let buffer else { return }
        let text = buffer.vimText
        var end = cursor
        var replaced = 0
        while replaced < count, end < contentsEnd(cursor) {
            end = next(end, in: text)
            replaced += 1
        }
        guard replaced == count else { return }
        buffer.vimReplace(NSRange(location: cursor, length: end - cursor), with: String(repeating: String(character), count: count))
        place(clampNormal(cursor + (String(repeating: String(character), count: count) as NSString).length - 1))
    }

    // MARK: - Visual

    private func visualRange(linewise: Bool, from saved: (anchor: Int, cursor: Int, mode: VimMode)? = nil) -> NSRange {
        guard let buffer else { return NSRange(location: 0, length: 0) }
        let text = buffer.vimText
        let a = saved?.anchor ?? anchor
        let c = saved?.cursor ?? cursor
        let low = min(min(a, c), text.length)
        let high = min(max(a, c), text.length)
        if linewise {
            return NSRange(location: lineStart(low), length: lineEnd(high) - lineStart(low))
        }
        let end = high < text.length ? next(high, in: text) : high
        return NSRange(location: low, length: end - low)
    }

    private func showVisual() {
        guard let buffer else { return }
        buffer.vimSelect(visualRange(linewise: mode == .visualLine))
    }

    private func exitVisual() {
        lastVisual = (anchor, cursor, mode)
        mode = .normal
        place(clampNormal(cursor))
    }

    // MARK: - Cursor

    private func place(_ offset: Int) {
        guard let buffer else { return }
        cursor = max(0, min(offset, buffer.vimText.length))
        if mode.isVisual {
            showVisual()
        } else if mode == .normal {
            buffer.vimSelect(NSRange(location: cursor, length: 0))
        }
    }

    private static func isVertical(_ motion: Motion) -> Bool {
        switch motion {
        case .up, .down, .halfPageDown, .halfPageUp, .pageDown, .pageUp: true
        default: false
        }
    }

    private func moveCursor(to target: Int, motion: Motion) {
        let clamped = mode == .normal ? clampNormal(target) : clampVisual(target)
        if !Self.isVertical(motion) {
            desiredColumn = motion == .lineEnd ? Int.max : clamped - lineStart(clamped)
        }
        place(clamped)
    }

    // MARK: - Motions

    private struct MotionTarget {
        enum Kind { case exclusive, inclusive, linewise }
        var position: Int
        var kind: Kind
    }

    private func motionTarget(_ motion: Motion, count explicitCount: Int?, from start: Int, forOperator: Bool) -> MotionTarget? {
        guard let buffer else { return nil }
        let text = buffer.vimText
        let length = text.length
        // Line numbers (`G`, `gg`) read `explicitCount` as the line itself.
        let count = max(1, explicitCount ?? 1)
        var position = start
        /// Step `count` times, stopping as soon as a step makes no progress,
        /// so the work is bounded by the text, not the count.
        func repeated(_ step: (Int) -> Int) -> Int {
            var current = start
            var steps = 0
            while steps < count {
                let next = step(current)
                if next == current { break }
                current = next
                steps += 1
            }
            return current
        }
        switch motion {
        case .left:
            let first = lineStart(start)
            position = repeated { $0 > first ? self.previous($0, in: text) : $0 }
            return position == start ? nil : MotionTarget(position: position, kind: .exclusive)
        case .right:
            let limit = forOperator ? contentsEnd(start) : lastCharacter(start)
            position = repeated { $0 < limit ? self.next($0, in: text) : $0 }
            return position == start ? nil : MotionTarget(position: min(position, limit), kind: .exclusive)
        case .down, .up:
            return verticalTarget(lines: motion == .down ? count : -count, from: start)
        case .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            let page = max(1, buffer.vimVisibleLineCount)
            let lines = (motion == .halfPageDown || motion == .halfPageUp) ? max(1, page / 2) * count : max(1, page - 2) * count
            return verticalTarget(lines: (motion == .halfPageDown || motion == .pageDown) ? lines : -lines, from: start)
        case .wordForward(let big):
            var step = 0
            while step < count {
                let stops = forOperator && step == count - 1
                let next = wordForward(from: position, big: big, stopAtLineEnd: stops)
                step += 1
                if next == position { break }
                position = next
            }
            return MotionTarget(position: min(position, length), kind: .exclusive)
        case .wordBackward(let big):
            position = repeated { self.wordBackward(from: $0, big: big) }
            return position == start ? nil : MotionTarget(position: position, kind: .exclusive)
        case .wordEnd(let big):
            position = repeated { min(self.wordEnd(from: $0, big: big), max(0, length - 1)) }
            return MotionTarget(position: min(position, max(0, length - 1)), kind: .inclusive)
        case .wordEndBackward(let big):
            position = repeated { self.wordEndBackward(from: $0, big: big) }
            return MotionTarget(position: position, kind: .inclusive)
        case .lineStart:
            return MotionTarget(position: lineStart(start), kind: .exclusive)
        case .firstNonBlank:
            return MotionTarget(position: firstNonBlank(start), kind: .exclusive)
        case .lineEnd:
            var line = start
            for _ in 1..<count {
                let nextLine = lineEnd(line)
                guard nextLine < length else { break }
                line = nextLine
            }
            return MotionTarget(position: lastCharacter(line), kind: .inclusive)
        case .lastNonBlank:
            var end = contentsEnd(start)
            while end > lineStart(start), CodeText.isBlank(text.character(at: end - 1)) { end -= 1 }
            return MotionTarget(position: end > lineStart(start) ? previous(end, in: text) : lineStart(start), kind: .inclusive)
        case .documentStart, .documentEnd:
            let lines = CodeLineIndex(text)
            let line: Int
            if let explicitCount {
                line = min(max(1, explicitCount), lines.lineCount) - 1
            } else {
                line = motion == .documentStart ? 0 : lines.lineCount - 1
            }
            return MotionTarget(position: firstNonBlank(lines.starts[line]), kind: .linewise)
        case .paragraphForward:
            var line = lineStart(start)
            for _ in 0..<count {
                if line >= length { break }
                // Leave the blank lines we are on, then stop at the next blank.
                while line < length, isBlankLine(line) { line = lineEnd(line) }
                while line < length, !isBlankLine(line) {
                    let nextLine = lineEnd(line)
                    if nextLine >= length, !hasTrailingBreak(line) {
                        return MotionTarget(position: forOperator ? length : lastCharacter(line), kind: forOperator ? .exclusive : .inclusive)
                    }
                    line = nextLine
                }
            }
            return MotionTarget(position: min(line, length), kind: .exclusive)
        case .paragraphBackward:
            var line = lineStart(start)
            for _ in 0..<count {
                if line == 0 { break }
                while line > 0, isBlankLine(line) { line = lineStart(line - 1) }
                while line > 0, !isBlankLine(line) { line = lineStart(line - 1) }
            }
            return MotionTarget(position: line, kind: .exclusive)
        case .matchPair:
            guard let match = matchingPair(from: start) else { return nil }
            return MotionTarget(position: match, kind: .inclusive)
        case .find(let character, let kind):
            lastFind = (character, kind)
            return findTarget(character, kind: kind, count: count, from: start, repeating: false)
        case .repeatFind(let reverse):
            guard let lastFind else { return nil }
            var kind = lastFind.kind
            if reverse {
                kind = switch kind {
                case .f: .F
                case .F: .f
                case .t: .T
                case .T: .t
                }
            }
            return findTarget(lastFind.character, kind: kind, count: count, from: start, repeating: true)
        case .searchNext(let reverse):
            guard let lastSearch else {
                message = "No previous search"
                return nil
            }
            guard let found = search(lastSearch.pattern, forward: lastSearch.forward != reverse, from: position, count: count) else {
                return nil
            }
            return MotionTarget(position: found, kind: .exclusive)
        case .searchWord(let forward):
            guard let (word, wordStart) = wordUnderCursor(start) else { return nil }
            let pattern = "\\<" + NSRegularExpression.escapedPattern(for: word) + "\\>"
            lastSearch = (pattern, forward)
            // From the word's start, as Vim does, so `#` never lands on the
            // word the cursor is already in.
            guard let found = search(pattern, forward: forward, from: wordStart, count: count) else { return nil }
            return MotionTarget(position: found, kind: .exclusive)
        case .nextLine, .previousLine, .currentLine:
            let delta = motion == .nextLine ? count : (motion == .previousLine ? -count : count - 1)
            guard let target = verticalTarget(lines: delta, from: start) else { return nil }
            return MotionTarget(position: firstNonBlank(target.position), kind: .linewise)
        }
    }

    private func verticalTarget(lines delta: Int, from start: Int) -> MotionTarget? {
        guard let buffer else { return nil }
        let length = buffer.vimText.length
        var line = lineStart(start)
        var moved = 0
        if delta > 0 {
            while moved < delta {
                let nextLine = lineEnd(line)
                guard nextLine > line, nextLine < length || (nextLine == length && hasTrailingBreak(line)) else { break }
                line = nextLine
                moved += 1
            }
        } else {
            while moved < -delta, line > 0 {
                line = lineStart(line - 1)
                moved += 1
            }
        }
        guard moved > 0 || delta == 0 else { return nil }
        let column = desiredColumn ?? (start - lineStart(start))
        let target = column == Int.max ? lastCharacter(line) : min(line + column, lastCharacter(line))
        return MotionTarget(position: target, kind: .linewise)
    }

    private func findTarget(_ character: Character, kind: FindKind, count: Int, from start: Int, repeating: Bool) -> MotionTarget? {
        guard let buffer else { return nil }
        let text = buffer.vimText
        let needle = Array(String(character).utf16)
        guard needle.count == 1 else { return nil }
        let unit = needle[0]
        let lineFirst = lineStart(start)
        let lineLast = contentsEnd(start)
        var position = start
        let forward = kind == .f || kind == .t
        if repeating {
            if kind == .t { position += 1 }
            if kind == .T { position -= 1 }
        }
        for _ in 0..<count {
            var probe = forward ? position + 1 : position - 1
            var found: Int?
            while probe >= lineFirst, probe < lineLast {
                if text.character(at: probe) == unit {
                    found = probe
                    break
                }
                probe += forward ? 1 : -1
            }
            guard let found else { return nil }
            position = found
        }
        switch kind {
        case .f: return MotionTarget(position: position, kind: .inclusive)
        case .t: return MotionTarget(position: position - 1, kind: .inclusive)
        case .F: return MotionTarget(position: position, kind: .exclusive)
        case .T: return MotionTarget(position: position + 1, kind: .exclusive)
        }
    }

    private func matchingPair(from start: Int) -> Int? {
        guard let buffer else { return nil }
        let text = buffer.vimText
        let pairs: [unichar: (unichar, Bool)] = [
            0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
            0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false),
        ]
        var origin = start
        while origin < contentsEnd(start), pairs[text.character(at: origin)] == nil { origin += 1 }
        guard origin < contentsEnd(start), let (partner, forward) = pairs[text.character(at: origin)] else { return nil }
        let own = text.character(at: origin)
        var depth = 0
        var index = origin
        while index >= 0, index < text.length {
            let unit = text.character(at: index)
            if unit == own { depth += 1 } else if unit == partner {
                depth -= 1
                if depth == 0 { return index }
            }
            index += forward ? 1 : -1
        }
        return nil
    }

    // MARK: - Words

    /// 0 blank, 1 punctuation, 2 word. Big words merge 1 and 2.
    private func wordClass(_ offset: Int, big: Bool) -> Int {
        guard let buffer, offset >= 0, offset < buffer.vimText.length else { return 0 }
        let unit = buffer.vimText.character(at: offset)
        if CodeText.isBlank(unit) || CodeText.isLineBreak(unit) { return 0 }
        if big { return 2 }
        return CodeTextEditing.isWordUnit(unit) ? 2 : 1
    }

    private func isBlank(at offset: Int) -> Bool { wordClass(offset, big: true) == 0 }

    private func isLineBreak(at offset: Int) -> Bool {
        guard let buffer, offset >= 0, offset < buffer.vimText.length else { return false }
        return CodeText.isLineBreak(buffer.vimText.character(at: offset))
    }

    private func wordForward(from start: Int, big: Bool, stopAtLineEnd: Bool) -> Int {
        guard let buffer else { return start }
        let length = buffer.vimText.length
        var position = start
        let kind = wordClass(position, big: big)
        if kind != 0 {
            while position < length, wordClass(position, big: big) == kind { position += 1 }
        }
        while position < length, wordClass(position, big: big) == 0 {
            if isLineBreak(at: position) {
                if stopAtLineEnd { return position }
                position = lineEnd(position)
                if position < length, isLineBreak(at: position) { return position }
                continue
            }
            position += 1
        }
        return position
    }

    private func wordBackward(from start: Int, big: Bool) -> Int {
        var position = start - 1
        guard position >= 0 else { return 0 }
        while position > 0, wordClass(position, big: big) == 0 {
            // An empty line counts as a word.
            if isLineBreak(at: position), isLineBreak(at: position - 1) { return lineStart(position) }
            position -= 1
        }
        let kind = wordClass(position, big: big)
        while position > 0, wordClass(position - 1, big: big) == kind, kind != 0 { position -= 1 }
        return position
    }

    private func wordEnd(from start: Int, big: Bool) -> Int {
        guard let buffer else { return start }
        let length = buffer.vimText.length
        var position = start + 1
        while position < length, wordClass(position, big: big) == 0 { position += 1 }
        guard position < length else { return max(0, length - 1) }
        let kind = wordClass(position, big: big)
        while position + 1 < length, wordClass(position + 1, big: big) == kind { position += 1 }
        return position
    }

    private func wordEndBackward(from start: Int, big: Bool) -> Int {
        var position = start
        let kind = wordClass(position, big: big)
        if kind != 0 {
            while position > 0, wordClass(position, big: big) == kind { position -= 1 }
        }
        while position > 0, wordClass(position, big: big) == 0 { position -= 1 }
        return position
    }

    /// The keyword under (or after) the cursor and where it starts.
    private func wordUnderCursor(_ offset: Int) -> (word: String, start: Int)? {
        guard let buffer else { return nil }
        let text = buffer.vimText
        var start = offset
        while start < contentsEnd(offset), wordClass(start, big: false) != 2 { start += 1 }
        guard start < contentsEnd(offset) else { return nil }
        var end = start
        while start > lineStart(offset), wordClass(start - 1, big: false) == 2 { start -= 1 }
        while end < contentsEnd(offset), wordClass(end, big: false) == 2 { end += 1 }
        return (text.substring(with: NSRange(location: start, length: end - start)), start)
    }

    // MARK: - Text objects

    private func objectRange(_ object: TextObject, at offset: Int) -> (NSRange, Bool)? {
        guard let buffer else { return nil }
        let text = buffer.vimText
        switch object {
        case .word(let big, let around):
            let first = lineStart(offset)
            let last = contentsEnd(offset)
            guard offset < last else { return nil }
            let kind = wordClass(offset, big: big)
            var start = offset
            var end = offset
            while start > first, wordClass(start - 1, big: big) == kind { start -= 1 }
            while end < last, wordClass(end, big: big) == kind { end += 1 }
            if around {
                if kind == 0 {
                    let wordKind = wordClass(end, big: big)
                    while end < last, wordClass(end, big: big) == wordKind, wordKind != 0 { end += 1 }
                } else if end < last, wordClass(end, big: big) == 0 {
                    while end < last, wordClass(end, big: big) == 0 { end += 1 }
                } else {
                    while start > first, wordClass(start - 1, big: big) == 0 { start -= 1 }
                }
            }
            return (NSRange(location: start, length: end - start), false)
        case .quote(let character, let around):
            guard let unit = String(character).utf16.first else { return nil }
            let first = lineStart(offset)
            let last = contentsEnd(offset)
            var quotes: [Int] = []
            var index = first
            while index < last {
                let current = text.character(at: index)
                if current == 0x5C { index += 2; continue }
                if current == unit { quotes.append(index) }
                index += 1
            }
            var pairStart: Int?
            var pairEnd: Int?
            var pairIndex = 0
            while pairIndex + 1 < quotes.count {
                let open = quotes[pairIndex]
                let close = quotes[pairIndex + 1]
                if offset <= close {
                    pairStart = open
                    pairEnd = close
                    break
                }
                pairIndex += 2
            }
            guard let pairStart, let pairEnd else { return nil }
            return around
                ? (NSRange(location: pairStart, length: pairEnd - pairStart + 1), false)
                : (NSRange(location: pairStart + 1, length: pairEnd - pairStart - 1), false)
        case .pair(let open, let close, let around):
            guard let openUnit = String(open).utf16.first, let closeUnit = String(close).utf16.first else { return nil }
            var start: Int?
            var depth = 0
            var index = offset
            if index < text.length, text.character(at: index) == closeUnit { index -= 1; depth = 0 }
            if offset < text.length, text.character(at: offset) == openUnit {
                start = offset
            } else {
                while index >= 0 {
                    let unit = text.character(at: index)
                    if unit == closeUnit, index != offset { depth += 1 }
                    if unit == openUnit {
                        if depth == 0 {
                            start = index
                            break
                        }
                        depth -= 1
                    }
                    index -= 1
                }
            }
            guard let start else { return nil }
            depth = 0
            var end: Int?
            index = start
            while index < text.length {
                let unit = text.character(at: index)
                if unit == openUnit { depth += 1 }
                if unit == closeUnit {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
                index += 1
            }
            guard let end else { return nil }
            if around { return (NSRange(location: start, length: end - start + 1), false) }
            var innerStart = start + 1
            var innerEnd = end
            // `di{` on a block keeps the braces on their own lines.
            if innerStart < innerEnd, isLineBreak(at: innerStart) {
                innerStart = lineEnd(innerStart)
                let closerLine = lineStart(end)
                if closerLine > innerStart,
                   (closerLine..<end).allSatisfy({ CodeText.isBlank(text.character(at: $0)) }) {
                    innerEnd = closerLine
                }
            }
            return (NSRange(location: innerStart, length: max(0, innerEnd - innerStart)), false)
        case .paragraph(let around):
            let blank = isBlankLine(offset)
            var first = lineStart(offset)
            while first > 0, isBlankLine(lineStart(first - 1)) == blank { first = lineStart(first - 1) }
            var last = lineStart(offset)
            while lineEnd(last) < text.length, isBlankLine(lineEnd(last)) == blank { last = lineEnd(last) }
            if around {
                while lineEnd(last) < text.length, isBlankLine(lineEnd(last)) != blank { last = lineEnd(last) }
            }
            return (linewiseRange(from: first, to: last), true)
        }
    }

    // MARK: - Search

    /// Smart case: a capital letter in the pattern (not an escape such as
    /// `\W`) makes it case-sensitive; `ignoreCase` (`:s///i`) always ignores case.
    private func regex(for pattern: String, ignoreCase: Bool = false) -> NSRegularExpression? {
        var caseSensitive = false
        var escaped = false
        for character in pattern {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character.isUppercase {
                caseSensitive = true
            }
        }
        if ignoreCase { caseSensitive = false }
        var converted = pattern
        for (vim, icu) in [("\\<", "\\b"), ("\\>", "\\b"), ("\\(", "("), ("\\)", ")"), ("\\|", "|"), ("\\+", "+"), ("\\?", "?")] {
            converted = converted.replacingOccurrences(of: vim, with: icu)
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        return (try? NSRegularExpression(pattern: converted, options: options))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
    }

    /// The `count`th match after (or before) `offset`, wrapping around the
    /// document. One scan finds every match; the count only indexes into
    /// them, so `9999n` costs the same as `n`.
    private func search(_ pattern: String, forward: Bool, from offset: Int, count: Int = 1) -> Int? {
        guard let buffer, let regex = regex(for: pattern) else { return nil }
        let text = buffer.vimText
        let starts = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range.location)
        if !starts.isEmpty {
            let total = starts.count
            let steps = max(1, count) - 1
            let wrapped: Bool
            let index: Int
            if forward {
                let first = starts.firstIndex { $0 > offset }
                let target = (first ?? 0) + steps
                wrapped = first == nil || target >= total
                index = target % total
            } else {
                let last = starts.lastIndex { $0 < offset }
                let target = (last ?? total - 1) - steps
                wrapped = last == nil || target < 0
                index = (target % total + total) % total
            }
            if wrapped { message = "Search wrapped" }
            return starts[index]
        }
        message = "Pattern not found: \(pattern)"
        return nil
    }

    private func substitute(_ body: String, scope: NSRange) {
        guard let buffer, let delimiter = body.first else { return }
        var parts: [String] = [""]
        var escaping = false
        for character in body.dropFirst() {
            if escaping {
                if character != delimiter { parts[parts.count - 1].append("\\") }
                parts[parts.count - 1].append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == delimiter, parts.count < 3 {
                parts.append("")
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        guard parts.count >= 2, !parts[0].isEmpty || lastSearch != nil else {
            message = "Invalid substitute"
            return
        }
        let pattern = parts[0].isEmpty ? (lastSearch?.pattern ?? "") : parts[0]
        let flags = parts.count > 2 ? parts[2] : ""
        guard let regex = regex(for: pattern, ignoreCase: flags.contains("i")) else { return }
        let template = Self.template(fromVimReplacement: parts[1])
        let text = buffer.vimText
        let source = text as String
        let global = flags.contains("g")
        // As in Vim, each line is matched on its own and line breaks never match.
        var matches: [NSTextCheckingResult] = []
        for line in CodeTextEditing.lineContents(text, in: scope) {
            let lineMatches = regex.matches(in: source, range: line)
            matches += global ? lineMatches : Array(lineMatches.prefix(1))
        }
        guard !matches.isEmpty else {
            message = "Pattern not found: \(pattern)"
            return
        }
        let scoped = text.substring(with: scope)
        let result = NSMutableString(string: scoped)
        for match in matches.reversed() {
            let local = NSRange(location: match.range.location - scope.location, length: match.range.length)
            let replacement = regex.replacementString(for: match, in: source, offset: 0, template: template)
            result.replaceCharacters(in: local, with: replacement)
        }
        let lastLine = lineStart(matches[matches.count - 1].range.location)
        buffer.vimReplace(scope, with: result as String)
        place(firstNonBlank(min(lastLine, buffer.vimText.length)))
        if matches.count > 1 { message = "\(matches.count) substitutions" }
    }

    private static func template(fromVimReplacement replacement: String) -> String {
        var output = ""
        var escaping = false
        for character in replacement {
            if escaping {
                switch character {
                case "1"..."9": output += "$" + String(character)
                case "n": output += "\n"
                case "t": output += "\t"
                case "&": output += "&"
                default: output += NSRegularExpression.escapedTemplate(for: String(character))
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "&" {
                output += "$0"
            } else {
                output += NSRegularExpression.escapedTemplate(for: String(character))
            }
        }
        return output
    }

    // MARK: - Line geometry

    private func lineStart(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        var start = 0
        buffer.vimText.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: min(offset, buffer.vimText.length), length: 0))
        return start
    }

    private func contentsEnd(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        var end = 0
        buffer.vimText.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(offset, buffer.vimText.length), length: 0))
        return end
    }

    /// Start of the next line (after this line's break).
    private func lineEnd(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        var end = 0
        buffer.vimText.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: min(offset, buffer.vimText.length), length: 0))
        return end
    }

    private func hasTrailingBreak(_ offset: Int) -> Bool {
        lineEnd(offset) > contentsEnd(offset)
    }

    private func lastCharacter(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        let end = contentsEnd(offset)
        let start = lineStart(offset)
        return end > start ? previous(end, in: buffer.vimText) : start
    }

    private func firstNonBlank(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        let text = buffer.vimText
        var index = lineStart(offset)
        let end = contentsEnd(offset)
        while index < end, CodeText.isBlank(text.character(at: index)) { index += 1 }
        return index == end && end > lineStart(offset) ? lastCharacter(offset) : index
    }

    private func isBlankLine(_ offset: Int) -> Bool {
        guard let buffer else { return true }
        let text = buffer.vimText
        let end = contentsEnd(offset)
        var index = lineStart(offset)
        while index < end {
            if !CodeText.isBlank(text.character(at: index)) { return false }
            index += 1
        }
        return true
    }

    /// Normal mode never rests on a line break unless the line is empty.
    private func clampNormal(_ offset: Int) -> Int {
        guard let buffer else { return 0 }
        let clamped = max(0, min(offset, buffer.vimText.length))
        return min(clamped, lastCharacter(clamped))
    }

    private func clampVisual(_ offset: Int) -> Int {
        clampNormal(offset)
    }

    private func next(_ offset: Int, in text: NSString) -> Int {
        guard offset < text.length else { return text.length }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
    }

    private func previous(_ offset: Int, in text: NSString) -> Int {
        guard offset > 0 else { return 0 }
        return text.rangeOfComposedCharacterSequence(at: offset - 1).location
    }
}

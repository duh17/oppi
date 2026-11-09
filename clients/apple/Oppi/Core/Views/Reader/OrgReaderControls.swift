import UIKit

/// Where an Org reader's folds are kept between readers of the same file, so a
/// saved task edit (which mounts a new reader) leaves the headings as the
/// person had them. The owner keys it by file; the reader reports each change.
struct OrgFoldMemory {
    /// The headings folded, by ordinal (`OrgFolding`).
    var folded: Set<Int> = []
    var onChange: @MainActor (Set<Int>) -> Void = { _ in }
}

/// An Org document the reader converts to Markdown. The parse is kept, so a
/// fold converts again but does not parse again.
final class OrgReaderDocument: @unchecked Sendable {
    private let source: String
    private let documentPath: String?
    private let offersStateControl: Bool
    private let lock = NSLock()
    private var parsed: [LocatedOrgBlock]?
    private var parsedOutline: ReaderOutline?

    init(source: String, documentPath: String?, offersStateControl: Bool) {
        self.source = source
        self.documentPath = documentPath
        self.offersStateControl = offersStateControl
    }

    /// What a conversion wrote: the Markdown, and which Org heading (by
    /// ordinal, `OrgFolding`) each of its headings is. A `#+TITLE` is a
    /// heading of no Org heading's, and has none.
    struct Converted: Sendable {
        let markdown: String
        let headingOrdinals: [Int?]
    }

    private func blocks() -> [LocatedOrgBlock] {
        lock.lock()
        defer { lock.unlock() }
        let blocks = parsed ?? OrgParser().parseLocated(source)
        parsed = blocks
        return blocks
    }

    /// The document's headings, for finding one and listing them.
    var outline: ReaderOutline {
        let blocks = blocks()
        lock.lock()
        defer { lock.unlock() }
        let outline = parsedOutline ?? ReaderOutline.org(blocks)
        parsedOutline = outline
        return outline
    }

    /// The Markdown with the headings on `folded` hidden; nil when cancelled.
    func convert(folded: Set<Int>, cancellationCheck: @escaping @Sendable () -> Bool) -> Converted? {
        guard !cancellationCheck() else { return nil }
        let blocks = blocks()
        let trace = OrgToMarkdownConverter.HeadingTrace()
        guard let markdown = DocumentRenderPipeline.orgToMarkdown(
            located: blocks,
            documentPath: documentPath,
            offersStateControl: offersStateControl,
            foldingHeadings: .init(folded: folded),
            headingTrace: trace,
            linksHeadings: true,
            cancellationCheck: cancellationCheck
        ) else { return nil }
        let ordinals = OrgFolding.ordinals(of: blocks)
        return Converted(markdown: markdown, headingOrdinals: trace.lines.map { $0.flatMap { ordinals[$0] } })
    }
}

/// What the controls of an Org reader do: its headings fold, and, when the
/// reader can save the file, the task controls of `ReaderTaskEditing`.
///
/// Folds start expanded. They are kept by `OrgFoldMemory`, not in the file.
@MainActor
final class OrgReaderControls: ReaderTaskControlHandling {
    let document: OrgReaderDocument
    private let editing: ReaderTaskEditing?
    private let memory: OrgFoldMemory
    private(set) var folded: Set<Int>
    /// The heading a fold just changed, which VoiceOver is sent back to.
    private var focusOrdinal: Int?
    /// Called after `folded` changed; the reader converts and renders again.
    var onFoldChange: (@MainActor () -> Void)?

    init(source: String, documentPath: String?, editing: ReaderTaskEditing?, memory: OrgFoldMemory?) {
        document = OrgReaderDocument(source: source, documentPath: documentPath, offersStateControl: editing != nil)
        self.editing = editing
        self.memory = memory ?? OrgFoldMemory()
        folded = memory?.folded ?? []
    }

    var allowsTaskControls: Bool { editing?.allowsTaskControls == true }
    var allowsFolding: Bool { true }

    func toggleFold(ordinal: Int) {
        if !folded.insert(ordinal).inserted { folded.remove(ordinal) }
        focusOrdinal = ordinal
        memory.onChange(folded)
        onFoldChange?()
    }

    /// Opens whichever of the sections `ordinals` names are folded, so a
    /// heading under them shows. True when it opened any, and the reader
    /// converts again.
    @discardableResult
    func unfold(_ ordinals: [Int]) -> Bool {
        let closed = ordinals.filter { folded.contains($0) }
        guard !closed.isEmpty else { return false }
        folded.subtract(closed)
        memory.onChange(folded)
        onFoldChange?()
        return true
    }

    func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction {
        if control.isFold {
            return .action { [weak self] in self?.toggleFold(ordinal: control.line) }
        }
        return editing?.interaction(for: control, in: view) ?? .action {}
    }

    // MARK: VoiceOver

    /// Sends VoiceOver to the heading a fold changed, once the reader has drawn
    /// it again: the old element went with the old text. Waits turn by turn
    /// for the cell that holds it, as far as `attempts` allow.
    func announceFold(in root: UIView, attempts: Int = 20) {
        guard let ordinal = focusOrdinal else { return }
        if let element = Self.foldElement(ordinal: ordinal, in: root) {
            focusOrdinal = nil
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        } else if attempts > 0 {
            DispatchQueue.main.async { [weak self, weak root] in
                guard let root else { return }
                self?.announceFold(in: root, attempts: attempts - 1)
            }
        }
    }

    /// The accessibility element of the heading with `ordinal`, in the text
    /// views under `root`.
    static func foldElement(ordinal: Int, in root: UIView) -> ReaderTaskControlElement? {
        if let textView = root as? BaselineSafeTextView,
           let element = (textView.accessibilityElements ?? []).lazy
               .compactMap({ $0 as? ReaderTaskControlElement })
               .first(where: { $0.control.isFold && $0.control.line == ordinal }) {
            return element
        }
        for subview in root.subviews {
            if let element = foldElement(ordinal: ordinal, in: subview) { return element }
        }
        return nil
    }
}

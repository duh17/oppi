import UIKit

/// An attachment the reader draws for a control that edits a source line (a
/// task checkbox, an Org state or date badge).
protocol ReaderTaskControlAttachment: NSTextAttachment {
    var control: ReaderTaskControl? { get }
    /// Drawn nowhere (a plain heading's state): no touch area, and VoiceOver
    /// reaches it as an action of its line, not as a button of its own.
    var isMarker: Bool { get }
}

extension ReaderTaskControlAttachment {
    var isMarker: Bool { false }
}

/// What touching a control does.
enum ReaderTaskInteraction {
    case action(@MainActor () -> Void)
    /// Opens a native menu from the control.
    case menu(UIMenu)
}

/// Owns what the controls in a reader's text do. One owner answers a touch and
/// a VoiceOver activation alike, so the two can never differ.
@MainActor
protocol ReaderTaskControlHandling: AnyObject {
    /// Whether controls act right now. False for a file the reader cannot save,
    /// and while an edit is being saved.
    var allowsTaskControls: Bool { get }
    /// Whether a heading folds when tapped. Folding edits nothing, so a file
    /// the reader cannot save still folds.
    var allowsFolding: Bool { get }
    /// What touching `control`, which sits in `view`, does. A sheet the control
    /// opens is presented from `view`.
    func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction
}

extension ReaderTaskControlHandling {
    var allowsFolding: Bool { false }

    /// Whether `control` acts right now.
    func allows(_ control: ReaderTaskControl) -> Bool {
        control.isFold ? allowsFolding : allowsTaskControls
    }
}

extension ReaderTaskControl {
    /// The VoiceOver custom action that does what a tap does.
    var accessibilityActionName: String {
        switch kind {
        case .fold(let isExpanded): isExpanded ? String(localized: "Collapse") : String(localized: "Expand")
        case .checkbox: String(localized: "Toggle")
        case .state: String(localized: "Change state")
        case .date: String(localized: "Change date")
        }
    }
}

/// The control the user touches. It is the touch target only: it sits over the
/// control it was last aimed at (`hitTest`), so UIKit gives it the touch ahead
/// of the text view's own gestures, and a menu opens from the control's own
/// frame. VoiceOver reaches the control through `ReaderTaskControlElement`.
final class ReaderTaskTouchTarget: UIButton {
    var control: ReaderTaskControl?
    var rect = CGRect.null

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The accessibility element of one control: a button at the control's touch
/// area, with the identifier a test finds it by and the custom action a
/// VoiceOver user picks from the rotor.
final class ReaderTaskControlElement: UIAccessibilityElement {
    let control: ReaderTaskControl
    private weak var textView: BaselineSafeTextView?

    init(control: ReaderTaskControl, label: String, frame: CGRect, textView: BaselineSafeTextView) {
        self.control = control
        self.textView = textView
        super.init(accessibilityContainer: textView)
        accessibilityLabel = label
        accessibilityIdentifier = control.accessibilityIdentifier
        accessibilityTraits = .button
        if case .fold(let isExpanded) = control.kind {
            // The heading itself is the control: its state is its value.
            accessibilityTraits = [.header, .button]
            accessibilityValue = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        }
        accessibilityFrameInContainerSpace = frame
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: control.accessibilityActionName) { [weak self] _ in
                self?.accessibilityActivate() ?? false
            },
        ]
    }

    override func accessibilityActivate() -> Bool {
        guard let textView else { return false }
        return textView.activateTaskControl(control)
    }
}

// MARK: - Finding controls in the text

/// A control attachment with where it sits.
struct ReaderLocatedTaskControl {
    let control: ReaderTaskControl
    let label: String
    let isMarker: Bool
    /// Where the attachment is drawn, in the text view's coordinates.
    let glyphRect: CGRect

    /// The touch area: the glyph's, at least 44 × 44 pt around its centre. A
    /// checkbox is already a 44 pt column wide, and its line is spaced so the
    /// band around it never reaches the next item's.
    var touchRect: CGRect {
        let side = MarkdownTaskCheckbox.hitSize
        var rect = glyphRect
        if rect.width < side {
            rect.origin.x -= (side - rect.width) / 2
            rect.size.width = side
        }
        if rect.height < side {
            rect.origin.y -= (side - rect.height) / 2
            rect.size.height = side
        }
        return rect
    }
}

extension BaselineSafeTextView {
    /// What the text holds, read once per text.
    struct TaskAttachmentScan {
        let length: Int
        var holdsControls = false
        var holdsSpokenAttachments = false
    }

    private func scanTaskAttachments() -> TaskAttachmentScan {
        observeTextEdits()
        let length = textStorage.length
        if let taskAttachmentScan, taskAttachmentScan.length == length { return taskAttachmentScan }
        var scan = TaskAttachmentScan(length: length)
        if length > 0 {
            textStorage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: length),
                options: .longestEffectiveRangeNotRequired
            ) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                if (attachment as? ReaderTaskControlAttachment)?.control != nil { scan.holdsControls = true }
                if attachment.accessibilityLabel?.isEmpty == false { scan.holdsSpokenAttachments = true }
            }
        }
        taskAttachmentScan = scan
        return scan
    }

    var allowsTaskControls: Bool {
        guard let handler = taskControlHandler, handler.allowsTaskControls || handler.allowsFolding else { return false }
        return scanTaskAttachments().holdsControls
    }

    /// Whether the text speaks through lines of its own (it has badges or
    /// checkboxes, which UIKit's lines leave out, or controls) rather than as
    /// one element.
    var usesSpokenLines: Bool {
        textLayoutManager != nil && (scanTaskAttachments().holdsSpokenAttachments || allowsTaskControls)
    }

    func invalidateTaskControls() {
        taskAttachmentScan = nil
        taskAccessibilityCache = nil
    }

    // MARK: Text ranges

    private func nsRange(_ range: NSTextRange, in content: NSTextContentManager) -> NSRange {
        NSRange(
            location: content.offset(from: content.documentRange.location, to: range.location),
            length: content.offset(from: range.location, to: range.endLocation)
        )
    }

    private func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func glyphRect(ofCharacterAt index: Int, layout: NSTextLayoutManager, content: NSTextContentManager) -> CGRect? {
        guard let range = textRange(NSRange(location: index, length: 1), in: content) else { return nil }
        var found: CGRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        return found?.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    /// The control attachments in `range`, with where each is drawn.
    private func taskControls(
        in range: NSRange,
        layout: NSTextLayoutManager,
        content: NSTextContentManager
    ) -> [ReaderLocatedTaskControl] {
        var found: [ReaderLocatedTaskControl] = []
        textStorage.enumerateAttribute(.attachment, in: range, options: .longestEffectiveRangeNotRequired) { value, run, _ in
            guard let attachment = value as? ReaderTaskControlAttachment, let control = attachment.control else { return }
            for index in run.location..<(run.location + run.length) {
                guard let rect = glyphRect(ofCharacterAt: index, layout: layout, content: content) else { continue }
                found.append(ReaderLocatedTaskControl(
                    control: control,
                    label: attachment.accessibilityLabel ?? "",
                    isMarker: attachment.isMarker,
                    glyphRect: rect
                ))
            }
        }
        return found
    }

    /// The control whose touch area holds `point`, nearest its centre when the
    /// areas of two overlap. Reads only the lines near the point.
    func taskControl(at point: CGPoint) -> ReaderLocatedTaskControl? {
        guard allowsTaskControls,
              let layout = textLayoutManager,
              let content = layout.textContentManager else { return nil }
        let reach = MarkdownTaskCheckbox.hitSize / 2
        let local = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, local.y - reach))) else { return nil }
        var best: (control: ReaderLocatedTaskControl, distance: CGFloat)?
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            if fragment.layoutFragmentFrame.minY > local.y + reach { return false }
            for candidate in taskControls(in: nsRange(fragment.rangeInElement, in: content), layout: layout, content: content)
            where !candidate.isMarker && !candidate.control.isFold
                && taskControlHandler?.allows(candidate.control) == true
                && candidate.touchRect.contains(point) {
                let distance = abs(candidate.glyphRect.midX - point.x)
                if best == nil || distance < best?.distance ?? .infinity { best = (candidate, distance) }
            }
            return true
        }
        return best?.control
    }

    // MARK: Heading fold

    /// The fold control of the heading whose paragraph holds `point`, unless
    /// `point` is on a link in it: the whole heading folds it, and a link in
    /// the title still opens.
    func foldControl(at point: CGPoint) -> ReaderTaskControl? {
        guard allowsTaskControls,
              taskControlHandler?.allowsFolding == true,
              // A badge on the heading (its state, a date) keeps its own touch.
              taskControl(at: point) == nil,
              let layout = textLayoutManager,
              let content = layout.textContentManager else { return nil }
        let local = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let fragment = layout.textLayoutFragment(for: local),
              fragment.layoutFragmentFrame.contains(local) else { return nil }
        guard let fold = taskControls(in: nsRange(fragment.rangeInElement, in: content), layout: layout, content: content)
            .first(where: { $0.control.isFold })?.control else { return nil }
        if let position = closestPosition(to: point) {
            let index = offset(from: beginningOfDocument, to: position)
            for candidate in [index - 1, index] where candidate >= 0 && candidate < textStorage.length {
                if textStorage.attribute(.link, at: candidate, effectiveRange: nil) != nil { return nil }
            }
        }
        return fold
    }

    // MARK: Touch and activation

    /// Aims the touch target at `located`: a menu control shows its menu from
    /// the target, any other runs its action.
    func aimTaskTouchTarget(at located: ReaderLocatedTaskControl) {
        guard let handler = taskControlHandler else { return }
        let target = taskTouchTarget
        if target.superview !== self { addSubview(target) }
        if target.control == located.control, target.rect == located.touchRect { return }
        target.control = located.control
        target.rect = located.touchRect
        target.frame = located.touchRect
        switch handler.interaction(for: located.control, in: self) {
        case .menu(let menu):
            target.removeTarget(nil, action: nil, for: .primaryActionTriggered)
            target.menu = menu
            target.showsMenuAsPrimaryAction = true
        case .action(let run):
            target.menu = nil
            target.showsMenuAsPrimaryAction = false
            target.removeTarget(nil, action: nil, for: .primaryActionTriggered)
            target.addAction(UIAction { _ in run() }, for: .primaryActionTriggered)
        }
    }

    /// VoiceOver's way to the same owner action a touch reaches.
    @discardableResult
    func activateTaskControl(_ control: ReaderTaskControl) -> Bool {
        guard allowsTaskControls,
              let layout = textLayoutManager,
              let content = layout.textContentManager,
              let located = taskControls(
                  in: NSRange(location: 0, length: textStorage.length),
                  layout: layout,
                  content: content
              ).first(where: { $0.control == control }),
              taskControlHandler?.allows(control) == true else { return false }
        aimTaskTouchTarget(at: located)
        taskTouchTarget.performPrimaryAction()
        return true
    }

    /// The state menu of the heading the text menu was opened on, as one entry
    /// of that menu. It is the way to a state control that is not drawn.
    func taskStateMenu(forTextIn range: NSRange) -> UIMenu? {
        guard let handler = taskControlHandler, handler.allowsTaskControls,
              range.location <= textStorage.length else { return nil }
        let line = (textStorage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
        var state: ReaderTaskControl?
        textStorage.enumerateAttribute(.attachment, in: line, options: .longestEffectiveRangeNotRequired) { value, _, stop in
            guard let control = (value as? ReaderTaskControlAttachment)?.control, control.kind == .state else { return }
            state = control
            stop.pointee = true
        }
        guard let state, case .menu(let menu) = handler.interaction(for: state, in: self) else { return nil }
        let entry = UIMenu(title: String(localized: "State"), image: UIImage(systemName: "circle.dashed"), children: menu.children)
        entry.accessibilityIdentifier = "fileViewer.task.textMenu.state"
        return entry
    }

    // MARK: VoiceOver

    /// One element per line, with each badge and checkbox spoken where it sits,
    /// then one button per drawn control and one link element per link. A
    /// control that is not drawn is an action of its line.
    func spokenElements() -> [Any] {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return [] }
        let key = TaskAccessibilityKey(
            length: textStorage.length,
            size: bounds.size,
            controlsEnabled: allowsTaskControls,
            editsEnabled: taskControlHandler?.allowsTaskControls == true
        )
        if let cache = taskAccessibilityCache, cache.key == key { return cache.elements }

        var elements: [UIAccessibilityElement] = []
        let controlsEnabled = key.controlsEnabled
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            let base = nsRange(fragment.rangeInElement, in: content).location
            for line in fragment.textLineFragments {
                let range = NSRange(location: base + line.characterRange.location, length: line.characterRange.length)
                guard range.length > 0, NSMaxRange(range) <= textStorage.length else { continue }
                let frame = line.typographicBounds.offsetBy(
                    dx: origin.x + textContainerInset.left,
                    dy: origin.y + textContainerInset.top
                )
                let controls = (controlsEnabled ? taskControls(in: range, layout: layout, content: content) : [])
                    .filter { taskControlHandler?.allows($0.control) == true }
                if let label = spokenLabel(of: range) {
                    let markerActions = controls.filter(\.isMarker).map { located in
                        UIAccessibilityCustomAction(name: located.control.accessibilityActionName) { [weak self] _ in
                            self?.activateTaskControl(located.control) ?? false
                        }
                    }
                    if let fold = controls.first(where: { $0.control.isFold }) {
                        // A foldable heading is one element: its words, its
                        // state as the value, and the fold as its action.
                        let element = ReaderTaskControlElement(
                            control: fold.control,
                            label: label,
                            frame: frame,
                            textView: self
                        )
                        element.accessibilityCustomActions = (element.accessibilityCustomActions ?? []) + markerActions
                        elements.append(element)
                    } else {
                        let element = UIAccessibilityElement(accessibilityContainer: self)
                        element.accessibilityLabel = label
                        element.accessibilityTraits = .staticText
                        element.accessibilityFrameInContainerSpace = frame
                        element.accessibilityCustomActions = markerActions
                        elements.append(element)
                    }
                }
                for located in controls where !located.isMarker && !located.control.isFold {
                    elements.append(ReaderTaskControlElement(
                        control: located.control,
                        label: located.label,
                        frame: located.touchRect,
                        textView: self
                    ))
                }
                elements += linkElements(in: range, layout: layout, content: content)
            }
            return true
        }
        taskAccessibilityCache = TaskAccessibilityCache(key: key, elements: elements)
        return elements
    }

    /// A link element for each link in `range`, over its words. A container
    /// replaces the children UIKit would make, so the links are made here.
    /// VoiceOver's activation taps the link's centre, the touch path a link
    /// already takes.
    private func linkElements(
        in range: NSRange,
        layout: NSTextLayoutManager,
        content: NSTextContentManager
    ) -> [UIAccessibilityElement] {
        var links: [UIAccessibilityElement] = []
        textStorage.enumerateAttribute(.link, in: range, options: []) { value, run, _ in
            guard value != nil, let label = spokenLabel(of: run), let textRange = textRange(run, in: content) else { return }
            var frame = CGRect.null
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                frame = frame.union(segment)
                return true
            }
            guard !frame.isNull else { return }
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = label
            element.accessibilityTraits = .link
            element.accessibilityFrameInContainerSpace = frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            links.append(element)
        }
        return links
    }

    /// The line's text with each attachment spoken as its own label, apart from
    /// the words around it.
    private func spokenLabel(of range: NSRange) -> String? {
        var pieces: [String] = []
        let text = textStorage
        text.enumerateAttribute(.attachment, in: range, options: .longestEffectiveRangeNotRequired) { value, run, _ in
            // A fold's state is the heading's value, not words of its line.
            if let control = (value as? ReaderTaskControlAttachment)?.control, control.isFold { return }
            let piece = (value as? NSTextAttachment).map { $0.accessibilityLabel ?? "" }
                ?? (text.string as NSString).substring(with: run)
            let trimmed = piece
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
    }
}

struct TaskAccessibilityKey: Equatable {
    let length: Int
    let size: CGSize
    let controlsEnabled: Bool
    let editsEnabled: Bool
}

struct TaskAccessibilityCache {
    let key: TaskAccessibilityKey
    let elements: [Any]
}

/// A tap on a foldable heading folds it. It sits on `host` (a reader cell),
/// beside the text views' own gestures rather than on them, so selecting a
/// heading's words and opening its links work as before.
@MainActor
final class ReaderFoldTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var host: UIView?
    private let textViews: () -> [BaselineSafeTextView]

    init(host: UIView, textViews: @escaping () -> [BaselineSafeTextView]) {
        self.host = host
        self.textViews = textViews
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(tapped))
        cancelsTouchesInView = false
        delegate = self
    }

    private func target(at point: CGPoint) -> (textView: BaselineSafeTextView, control: ReaderTaskControl)? {
        guard let host else { return nil }
        for textView in textViews() {
            let local = host.convert(point, to: textView)
            if textView.bounds.contains(local), let control = textView.foldControl(at: local) {
                return (textView, control)
            }
        }
        return nil
    }

    @objc private func tapped() {
        guard state == .ended, let host, let target = target(at: location(in: host)) else { return }
        target.textView.activateTaskControl(target.control)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let host else { return false }
        return target(at: touch.location(in: host)) != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// A press on the heading is the text view's (selection, the text menu with
    /// the state menu in it): the fold waits for its long press to fail.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        other is UILongPressGestureRecognizer && other.view is BaselineSafeTextView
    }
}

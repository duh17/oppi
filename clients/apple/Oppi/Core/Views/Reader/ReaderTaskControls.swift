import UIKit

/// An attachment the reader draws for a control that edits a source line (a
/// task checkbox, an Org state or date badge).
protocol ReaderTaskControlAttachment: NSTextAttachment {
    var control: ReaderTaskControl? { get }
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
    /// What touching `control`, which sits in `view`, does. A sheet the control
    /// opens is presented from `view`.
    func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction
}

extension ReaderTaskControl {
    /// The VoiceOver custom action that does what a tap does.
    var accessibilityActionName: String {
        switch kind {
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
        taskControlHandler?.allowsTaskControls == true && scanTaskAttachments().holdsControls
    }

    /// Whether the text speaks through lines of its own (it has badges or
    /// checkboxes, which UIKit's lines leave out) rather than as one element.
    var usesSpokenLines: Bool {
        textLayoutManager != nil && scanTaskAttachments().holdsSpokenAttachments
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
            where candidate.touchRect.contains(point) {
                let distance = abs(candidate.glyphRect.midX - point.x)
                if best == nil || distance < best?.distance ?? .infinity { best = (candidate, distance) }
            }
            return true
        }
        return best?.control
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
              ).first(where: { $0.control == control }) else { return false }
        aimTaskTouchTarget(at: located)
        taskTouchTarget.performPrimaryAction()
        return true
    }

    // MARK: VoiceOver

    /// One element per line, with each badge and checkbox spoken where it sits,
    /// then one button per control; UIKit's own links stay as they were.
    func spokenElements() -> [Any] {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return [] }
        let key = TaskAccessibilityKey(
            length: textStorage.length,
            size: bounds.size,
            controlsEnabled: allowsTaskControls
        )
        if let cache = taskAccessibilityCache, cache.key == key { return cache.elements }

        var elements: [(frame: CGRect, element: UIAccessibilityElement)] = []
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
                if let label = spokenLabel(of: range) {
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityLabel = label
                    element.accessibilityTraits = .staticText
                    element.accessibilityFrameInContainerSpace = frame
                    elements.append((frame, element))
                }
                guard controlsEnabled else { continue }
                for located in taskControls(in: range, layout: layout, content: content) {
                    let element = ReaderTaskControlElement(
                        control: located.control,
                        label: located.label,
                        frame: located.touchRect,
                        textView: self
                    )
                    elements.append((located.touchRect, element))
                }
            }
            return true
        }
        // The links UIKit made for the text keep their own elements.
        let links = (super.accessibilityElements ?? []).filter {
            ($0 as? NSObject)?.accessibilityTraits.contains(.link) == true
        }
        let result = elements.map(\.element) as [Any] + links
        taskAccessibilityCache = TaskAccessibilityCache(key: key, elements: result)
        return result
    }

    /// The line's text with each attachment spoken as its own label, apart from
    /// the words around it.
    private func spokenLabel(of range: NSRange) -> String? {
        var pieces: [String] = []
        let text = textStorage
        text.enumerateAttribute(.attachment, in: range, options: .longestEffectiveRangeNotRequired) { value, run, _ in
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
}

struct TaskAccessibilityCache {
    let key: TaskAccessibilityKey
    let elements: [Any]
}

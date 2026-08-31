import AppKit
import SwiftUI

/// Composer-owned paste path. Cmd-V and Edit > Paste hit `NSTextView.paste`
/// so attachments can stage without an NSEvent monitor swallowing mixed text.
struct MacComposerInputView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var accessibilityLabel: String
    var textColor: NSColor
    var onFocusChange: (Bool) -> Void
    var onPasteAttachments: (MacComposerPasteboardPayload) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MacComposerInputScrollView {
        let textView = MacComposerPasteTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.string = text
        textView.setAccessibilityIdentifier("mac.composer.input")
        textView.setAccessibilityLabel(accessibilityLabel)

        let scrollView = MacComposerInputScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier("mac.composer.input")
        scrollView.setAccessibilityLabel(accessibilityLabel)

        context.coordinator.parent = self
        context.coordinator.textView = textView
        applyChrome(to: textView)
        MacComposerPasteTextView.hideWritingToolsAffordance(on: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: MacComposerInputScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MacComposerPasteTextView else { return }
        context.coordinator.textView = textView
        applyChrome(to: textView)
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.setAccessibilityLabel(accessibilityLabel)

        if !context.coordinator.isApplyingExternalText,
           !textView.hasMarkedText(),
           textView.string != text {
            context.coordinator.isApplyingExternalText = true
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            if NSMaxRange(selected) <= length {
                textView.setSelectedRange(selected)
            } else {
                textView.setSelectedRange(NSRange(location: length, length: 0))
            }
            context.coordinator.isApplyingExternalText = false
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: MacComposerInputScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              width.isFinite,
              width > 0,
              let textView = scrollView.documentView as? NSTextView else {
            return nil
        }
        return CGSize(
            width: width,
            height: MacComposerInputMetrics.fittedHeight(
                text: textView.string,
                font: textView.font ?? NSFont.preferredFont(forTextStyle: .body),
                width: width
            )
        )
    }

    private func applyChrome(to textView: MacComposerPasteTextView) {
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.onPasteAttachments = onPasteAttachments
        textView.onFocusChange = onFocusChange
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerInputView?
        weak var textView: MacComposerPasteTextView?
        var isApplyingExternalText = false

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }
            parent?.text = textView.string
        }
    }
}

enum MacComposerInputMetrics {
    static let minimumHeight: CGFloat = 21
    static let maximumHeight: CGFloat = 105

    static func fittedHeight(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let measuredText: String
        if text.isEmpty {
            measuredText = " "
        } else if text.hasSuffix("\n") {
            measuredText = text + " "
        } else {
            measuredText = text
        }
        let bounds = (measuredText as NSString).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(max(ceil(bounds.height), minimumHeight), maximumHeight)
    }
}

final class MacComposerInputScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let documentView {
            return window?.makeFirstResponder(documentView) ?? super.becomeFirstResponder()
        }
        return super.becomeFirstResponder()
    }
}

@MainActor
final class MacComposerPasteTextView: NSTextView {
    var onPasteAttachments: ((MacComposerPasteboardPayload) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Hides the macOS "Write with Siri" affordance without turning Writing Tools off.
    /// `allowsWritingToolsAffordance` exists on `NSTextView` at runtime (macOS 15.4+)
    /// but is only declared on `NSTextField` in the public SDK.
    /// Call once after the system `NSTextView` initializer — do not KVC this on every SwiftUI update.
    static func hideWritingToolsAffordance(on textView: NSTextView) {
        let setter = Selector(("setAllowsWritingToolsAffordance:"))
        guard textView.responds(to: setter) else { return }
        textView.setValue(false, forKey: "allowsWritingToolsAffordance")
    }

    override var acceptsFirstResponder: Bool { true }

    override func paste(_ sender: Any?) {
        applyPaste(thenTextOnly: { super.paste(sender) })
    }

    override func pasteAsPlainText(_ sender: Any?) {
        applyPaste(thenTextOnly: { super.pasteAsPlainText(sender) })
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            let plan = MacComposerPasteCommand.plan(from: .general)
            if plan.action.shouldStageAttachments {
                return true
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd-Return stays on the send button shortcut. Do not consume it here.
        if Self.isCommandReturn(event) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    private func applyPaste(thenTextOnly: () -> Void) {
        let plan = MacComposerPasteCommand.plan(from: .general)
        if plan.action.shouldStageAttachments {
            onPasteAttachments?(plan.payload)
        }
        switch plan.action {
        case .pasteTextOnly:
            thenTextOnly()
        case .stageAttachmentsAndPasteText:
            if let text = plan.textToInsert, !text.isEmpty {
                insertText(text, replacementRange: selectedRange())
            }
        case .stageAttachmentsOnly:
            break
        }
    }

    static func isCommandReturn(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else { return false }
        let raw = event.charactersIgnoringModifiers ?? ""
        return event.keyCode == 36 || event.keyCode == 76 || raw == "\r" || raw == "\n"
    }
}

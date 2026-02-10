import SwiftUI
import UIKit

@MainActor
private func applyStabilityInputTraits(to textView: UITextView) {
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.textContentType = .none

    let assistant = textView.inputAssistantItem
    assistant.leadingBarButtonGroups = []
    assistant.trailingBarButtonGroups = []
}

/// A UITextView wrapper that supports pasting images from the clipboard.
///
/// SwiftUI's `TextField` ignores image paste events. This UIViewRepresentable
/// intercepts `paste:` to check `UIPasteboard.general` for images, forwarding
/// them via `onPasteImages`. Text paste still works normally.
///
/// Uses a fixed inline height and internal scrolling to avoid layout loops.
struct PastableTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let maxLines: Int
    let onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastableUITextView {
        let textView = PastableUITextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        // Keep scrolling enabled at all times.
        // Dynamic toggling (based on frame/height) creates a UIKit↔SwiftUI
        // layout feedback loop during send + timeline relayout.
        textView.isScrollEnabled = true
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)

        // Disable predictive/autocorrect pipelines in inline composer.
        // In captures, stalls moved from sizeThatFits to idle while TextInputUI
        // candidate generation remained hot around send.
        applyStabilityInputTraits(to: textView)

        // Force TextKit 1. The default TextKit 2 path showed pathological
        // layout behavior under SwiftUI pressure on device.
        _ = textView.layoutManager

        return textView
    }

    func updateUIView(_ textView: PastableUITextView, context: Context) {
        MainThreadBreadcrumb.set("textview-update")
        defer { MainThreadBreadcrumb.set("idle") }

        if textView.text != text {
            textView.text = text
        }
        textView.onPasteImages = onPasteImages
        textView.tintColor = tintColor

        // Keep update path side-effect free: no layout invalidation, no dynamic
        // scroll toggling, no text-container mutation.
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: PastableUITextView, context: Context) -> CGSize? {
        MainThreadBreadcrumb.set("textview-sizeThatFits")
        defer { MainThreadBreadcrumb.set("idle") }

        // Emergency hardening:
        // Use a fixed inline height and internal scrolling, instead of
        // dynamic text measurement. This removes the auto-resize feedback
        // loop from the hot path during send/timeline relayout.
        let proposedWidth = proposal.width ?? textView.bounds.width
        let fallbackWidth = textView.window?.windowScene?.screen.bounds.width ?? 320
        let width = max(proposedWidth > 0 ? proposedWidth : fallbackWidth, 1)

        let lineHeight = textView.font?.lineHeight ?? font.lineHeight
        let inlineHeight = ceil(lineHeight + 6)
        return CGSize(width: width, height: inlineHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

// MARK: - Full Size Text View

/// A pastable text view that fills all available space. Used in the expanded composer.
///
/// Unlike `PastableTextView` (fixed inline height), this variant always scrolls
/// and fills its container. Keyboard dismiss is interactive
/// (drag to dismiss). Auto-focuses on appear after a brief delay for sheet animation.
struct FullSizeTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastableUITextView {
        let textView = PastableUITextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true

        applyStabilityInputTraits(to: textView)

        // Auto-focus after sheet animation settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            textView.becomeFirstResponder()
            // Place cursor at end
            if let end = textView.textRange(
                from: textView.endOfDocument,
                to: textView.endOfDocument
            ) {
                textView.selectedTextRange = end
            }
        }

        return textView
    }

    func updateUIView(_ textView: PastableUITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.onPasteImages = onPasteImages
        textView.tintColor = tintColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

// MARK: - Custom UITextView

/// UITextView subclass that intercepts paste to extract images.
final class PastableUITextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?

    override var intrinsicContentSize: CGSize {
        // Return noIntrinsicMetric — sizeThatFits is the authoritative source
        // for SwiftUI layout. Having intrinsicContentSize compete with
        // sizeThatFits causes layout oscillation.
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            if pb.hasImages || pb.hasStrings {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general

        // Check for images first
        if pb.hasImages, let images = pb.images, !images.isEmpty {
            onPasteImages?(images)
            // If clipboard also has text, paste that too
            if pb.hasStrings {
                super.paste(sender)
            }
            return
        }

        // Normal text paste
        super.paste(sender)
    }
}

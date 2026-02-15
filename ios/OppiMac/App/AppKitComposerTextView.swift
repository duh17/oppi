import AppKit
import SwiftUI

struct AppKitComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let textScale: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> ComposerTextViewContainer {
        let container = ComposerTextViewContainer()
        container.onTextChange = { newValue in
            context.coordinator.text.wrappedValue = newValue
        }
        container.onSubmit = {
            context.coordinator.onSubmit()
        }
        container.update(text: text, focusToken: focusToken, textScale: textScale)
        return container
    }

    func updateNSView(_ nsView: ComposerTextViewContainer, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit

        nsView.onTextChange = { newValue in
            context.coordinator.text.wrappedValue = newValue
        }
        nsView.onSubmit = {
            context.coordinator.onSubmit()
        }
        nsView.update(text: text, focusToken: focusToken, textScale: textScale)
    }

    final class Coordinator {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }
    }
}

final class ComposerTextViewContainer: NSView {
    var onTextChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    private let scrollView = NSScrollView()
    private let textView = SubmitTextView()

    private var lastAppliedText: String = ""
    private var lastFocusToken: Int = .min
    private var lastTextScale: CGFloat = 1.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func update(text: String, focusToken: Int, textScale: CGFloat) {
        if textView.string != text {
            textView.string = text
        }

        let clampedScale = min(max(textScale, 0.95), 1.55)
        if abs(clampedScale - lastTextScale) > 0.0001 {
            lastTextScale = clampedScale
            textView.font = .systemFont(ofSize: 14 * clampedScale)
        }

        applyTheme()

        if focusToken != lastFocusToken {
            lastFocusToken = focusToken
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self.textView)
            }
        }

        lastAppliedText = text
    }

    private func setUpViews() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        textView.minSize = NSSize(width: 0, height: 28)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 9, height: 8)
        textView.font = .systemFont(ofSize: 14 * lastTextScale)
        textView.onSubmit = { [weak self] in
            self?.onSubmit?()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        scrollView.documentView = textView

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        applyTheme()
    }

    private func applyTheme() {
        let palette = OppiMacTheme.current
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = palette.comment.withAlphaComponent(0.22).cgColor
        layer?.backgroundColor = palette.backgroundSecondary.cgColor

        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.backgroundSecondary

        textView.backgroundColor = palette.backgroundSecondary
        textView.insertionPointColor = palette.blue
        textView.textColor = palette.foreground
        textView.selectedTextAttributes = [
            .backgroundColor: palette.selection,
            .foregroundColor: palette.foreground,
        ]
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === textView else { return }

        let newValue = textView.string
        guard newValue != lastAppliedText else { return }

        lastAppliedText = newValue
        onTextChange?(newValue)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            if let event = NSApp.currentEvent,
               event.modifierFlags.contains(.shift) {
                super.doCommand(by: #selector(insertLineBreak(_:)))
                return
            }

            onSubmit?()
            return
        }

        super.doCommand(by: selector)
    }
}

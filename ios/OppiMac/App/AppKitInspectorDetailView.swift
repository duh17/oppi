import AppKit
import SwiftUI

struct AppKitInspectorDetailView: NSViewRepresentable {
    let document: OppiMacInspectorDocument?

    func makeNSView(context: Context) -> InspectorTextContainerView {
        let view = InspectorTextContainerView()
        view.update(document: document)
        return view
    }

    func updateNSView(_ nsView: InspectorTextContainerView, context: Context) {
        nsView.update(document: document)
    }
}

final class InspectorTextContainerView: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func update(document: OppiMacInspectorDocument?) {
        applyTheme()

        let rendered = makeAttributedString(document: document)
        textView.textStorage?.setAttributedString(rendered)
    }

    private func setUpViews() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 6, height: 10)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.lineFragmentPadding = 0
        }

        scrollView.documentView = textView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme()
    }

    private func applyTheme() {
        let palette = OppiMacTheme.current

        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor

        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.blue

        textView.linkTextAttributes = [
            .foregroundColor: palette.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    private func makeAttributedString(document: OppiMacInspectorDocument?) -> NSAttributedString {
        let palette = OppiMacTheme.current
        let result = NSMutableAttributedString()

        guard let document else {
            result.append(NSAttributedString(
                string: "Select a timeline item\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: palette.foreground,
                ]
            ))
            result.append(NSAttributedString(
                string: "Inspector details appear here.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: palette.comment,
                ]
            ))
            return result
        }

        result.append(NSAttributedString(
            string: document.title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: palette.foreground,
            ]
        ))

        result.append(NSAttributedString(
            string: document.timestamp.formatted(date: .abbreviated, time: .standard) + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: palette.comment,
            ]
        ))

        if !document.metadataRows.isEmpty {
            result.append(NSAttributedString(
                string: "Metadata\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: palette.foreground,
                ]
            ))

            for row in document.metadataRows {
                result.append(NSAttributedString(
                    string: row.key + ": ",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: palette.comment,
                    ]
                ))
                result.append(NSAttributedString(
                    string: row.value + "\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: palette.foregroundDim,
                    ]
                ))
            }

            result.append(NSAttributedString(string: "\n"))
        }

        result.append(NSAttributedString(
            string: document.detailTitle + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: palette.foreground,
            ]
        ))

        result.append(NSAttributedString(
            string: document.detailText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: palette.foreground,
            ]
        ))

        return result
    }
}

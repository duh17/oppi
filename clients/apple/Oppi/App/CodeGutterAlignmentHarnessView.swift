#if DEBUG
import SwiftUI
import UIKit

enum CodeGutterAlignmentHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--code-gutter-alignment-harness")
            || processInfo.environment["PI_CODE_GUTTER_ALIGNMENT_HARNESS"] == "1"
#else
        return false
#endif
    }
}

struct CodeGutterAlignmentHarnessView: UIViewRepresentable {
    func makeUIView(context: Context) -> CodeGutterAlignmentHarnessRootView {
        CodeGutterAlignmentHarnessRootView()
    }

    func updateUIView(_ uiView: CodeGutterAlignmentHarnessRootView, context: Context) {
        uiView.updateDiagnostics()
    }
}

final class CodeGutterAlignmentHarnessRootView: UIView {
    private static let fixtureCode = """
    source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
    ranges.append(NSRange(location: location, length: max(0, contentsEnd - location)))
    guard lineEnd > location else { break }
    """

    private let codeBody: NativeFullScreenCodeBody
    private let diagnosticsStack = UIStackView()
    private let readyLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "harness.ready"
    )
    private let gutterReadyLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeGutter.ready"
    )
    private let rowCountLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeGutter.rowCount"
    )
    private let maxDeltaLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeGutter.maxDeltaHundredths"
    )
    private let firstGapLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeGutter.firstGapHundredths"
    )
    private let lineHeightLabel = CodeGutterAlignmentHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeGutter.lineHeightHundredths"
    )

    override init(frame: CGRect) {
        codeBody = NativeFullScreenCodeBody(
            content: Self.fixtureCode,
            language: "swift",
            startLine: 204,
            palette: ThemeID.dark.palette,
            readerPreferences: FullScreenReaderPreferences(textScale: 1.25, wrapsText: true),
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDiagnostics()
    }

    func updateDiagnostics() {
        codeBody.layoutIfNeeded()
        let diagnostics = codeBody.codeGutterAlignmentDiagnosticsForTesting()
        setDiagnostic(readyLabel, value: 1)
        setDiagnostic(gutterReadyLabel, value: 1)
        setDiagnostic(rowCountLabel, value: diagnostics.rowCount)
        setDiagnostic(maxDeltaLabel, value: Int((diagnostics.maxRowDelta * 100).rounded()))
        setDiagnostic(firstGapLabel, value: Int((diagnostics.firstLogicalLineGap * 100).rounded()))
        setDiagnostic(lineHeightLabel, value: Int((diagnostics.lineHeight * 100).rounded()))
    }

    private func setup() {
        backgroundColor = UIColor(ThemeID.dark.palette.bgDark)

        codeBody.translatesAutoresizingMaskIntoConstraints = false
        addSubview(codeBody)

        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        addSubview(diagnosticsStack)

        [
            readyLabel,
            gutterReadyLabel,
            rowCountLabel,
            maxDeltaLabel,
            firstGapLabel,
            lineHeightLabel,
        ].forEach(diagnosticsStack.addArrangedSubview)

        NSLayoutConstraint.activate([
            codeBody.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBody.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBody.topAnchor.constraint(equalTo: topAnchor),
            codeBody.bottomAnchor.constraint(equalTo: bottomAnchor),

            diagnosticsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 2),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.updateDiagnostics()
        }
    }

    private static func makeDiagnosticLabel(id: String) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = id
        label.isAccessibilityElement = true
        label.font = .systemFont(ofSize: 1)
        label.textColor = .white
        label.backgroundColor = .clear
        label.text = "0"
        label.accessibilityLabel = id
        label.accessibilityValue = "0"
        return label
    }

    private func setDiagnostic(_ label: UILabel, value: Int) {
        let text = String(value)
        label.text = text
        label.accessibilityValue = text
    }
}
#endif

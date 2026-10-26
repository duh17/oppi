#if DEBUG
import SwiftUI
import UIKit

enum CodeBlockWrappingHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--code-block-wrapping-harness")
            || processInfo.environment["PI_CODE_BLOCK_WRAPPING_HARNESS"] == "1"
#else
        return false
#endif
    }
}

struct CodeBlockWrappingHarnessView: UIViewRepresentable {
    func makeUIView(context: Context) -> CodeBlockWrappingHarnessRootView {
        CodeBlockWrappingHarnessRootView()
    }

    func updateUIView(_ uiView: CodeBlockWrappingHarnessRootView, context: Context) {
        uiView.updateDiagnostics()
    }
}

@MainActor
final class CodeBlockWrappingHarnessRootView: UIView {
    private static let markdown = """
    Wrapping should not stretch this code block when its parent is temporarily taller than the content.

    ```text
    alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega
    ```
    """

    private let panel = UIView()
    private let markdownView = AssistantMarkdownContentView()
    private let diagnosticsStack = UIStackView()
    private let readyLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(id: "harness.ready")
    private let blockHeightLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeBlockWrap.blockHeight"
    )
    private let wrapEnabledLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeBlockWrap.wrapEnabled"
    )
    private let headerHeightLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeBlockWrap.headerHeight"
    )
    private let headerTopLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeBlockWrap.headerTop"
    )
    private let headerGapLabel = CodeBlockWrappingHarnessRootView.makeDiagnosticLabel(
        id: "diag.codeBlockWrap.headerGap"
    )
    private weak var observedWrapButton: UIButton?

    override init(frame: CGRect) {
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
        panel.layoutIfNeeded()
        markdownView.layoutIfNeeded()

        guard let codeBlock = firstVisibleCodeBlock(in: markdownView) else {
            setDiagnostic(readyLabel, value: 0)
            setUnavailableDiagnostics()
            return
        }

        observeWrapButtonIfNeeded(in: codeBlock)
        let diagnostics = codeBlock.layoutDiagnosticsForTesting()
        let blockHeight = Int(codeBlock.bounds.height.rounded())

        setDiagnostic(blockHeightLabel, value: blockHeight)
        setDiagnostic(wrapEnabledLabel, value: diagnostics.wrapsLines ? 1 : 0)
        setDiagnostic(headerHeightLabel, value: Int(diagnostics.headerHeight.rounded()))
        setDiagnostic(headerTopLabel, value: Int(diagnostics.headerTopInset.rounded()))
        setDiagnostic(headerGapLabel, value: Int(diagnostics.headerToCodeGap.rounded()))
        setDiagnostic(readyLabel, value: 1)
    }

    private func setup() {
        backgroundColor = UIColor(ThemeID.dark.palette.bg)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = UIColor(ThemeID.dark.palette.bgHighlight).withAlphaComponent(0.25)
        panel.layer.cornerRadius = 16
        panel.clipsToBounds = true
        addSubview(panel)

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(markdownView)
        markdownView.apply(configuration: .make(
            content: Self.markdown,
            isStreaming: false,
            themeID: .dark,
            textSelectionEnabled: false,
            renderingMode: .live
        ))

        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        addSubview(diagnosticsStack)

        [
            readyLabel,
            blockHeightLabel,
            wrapEnabledLabel,
            headerHeightLabel,
            headerTopLabel,
            headerGapLabel,
        ].forEach(diagnosticsStack.addArrangedSubview)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            panel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 120),
            panel.heightAnchor.constraint(equalToConstant: 620),

            markdownView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            markdownView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            markdownView.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            markdownView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),

            diagnosticsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 2),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.updateDiagnostics()
        }
    }

    private func setUnavailableDiagnostics() {
        setDiagnostic(blockHeightLabel, value: -1)
        setDiagnostic(wrapEnabledLabel, value: -1)
        setDiagnostic(headerHeightLabel, value: -1)
        setDiagnostic(headerTopLabel, value: -1)
        setDiagnostic(headerGapLabel, value: -1)
    }

    private func observeWrapButtonIfNeeded(in root: UIView) {
        guard let button = firstVisibleWrapButton(in: root), observedWrapButton !== button else { return }
        observedWrapButton?.removeTarget(self, action: #selector(wrapControlChanged), for: .touchUpInside)
        observedWrapButton = button
        button.addTarget(self, action: #selector(wrapControlChanged), for: .touchUpInside)
    }

    @objc private func wrapControlChanged() {
        scheduleDiagnosticRefreshes()
    }

    private func scheduleDiagnosticRefreshes() {
        DispatchQueue.main.async { [weak self] in self?.updateDiagnostics() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.updateDiagnostics() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateDiagnostics() }
    }

    private func firstVisibleCodeBlock(in root: UIView) -> NativeCodeBlockView? {
        guard !root.isHidden, root.alpha > 0.01 else { return nil }
        if let codeBlock = root as? NativeCodeBlockView {
            return codeBlock
        }
        for subview in root.subviews {
            if let found = firstVisibleCodeBlock(in: subview) {
                return found
            }
        }
        return nil
    }

    private func firstVisibleWrapButton(in root: UIView) -> UIButton? {
        guard !root.isHidden, root.alpha > 0.01 else { return nil }
        if let button = root as? UIButton,
           button.accessibilityIdentifier == "markdown.codeBlock.wrap" {
            return button
        }
        for subview in root.subviews {
            if let found = firstVisibleWrapButton(in: subview) {
                return found
            }
        }
        return nil
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

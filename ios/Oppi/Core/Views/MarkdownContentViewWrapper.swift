import SwiftUI
import UIKit

/// SwiftUI bridge for the UIKit markdown renderer (`AssistantMarkdownContentView`).
struct MarkdownContentViewWrapper: UIViewRepresentable {
    let content: String
    var isStreaming = false
    var textSelectionEnabled = true
    var plainTextFallbackThreshold: Int? = AssistantMarkdownContentView.Configuration.defaultPlainTextFallbackThreshold
    var workspaceID: String?
    var serverBaseURL: URL?
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?

    @Environment(\.selectedTextPiActionRouter) private var selectedTextPiRouter

    func makeUIView(context: Context) -> AssistantMarkdownContentView {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: AssistantMarkdownContentView, context: Context) {
        uiView.fetchWorkspaceFile = fetchWorkspaceFile
        uiView.apply(configuration: .init(
            content: content,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: textSelectionEnabled,
            plainTextFallbackThreshold: plainTextFallbackThreshold,
            selectedTextPiRouter: selectedTextPiRouter,
            workspaceID: workspaceID,
            serverBaseURL: serverBaseURL
        ))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AssistantMarkdownContentView,
        context: Context
    ) -> CGSize? {
        let fallbackWidth = uiView.window?.windowScene?.screen.bounds.width ?? uiView.bounds.width
        let width = proposal.width ?? fallbackWidth
        guard width > 0 else { return nil }

        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(1, fitting.height))
    }
}

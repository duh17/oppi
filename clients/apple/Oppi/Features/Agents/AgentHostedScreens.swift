import SwiftUI

/// The SwiftUI screens the UIKit Agents screens present or push: Pi's Tools
/// page, the icon picker, and the prompt readers.
@MainActor
enum AgentHostedScreens {
    /// Pi's Tools page. It edits `tools`, which saves each change and once
    /// more when the page closes.
    static func piTools(_ tools: PiToolsEditor, root: AppRootEnvironment) -> UIViewController {
        HostFactory.screen(root: root) { PiToolsPage(tools: tools) }
    }

    static func iconPicker(
        _ agent: StoredAgentDefinition?,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) -> RouterScreen {
        .hosted {
            guard let agent else { return AnyView(EmptyView()) }
            return AnyView(AgentIconPickerView(agent: agent, onSaved: onSaved))
        }
    }

    /// The icon picker's presentation for `traits`' size classes.
    static func iconPickerPresentation(_ traits: UITraitCollection) -> ModalPresentation {
        .iconPicker(
            horizontalSizeClass: UserInterfaceSizeClass(traits.horizontalSizeClass),
            verticalSizeClass: UserInterfaceSizeClass(traits.verticalSizeClass)
        )
    }

    static func reviewableMarkdown(
        content: String,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        sourcePath: String
    ) -> RouterScreen {
        .hosted {
            AnyView(ReviewableControlMarkdownView(
                content: content,
                domain: .agents,
                targetId: targetId,
                targetName: targetName,
                sourceLabel: sourceLabel,
                sourcePath: sourcePath
            ))
        }
    }

    /// Pi's built-in system prompt, read only.
    static func defaultPrompt(_ content: String) -> RouterScreen {
        .hosted {
            AnyView(
                EmbeddedFileViewerView(content: .fromText(content, filePath: "Pi-default-system-prompt.md"))
                    .ignoresSafeArea(edges: .top)
            )
        }
    }
}

/// The Pi Tools page the Pi page pushes.
private struct PiToolsPage: View {
    @Bindable var tools: PiToolsEditor

    var body: some View {
        AgentToolSelectionView(
            mode: $tools.mode,
            selectedNames: $tools.selectedNames,
            builtInTools: tools.builtInTools,
            defaultSelection: tools.defaultBuiltInSelection,
            optionalTools: tools.optionalTools,
            selectedOptionalNames: $tools.selectedOptionalNames,
            title: "Pi Tools",
            inheritFooter: AgentManagementPresentation.piToolsInheritFooter,
            exactFooter: AgentManagementPresentation.piToolsExactFooter,
            optionalToolsFooter: AgentManagementPresentation.piOptionalToolsFooter
        )
        .onDisappear { tools.pickerDidClose() }
    }
}

struct UseOppiSessionRow: View {
    let supportingText: String?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use Oppi Session")
                        .foregroundStyle(.themeFg)
                    if let supportingText {
                        Text(supportingText)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Use Oppi Session")
        .accessibilityHint(supportingText ?? "Opens an Oppi session")
    }
}

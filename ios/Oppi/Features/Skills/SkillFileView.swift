import SwiftUI
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillFile")

/// Displays the content of a single file from a skill directory.
///
/// Navigated to from the file tree in ``SkillDetailView``.
/// Text files are rendered as syntax-highlighted code or markdown.
struct SkillFileView: View {
    static let contentPresentation: FileContentPresentation = .document
    static let allowsNestedFullScreenExpansion = false

    let skillName: String
    let filePath: String

    @Environment(\.apiClient) private var apiClient
    @Environment(AppNavigation.self) private var navigation
    @State private var content: String?
    @State private var isLoading = true
    @State private var error: String?

    private var piRouter: SelectedTextPiActionRouter {
        let nav = navigation
        return SelectedTextPiActionRouter { request in
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }
    }

    private var fileName: String {
        filePath.components(separatedBy: "/").last ?? filePath
    }

    var body: some View {
        Group {
            if let content {
                FileContentView(content: content, filePath: filePath, presentation: Self.contentPresentation)
                    .allowsFullScreenExpansion(Self.allowsNestedFullScreenExpansion)
                    .environment(\.selectedTextPiActionRouter, piRouter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if isLoading {
                ProgressView("Loading…")
                    .padding(.top, 80)
            } else if let error {
                ContentUnavailableView(
                    "Failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .background(Color.themeBg)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let content {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = content
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }

        do {
            content = try await api.getSkillFile(name: skillName, path: filePath)
            logger.debug("Loaded skill file: \(skillName)/\(filePath)")
        } catch {
            logger.error("Failed to load \(skillName)/\(filePath): \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

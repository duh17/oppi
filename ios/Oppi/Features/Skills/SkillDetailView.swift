import SwiftUI
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillDetail")

/// Displays a skill's SKILL.md content, metadata badges, and file tree.
///
/// Loaded from tapping a skill row in ``WorkspaceEditView``.
/// Uses stale-while-revalidate: shows cached content immediately,
/// refreshes from server in the background.
struct SkillDetailView: View {
    let skillName: String

    @Environment(ServerConnection.self) private var connection
    @State private var detail: SkillDetail?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(detail.skill)
                    markdownSection(detail.content)
                    if detail.files.count > 1 {
                        filesSection(detail.files)
                    }
                }
                .padding()
            } else if isLoading {
                ProgressView("Loading skill…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
            } else if let error {
                ContentUnavailableView(
                    "Failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .navigationTitle(skillName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.description)
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            HStack(spacing: 8) {
                badge(
                    skill.containerSafe ? "Portable" : "Needs Local Tools",
                    icon: skill.containerSafe ? "checkmark.shield" : "desktopcomputer",
                    color: skill.containerSafe ? .themeGreen : .themeOrange
                )

                if skill.hasScripts {
                    badge("Scripts", icon: "terminal", color: .themeBlue)
                }

                if let detail, detail.files.count > 1 {
                    badge("\(detail.files.count) files", icon: "doc.on.doc", color: .themeComment)
                }
            }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: .capsule)
    }

    @ViewBuilder
    private func markdownSection(_ content: String) -> some View {
        if !content.isEmpty {
            Divider()
            MarkdownText(content)
        }
    }

    @ViewBuilder
    private func filesSection(_ files: [String]) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text("Files")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(files, id: \.self) { file in
                NavigationLink(value: SkillFileDestination(skillName: skillName, filePath: file)) {
                    HStack(spacing: 6) {
                        Image(systemName: fileIcon(for: file))
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .frame(width: 16)

                        Text(file)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.themeFg)

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        // Stale-while-revalidate: show cache first
        let cached = await TimelineCache.shared.loadSkillDetail(skillName)
        if let cached {
            detail = cached
            isLoading = false
        }

        // Refresh from server
        guard let api = connection.apiClient else {
            if detail == nil {
                error = "Not connected"
                isLoading = false
            }
            return
        }

        do {
            let fresh = try await api.getSkillDetail(name: skillName)
            detail = fresh
            await TimelineCache.shared.saveSkillDetail(skillName, detail: fresh)
            logger.debug("Loaded skill detail: \(skillName) (\(fresh.files.count) files)")
        } catch {
            logger.error("Failed to load skill \(skillName): \(error.localizedDescription)")
            if detail == nil {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: - Helpers

    private func fileIcon(for path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".py") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".sh") || !path.contains(".") { return "terminal" }
        if path.hasSuffix(".ts") || path.hasSuffix(".js") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".json") || path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "curlybraces" }
        return "doc"
    }
}

/// Navigation destination for viewing a skill's detail page.
struct SkillDetailDestination: Hashable, Identifiable {
    let skillName: String

    var id: String { skillName }
}

/// Navigation destination for viewing a file inside a skill.
struct SkillFileDestination: Hashable {
    let skillName: String
    let filePath: String
}

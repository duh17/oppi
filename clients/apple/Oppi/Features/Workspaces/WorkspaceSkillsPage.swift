import SwiftUI

/// Pi skills for one workspace, one toggle each. A toggle writes Pi settings at
/// once; the list shows the server's answer after the write.
struct WorkspaceSkillsPage: View {
    let model: WorkspaceSettingsModel

    @State private var selectedSkillDetail: SkillDetailDestination?

    var body: some View {
        List {
            Section {
                if model.isLoadingSkills && model.skills.isEmpty {
                    Text("Loading skills\u{2026}")
                        .foregroundStyle(.themeComment)
                } else if model.skills.isEmpty {
                    Text("No Pi skills discovered for this folder yet.")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(model.skills) { skill in
                        WorkspaceSkillRow(
                            skill: skill,
                            isEnabled: model.displayedEnabled(.skills, path: skill.path, server: skill.enabled),
                            isPending: model.isPending(.skills, path: skill.path),
                            canToggle: model.canTogglePiResources,
                            onToggle: { enabled in
                                Task { await model.setPiResource(.skills, path: skill.path, enabled: enabled) }
                            },
                            onShowDetail: {
                                selectedSkillDetail = SkillDetailDestination(skillName: skill.name, cwd: model.savedFolder)
                            }
                        )
                    }
                }

                if let skillsError = model.skillsError {
                    Text(skillsError)
                        .font(.caption2)
                        .foregroundStyle(.themeOrange)
                        .accessibilityIdentifier("workspace.edit.skills.error")
                }
            } footer: {
                Text(model.piResourceFooter)
            }
        }
        .settingsPage("Skills")
        .navigationDestination(item: $selectedSkillDetail) { dest in
            SkillDetailView(skillName: dest.skillName, cwd: dest.cwd)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath, cwd: dest.cwd)
        }
        .task {
            await model.loadPiResourcesIfNeeded()
        }
    }
}

private struct WorkspaceSkillRow: View {
    let skill: SkillInfo
    let isEnabled: Bool
    let isPending: Bool
    let canToggle: Bool
    let onToggle: (Bool) -> Void
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                isOn: Binding(get: { isEnabled }, set: onToggle)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .foregroundStyle(isEnabled ? .themeFg : .themeComment)
                        if isPending {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(2)
                }
            }
            .disabled(isPending || !canToggle)
            .accessibilityIdentifier("workspace.edit.skill.\(skill.name)")

            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.themeComment)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(skill.name) details")
        }
    }
}

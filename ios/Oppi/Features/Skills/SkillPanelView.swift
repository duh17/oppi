import SwiftUI
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillPanel")

/// Quick skill browser shown from the session status badge in ChatView.
///
/// Shows the skills enabled for the current workspace, with tappable
/// rows that navigate to skill detail. Also lists available-but-disabled
/// skills in a dimmed section.
struct SkillPanelView: View {
    /// Skill names enabled on the current workspace.
    let workspaceSkillNames: [String]

    @Environment(ServerConnection.self) private var connection
    @Environment(\.theme) private var theme

    private var allSkills: [SkillInfo] {
        connection.workspaceStore.skills
    }

    private var enabledSkills: [SkillInfo] {
        let nameSet = Set(workspaceSkillNames)
        return allSkills.filter { nameSet.contains($0.name) }
    }

    private var availableSkills: [SkillInfo] {
        let nameSet = Set(workspaceSkillNames)
        return allSkills.filter { !nameSet.contains($0.name) }
    }

    var body: some View {
        List {
            if !enabledSkills.isEmpty {
                Section {
                    ForEach(enabledSkills) { skill in
                        NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                            SkillRow(skill: skill, isEnabled: true)
                        }
                    }
                } header: {
                    Label("Enabled (\(enabledSkills.count))", systemImage: "checkmark.circle.fill")
                }
            }

            if !availableSkills.isEmpty {
                Section {
                    ForEach(availableSkills) { skill in
                        NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                            SkillRow(skill: skill, isEnabled: false)
                        }
                    }
                } header: {
                    Label("Available", systemImage: "circle.dashed")
                }
            }

            if allSkills.isEmpty {
                ContentUnavailableView(
                    "No Skills",
                    systemImage: "puzzlepiece",
                    description: Text("Skills haven't loaded yet.")
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: SkillDetailDestination.self) { dest in
            SkillDetailView(skillName: dest.skillName)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath)
        }
    }
}

// MARK: - SkillRow

private struct SkillRow: View {
    let skill: SkillInfo
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(isEnabled ? .themeFg : .themeComment)

                if skill.hasScripts {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.themeBlue)
                }

                if !skill.containerSafe {
                    Image(systemName: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.themeOrange)
                        .accessibilityLabel("Needs local tools")
                }
            }

            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1.0 : 0.6)
    }
}

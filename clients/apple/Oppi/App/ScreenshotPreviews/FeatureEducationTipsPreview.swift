#if DEBUG
import SwiftUI

// MARK: - Feature Education Tips Preview

private struct FeatureEducationTipPreviewItem: Identifiable {
    let id: String
    let priority: String
    let title: String
    let message: String
    let trigger: String
    let completion: String
    let stories: String
}


struct FeatureEducationTipsPreview: View {
    private static let priorities = ["P0", "P1", "P2"]
    private static let tips: [FeatureEducationTipPreviewItem] = [
        FeatureEducationTipPreviewItem(
            id: "open-tool-details",
            priority: "P0",
            title: "Open tool details",
            message: "Tap a tool row to inspect the command, output, diff, or file content.",
            trigger: "First completed non-ask tool row in chat",
            completion: "First tool row expanded",
            stories: "IOS-034, IOS-035, IOS-036"
        ),
        FeatureEducationTipPreviewItem(
            id: "tool-output-shortcuts",
            priority: "P0",
            title: "Use output shortcuts",
            message: "Double-tap or pinch expanded output to open it full screen. Touch and hold for copy actions.",
            trigger: "After first tool row is expanded and full-screen content is available",
            completion: "Full-screen opened or context menu used",
            stories: "IOS-034, IOS-042"
        ),
        FeatureEducationTipPreviewItem(
            id: "open-changed-files-bar",
            priority: "P0",
            title: "Review changed files",
            message: "Tap the changed-files bar to inspect files this session touched.",
            trigger: "First chat session with session-scoped changed files",
            completion: "Changed-files bar expanded",
            stories: "IOS-043, IOS-100"
        ),
        FeatureEducationTipPreviewItem(
            id: "answer-inline-asks-and-extension-prompts",
            priority: "P0",
            title: "Answer prompts here",
            message: "Pick an option or type a response here without returning to the Mac.",
            trigger: "First inline ask card or extension prompt appears",
            completion: "First prompt answered",
            stories: "IOS-009, IOS-059, IOS-061"
        ),
        FeatureEducationTipPreviewItem(
            id: "steer-vs-follow-up-while-busy",
            priority: "P0",
            title: "Choose how to send",
            message: "Use Steer to guide the current turn. Use Follow-up to queue the next instruction.",
            trigger: "Composer is busy and both send modes are available",
            completion: "First busy-send mode used",
            stories: "IOS-052, IOS-053"
        ),
        FeatureEducationTipPreviewItem(
            id: "select-text-for-review-comments",
            priority: "P0",
            title: "Comment on selected text",
            message: "Select text to stage a review comment for your next message.",
            trigger: "First diff, code, tool, or full-screen text view that supports comments",
            completion: "First review comment created",
            stories: "IOS-042, IOS-050"
        ),
        FeatureEducationTipPreviewItem(
            id: "context-bar-multi-select-and-drag-select",
            priority: "P1",
            title: "Select files quickly",
            message: "Tap Select, then drag down the file list to choose several files for a prompt template.",
            trigger: "Changed-files bar is expanded with at least two files",
            completion: "First context-bar multi-select",
            stories: "IOS-043, IOS-048, IOS-050"
        ),
        FeatureEducationTipPreviewItem(
            id: "message-queue-review-and-editing",
            priority: "P1",
            title: "Review queued messages",
            message: "Tap the queue to edit, reorder, or remove pending instructions before they send.",
            trigger: "A steering or follow-up message is queued",
            completion: "Message queue opened",
            stories: "IOS-053"
        ),
        FeatureEducationTipPreviewItem(
            id: "session-outline-tree",
            priority: "P1",
            title: "Open the session outline",
            message: "Use Outline to jump through messages, tool calls, and branches without scrolling.",
            trigger: "Long session, branched session, or outline button first visible",
            completion: "Session outline opened",
            stories: "IOS-025"
        ),
        FeatureEducationTipPreviewItem(
            id: "fork-from-a-point-in-history",
            priority: "P1",
            title: "Try another path",
            message: "Fork from a message to explore a new direction without changing the original session.",
            trigger: "User opens outline or message actions on a long session",
            completion: "First session fork created",
            stories: "IOS-024, IOS-025"
        ),
        FeatureEducationTipPreviewItem(
            id: "context-usage-inspector",
            priority: "P1",
            title: "Inspect context usage",
            message: "Tap context usage to see loaded skills, files, and token pressure before compacting.",
            trigger: "Context usage ring or bar first appears or crosses a warning threshold",
            completion: "Context inspector opened",
            stories: "IOS-044"
        ),
        FeatureEducationTipPreviewItem(
            id: "cross-session-attention",
            priority: "P1",
            title: "Find blocked sessions",
            message: "Attention badges point to sessions waiting for your answer.",
            trigger: "A pending ask appears outside the active chat",
            completion: "Attention session opened or answered",
            stories: "IOS-060, IOS-092"
        ),
        FeatureEducationTipPreviewItem(
            id: "file-repo-references",
            priority: "P1",
            title: "Reference repo files",
            message: "Type @ to add a workspace file reference without uploading the file.",
            trigger: "Composer focused in a workspace before first file reference",
            completion: "First file reference inserted",
            stories: "IOS-055"
        ),
        FeatureEducationTipPreviewItem(
            id: "slash-command-autocomplete",
            priority: "P1",
            title: "Run slash commands",
            message: "Type / at the start of a message to find commands like share or compact.",
            trigger: "Composer is empty and focused before first slash command",
            completion: "First slash command used",
            stories: "IOS-056"
        ),
        FeatureEducationTipPreviewItem(
            id: "expanded-full-screen-composer",
            priority: "P1",
            title: "Draft in full screen",
            message: "Use the expand button for long prompts; attachments and file references come with you.",
            trigger: "Prompt grows past compact composer threshold and expand button appears",
            completion: "Expanded composer opened",
            stories: "IOS-058"
        ),
        FeatureEducationTipPreviewItem(
            id: "workspace-row-previews",
            priority: "P2",
            title: "Preview sessions",
            message: "Tap a workspace row to preview active and recent sessions before opening it.",
            trigger: "Compact workspace list with active or recent sessions",
            completion: "Workspace row preview opened",
            stories: "IOS-013, IOS-014"
        ),
        FeatureEducationTipPreviewItem(
            id: "ipad-split-workspace-shell",
            priority: "P2",
            title: "Use the iPad sidebar",
            message: "Keep workspaces and sessions visible in the sidebar while chat stays open.",
            trigger: "First regular-width iPad launch after update",
            completion: "iPad sidebar navigation used",
            stories: "IOS-002"
        ),
        FeatureEducationTipPreviewItem(
            id: "quick-session-from-app-controls",
            priority: "P2",
            title: "Start faster",
            message: "Use Quick Session to start a prompt without drilling into a workspace first.",
            trigger: "Quick Session button or control is first available",
            completion: "Quick Session opened",
            stories: "IOS-026, IOS-096, IOS-097"
        ),
        FeatureEducationTipPreviewItem(
            id: "workspace-picker-in-quick-session",
            priority: "P2",
            title: "Pick the workspace",
            message: "Choose the target workspace before sending so the session starts in the right project.",
            trigger: "Quick Session sheet opens before first send",
            completion: "Quick Session workspace selected",
            stories: "IOS-027"
        ),
        FeatureEducationTipPreviewItem(
            id: "file-browser-fuzzy-search",
            priority: "P2",
            title: "Find files by name",
            message: "Use search to fuzzy-find files by path or filename.",
            trigger: "First file browser open in a workspace with many files",
            completion: "First file search used",
            stories: "IOS-064"
        ),
        FeatureEducationTipPreviewItem(
            id: "share-and-export-rendered-output",
            priority: "P2",
            title: "Share rendered output",
            message: "Use Share to export source, rendered documents, diffs, images, or PDFs.",
            trigger: "File, full-screen, or share viewer first exposes share action",
            completion: "First file or viewer share",
            stories: "IOS-067"
        ),
        FeatureEducationTipPreviewItem(
            id: "local-pi-session-import",
            priority: "P2",
            title: "Import local Pi sessions",
            message: "Tap an importable local session to bring previous Pi work into Oppi.",
            trigger: "Importable local Pi sessions appear in stopped history",
            completion: "First local Pi session imported",
            stories: "IOS-101"
        ),
        FeatureEducationTipPreviewItem(
            id: "stop-active-session-swipe-action",
            priority: "P2",
            title: "Stop a runaway session",
            message: "Swipe an active session row to stop work that should not keep running.",
            trigger: "First active session row in workspace list after a long run",
            completion: "First session stop from row",
            stories: "IOS-022"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header

                    ForEach(Self.priorities, id: \.self) { priority in
                        prioritySection(priority)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("feature-tips.catalog")
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Tips")
        }
        .tint(.themeBlue)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feature education tips")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.themeFg)

            Text("Fixture catalogue for app-behavior tips. Each card maps a contextual trigger to the action that dismisses the tip.")
                .font(.subheadline)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(Self.tips.count) tips covered")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.themeBlue.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("feature-tips.total")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func prioritySection(_ priority: String) -> some View {
        let priorityTips = Self.tips.filter { $0.priority == priority }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(priority)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(priorityColor(priority))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(priorityColor(priority).opacity(0.14), in: Capsule())

                Text("\(priorityTips.count) tips")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .accessibilityIdentifier("feature-tip-section.\(priority.lowercased())")

            ForEach(priorityTips) { tip in
                tipCard(tip)
            }
        }
        .padding(.top, 8)
    }

    private func tipCard(_ tip: FeatureEducationTipPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tip.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("feature-tip.\(tip.id)")

                Spacer(minLength: 8)

                Text(tip.stories)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(tip.message)
                .font(.subheadline)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Trigger", value: tip.trigger)
                metadataRow(label: "Stops after", value: tip.completion)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgHighlight.opacity(0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(priorityColor(tip.priority).opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feature-tip-card.\(tip.id)")
    }

    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
            Text(value)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "P0": return .themeOrange
        case "P1": return .themeBlue
        default: return .themeComment
        }
    }
}
#endif

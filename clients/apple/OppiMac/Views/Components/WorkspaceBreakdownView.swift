import SwiftUI

/// Compact list of workspaces sorted by cost (descending, as received from server).
///
/// Each row shows a folder icon, workspace name, session count, and right-aligned cost.
struct WorkspaceBreakdownView: View {

    let workspaces: [StatsWorkspaceBreakdown]

    var body: some View {
        if workspaces.isEmpty {
            Text("No workspace data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, ws in
                    workspaceRow(ws)
                    if index < workspaces.count - 1 {
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func workspaceRow(_ ws: StatsWorkspaceBreakdown) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(ws.name ?? ws.id)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text("\(ws.sessions)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(String(format: "$%.2f", ws.cost))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

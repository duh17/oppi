import SwiftUI

struct WorkspaceBreakdownSection: View {

    let workspaces: [StatsWorkspaceBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspaces")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)

            if workspaces.isEmpty {
                Text("No workspace data")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, ws in
                        workspaceRow(ws)
                        if index < workspaces.count - 1 {
                            Divider()
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    private func workspaceRow(_ ws: StatsWorkspaceBreakdown) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(.themeComment)
                .frame(width: 16)

            Text(ws.name ?? ws.id)
                .font(.caption)
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text("\(ws.sessions)")
                .font(.caption)
                .foregroundStyle(.themeComment)
                .monospacedDigit()

            Text(SessionFormatting.costString(ws.cost))
                .font(.caption)
                .foregroundStyle(.themeComment)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

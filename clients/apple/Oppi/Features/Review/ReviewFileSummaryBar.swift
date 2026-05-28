import SwiftUI

/// Shared header for file review and commit diff details.
///
/// Keeps the iPhone/iPad review surfaces visually consistent while callers
/// supply their own source of status and line-count data.
struct ReviewFileSummaryBar: View {
    let path: String
    let status: String
    let statusLabel: String
    let addedLines: Int?
    let removedLines: Int?

    init(
        path: String,
        status: String,
        statusLabel: String? = nil,
        addedLines: Int?,
        removedLines: Int?
    ) {
        self.path = path
        self.status = status
        self.statusLabel = statusLabel ?? status
        self.addedLines = addedLines
        self.removedLines = removedLines
    }

    private var fileIcon: FileIcon {
        FileIcon.forPath(path)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            fileIcon.iconView(size: 17, font: .subheadline.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fileIcon.color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(path.lastPathComponentForDisplay)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(GitStatusColor.color(for: status).opacity(0.12), in: Capsule())
                        .foregroundStyle(GitStatusColor.color(for: status))
                }

                if let parentPath = path.parentPathForDisplay {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if let addedLines, addedLines > 0 {
                    Text("+\(addedLines)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffAdded)
                }
                if let removedLines, removedLines > 0 {
                    Text("-\(removedLines)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffRemoved)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

import SwiftUI

/// Collapsible status bar showing child agent sessions above the ChatView composer.
///
/// Only appears when the current session has children (matched by `parentSessionId`).
/// Collapsed: aggregate status counts (working, done, error).
/// Expanded: per-child rows with status dot, name, model, cost, duration.
/// Tapping a child row navigates to that child's ChatView.
struct SubagentStatusBar: View {
    let childSessions: [Session]
    @Binding var isExpanded: Bool
    let onSelectChild: (String) -> Void

    private var workingCount: Int {
        childSessions.count { $0.status == .starting || $0.status == .busy || $0.status == .stopping }
    }

    private var doneCount: Int {
        childSessions.count { $0.status == .ready || $0.status == .stopped }
    }

    private var errorCount: Int {
        childSessions.count { $0.status == .error }
    }

    var body: some View {
        if !childSessions.isEmpty {
            VStack(spacing: 0) {
                // Header (always visible, tap to toggle)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    headerContent
                }
                .buttonStyle(.plain)

                // Expanded detail
                if isExpanded {
                    Divider()
                        .overlay(Color.themeBgHighlight)

                    VStack(spacing: 0) {
                        ForEach(childSessions) { child in
                            childRow(child)
                            if child.id != childSessions.last?.id {
                                Divider()
                                    .overlay(Color.themeBgHighlight)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.themeBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.themeBgHighlight, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Header

    private var headerContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if workingCount > 0 {
                    HStack(spacing: 3) {
                        Text("\u{23F3}")
                        Text("\(workingCount) working")
                    }
                    .foregroundStyle(.themeOrange)
                }
                if doneCount > 0 {
                    if workingCount > 0 {
                        Text("\u{00B7}")
                            .foregroundStyle(.themeComment)
                    }
                    HStack(spacing: 3) {
                        Text("\u{2713}")
                        Text("\(doneCount) done")
                    }
                    .foregroundStyle(.themeGreen)
                }
                if errorCount > 0 {
                    if workingCount > 0 || doneCount > 0 {
                        Text("\u{00B7}")
                            .foregroundStyle(.themeComment)
                    }
                    HStack(spacing: 3) {
                        Text("\u{2717}")
                        Text("\(errorCount) error")
                    }
                    .foregroundStyle(.themeRed)
                }
            }
            .font(.caption.weight(.medium))

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.themeComment)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Child Row

    private func childRow(_ child: Session) -> some View {
        Button {
            onSelectChild(child.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(child.status.color)
                    .frame(width: 8, height: 8)
                    .opacity(child.status == .busy || child.status == .stopping ? 0.8 : 1)
                    .animation(
                        child.status == .busy || child.status == .stopping
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default,
                        value: child.status
                    )

                Text(child.displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(child.status == .error ? .themeRed : .themeFg)
                    .lineLimit(1)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    if let model = shortModelName(child.model) {
                        Text(model)
                    }
                    if child.cost > 0 {
                        Text(costString(child.cost))
                    }
                    if child.status != .stopped, child.status != .error {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text(durationString(child.createdAt))
                        }
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.themeComment)
                .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func shortModelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private func costString(_ cost: Double) -> String {
        if cost >= 0.01 {
            let cents = Int((cost * 100).rounded())
            let d = cents / 100
            let r = cents % 100
            return "$\(d).\(r < 10 ? "0" : "")\(r)"
        } else {
            let mils = Int((cost * 1000).rounded())
            if mils < 10 { return "$0.00\(mils)" }
            if mils < 100 { return "$0.0\(mils)" }
            return "$0.\(mils)"
        }
    }

    private func durationString(_ createdAt: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(createdAt))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h\(remainingMinutes)m"
    }
}

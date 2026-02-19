import SwiftUI

/// Detail sheet for permission requests. Presented from the pill tap.
///
/// Single pending: shows one request with Allow/Deny buttons.
/// Multiple pending: TabView pager between requests.
struct PermissionSheet: View {
    let requests: [PermissionRequest]
    let onRespond: (String, PermissionResponseChoice) -> Void

    @State private var currentPage: Int = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if requests.isEmpty {
            // All resolved while sheet was open — auto-dismiss
            Color.clear.onAppear { dismiss() }
        } else if requests.count == 1 {
            singleRequestView(requests[0])
        } else {
            multiRequestView
        }
    }

    // MARK: - Single Request

    private func singleRequestView(_ request: PermissionRequest) -> some View {
        VStack(spacing: 0) {
            requestBody(request)

            PermissionActionButtons(request: request) { choice in
                onRespond(request.id, choice)
                dismiss()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Multiple Requests (Pager)

    private var multiRequestView: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                    singlePageContent(request)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            // Deny All (when 3+)
            if requests.count >= 3 {
                Button {
                    for request in requests {
                        onRespond(request.id, .denyOnce())
                    }
                    dismiss()
                } label: {
                    Text("Deny All (\(requests.count))")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.themeRed)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }

    private func singlePageContent(_ request: PermissionRequest) -> some View {
        VStack(spacing: 0) {
            requestBody(request)

            PermissionActionButtons(request: request) { choice in
                onRespond(request.id, choice)
                // Don't dismiss — advance to next page
                if currentPage >= requests.count - 1 {
                    currentPage = max(0, requests.count - 2)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func requestBody(_ request: PermissionRequest) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                PermissionSheetHeader(request: request)
                CommandBox(summary: request.displaySummary, tool: request.tool, input: request.input)

                if !request.reason.isEmpty {
                    Text(request.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Sheet Header

private struct PermissionSheetHeader: View {
    let request: PermissionRequest

    var body: some View {
        HStack {
            Image(systemName: request.risk.systemImage)
                .font(.title2)
                .foregroundStyle(Color.riskColor(request.risk))

            Text("Permission Request")
                .font(.headline)

            Spacer()

            if request.hasExpiry {
                Text(request.timeoutAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Label("No expiry", systemImage: "infinity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Command Box

private struct CommandBox: View {
    let summary: String
    let tool: String
    let input: [String: JSONValue]

    private var actionText: String {
        if tool.lowercased() == "bash",
           let command = input["command"]?.stringValue,
           !command.isEmpty {
            return command
        }
        return summary
    }

    private var showsSummaryHint: Bool {
        actionText != summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(tool))
                    .font(.caption)
                Text(displayToolLabel)
                    .font(.caption.bold())

                Spacer()

                if showsSummaryHint {
                    Text("Full action")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.themeComment)

            if showsSummaryHint {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(actionText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.themeFg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Pick an icon based on tool name + summary content.
    /// Browser commands come through as "bash" but the summary is smart
    /// (e.g., "Navigate: github.com", "JS: document.title").
    private func iconForTool(_ tool: String) -> String {
        // Check summary prefix for browser commands
        if summary.hasPrefix("Navigate:") { return "safari" }
        if summary.hasPrefix("JS:") { return "curlybraces" }
        if summary.hasPrefix("Screenshot") { return "camera.viewfinder" }
        if summary.hasPrefix("Start Chrome") { return "globe" }
        if summary.hasPrefix("Dismiss cookies") { return "xmark.shield" }
        if summary.hasPrefix("Pick element") { return "hand.tap" }
        if summary.hasPrefix("Browser:") { return "globe" }

        switch tool.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil"
        default: return "wrench"
        }
    }

    /// Display a more descriptive tool label for browser commands.
    private var displayToolLabel: String {
        if summary.hasPrefix("Navigate:") { return "web-browser" }
        if summary.hasPrefix("JS:") { return "web-browser" }
        if summary.hasPrefix("Screenshot") { return "web-browser" }
        if summary.hasPrefix("Start Chrome") { return "web-browser" }
        if summary.hasPrefix("Dismiss cookies") { return "web-browser" }
        if summary.hasPrefix("Pick element") { return "web-browser" }
        if summary.hasPrefix("Browser:") { return "web-browser" }
        return tool
    }
}

// MARK: - Action Buttons

/// Allow/Deny buttons with risk-appropriate emphasis.
///
/// Low/Medium: Allow is prominent. High: both equal weight.
/// Critical: Deny is prominent, Allow is deliberately plain.
private struct PermissionActionButtons: View {
    private struct ExtraChoice: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let role: ButtonRole?
        let choice: PermissionResponseChoice
    }

    let request: PermissionRequest
    let onAction: (PermissionResponseChoice) -> Void

    @State private var isResolving = false

    private var isCritical: Bool { request.risk == .critical }

    private var allowTint: Color {
        switch request.risk {
        case .low: return .themeGreen
        case .medium: return .themeBlue
        case .high: return .themeOrange
        case .critical: return .themeFgDim
        }
    }

    private var denyWidth: CGFloat {
        request.risk == .low ? 80 : .infinity
    }

    private var options: PermissionResolutionOptions {
        request.resolutionOptions
            ?? PermissionResolutionOptions(
                allowSession: true,
                allowAlways: false,
                alwaysDescription: nil,
                denyAlways: true
            )
    }

    private var extraChoices: [ExtraChoice] {
        var choices: [ExtraChoice] = []

        if options.allowSession {
            choices.append(
                ExtraChoice(
                    id: "allow-session",
                    title: "Allow this session",
                    systemImage: "clock",
                    role: nil,
                    choice: PermissionResponseChoice(action: .allow, scope: .session)
                )
            )
        }

        if options.allowAlways {
            let temporaryDurations: [(label: String, ms: Int)] = [
                ("Allow for 1 hour", 60 * 60 * 1000),
                ("Allow for 24 hours", 24 * 60 * 60 * 1000),
                ("Allow for 7 days", 7 * 24 * 60 * 60 * 1000),
            ]

            for duration in temporaryDurations {
                choices.append(
                    ExtraChoice(
                        id: "allow-temp-\(duration.ms)",
                        title: duration.label,
                        systemImage: "timer",
                        role: nil,
                        choice: PermissionResponseChoice(
                            action: .allow,
                            scope: .workspace,
                            expiresInMs: duration.ms
                        )
                    )
                )
            }

            choices.append(
                ExtraChoice(
                    id: "allow-forever",
                    title: options.alwaysDescription ?? "Always allow in this workspace",
                    systemImage: "checkmark.circle",
                    role: nil,
                    choice: PermissionResponseChoice(action: .allow, scope: .workspace)
                )
            )
        }

        if options.denyAlways {
            choices.append(
                ExtraChoice(
                    id: "deny-forever",
                    title: "Always deny in this workspace",
                    systemImage: "xmark.circle",
                    role: .destructive,
                    choice: PermissionResponseChoice(action: .deny, scope: .workspace)
                )
            )
        }

        return choices
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Deny button (one-time)
                if isCritical {
                    denyLabel
                        .buttonStyle(.borderedProminent)
                        .tint(.themeRed)
                } else {
                    denyLabel
                        .buttonStyle(.bordered)
                        .tint(.themeRed)
                }

                // Allow button (one-time)
                if isCritical {
                    allowLabel
                        .buttonStyle(.bordered)
                        .tint(allowTint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.themeRed, lineWidth: 2)
                        )
                } else {
                    allowLabel
                        .buttonStyle(.borderedProminent)
                        .tint(allowTint)
                }
            }

            if !extraChoices.isEmpty {
                HStack {
                    Menu {
                        ForEach(extraChoices) { item in
                            Button(role: item.role) {
                                resolve(item.choice)
                            } label: {
                                Label(item.title, systemImage: item.systemImage)
                            }
                        }
                    } label: {
                        Label("More options", systemImage: "ellipsis.circle")
                            .font(.footnote)
                    }
                    .disabled(isResolving)

                    Spacer()
                }
            }
        }
    }

    private var denyLabel: some View {
        Button {
            resolve(.denyOnce())
        } label: {
            Text("Deny")
                .font(.subheadline.bold())
                .frame(maxWidth: denyWidth)
                .padding(.vertical, 14)
        }
        .disabled(isResolving)
    }

    private var allowLabel: some View {
        Button {
            resolve(.allowOnce())
        } label: {
            HStack(spacing: 6) {
                if BiometricService.shared.requiresBiometric(for: request.risk) {
                    Image(systemName: biometricIcon)
                        .font(.caption)
                }
                Text("Allow")
            }
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .disabled(isResolving)
    }

    private var biometricIcon: String {
        switch BiometricService.shared.biometricName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock"
        }
    }

    private func resolve(_ choice: PermissionResponseChoice) {
        isResolving = true
        let style: UIImpactFeedbackGenerator.FeedbackStyle = choice.action == .allow ? .light : .heavy
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        onAction(choice)
    }
}

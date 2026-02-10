import SwiftUI

/// Detail sheet for permission requests. Presented from the pill tap.
///
/// Single pending: shows one request with Allow/Deny buttons.
/// Multiple pending: TabView pager between requests.
struct PermissionSheet: View {
    let requests: [PermissionRequest]
    let onRespond: (String, PermissionAction) -> Void

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
        VStack(spacing: 20) {
            // Header
            PermissionSheetHeader(request: request)

            // Command display
            CommandBox(summary: request.displaySummary, tool: request.tool)

            // Reason
            if !request.reason.isEmpty {
                Text(request.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Action buttons
            PermissionActionButtons(request: request) { action in
                onRespond(request.id, action)
                dismiss()
            }
        }
        .padding(24)
        .padding(.top, 4)
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
                        onRespond(request.id, .deny)
                    }
                    dismiss()
                } label: {
                    Text("Deny All (\(requests.count))")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.tokyoRed)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }

    private func singlePageContent(_ request: PermissionRequest) -> some View {
        VStack(spacing: 20) {
            PermissionSheetHeader(request: request)
            CommandBox(summary: request.displaySummary, tool: request.tool)

            if !request.reason.isEmpty {
                Text(request.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            PermissionActionButtons(request: request) { action in
                onRespond(request.id, action)
                // Don't dismiss — advance to next page
                if currentPage >= requests.count - 1 {
                    currentPage = max(0, requests.count - 2)
                }
            }
        }
        .padding(24)
        .padding(.top, 4)
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

            Text(request.timeoutAt, style: .timer)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Command Box

private struct CommandBox: View {
    let summary: String
    let tool: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(tool))
                    .font(.caption)
                Text(displayToolLabel)
                    .font(.caption.bold())
            }
            .foregroundStyle(.tokyoComment)

            Text(summary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.tokyoBgDark)
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
    let request: PermissionRequest
    let onAction: (PermissionAction) -> Void

    @State private var isResolving = false

    private var isCritical: Bool { request.risk == .critical }

    private var allowTint: Color {
        switch request.risk {
        case .low: return .tokyoGreen
        case .medium: return .tokyoBlue
        case .high: return .tokyoOrange
        case .critical: return .tokyoFgDim
        }
    }

    private var denyWidth: CGFloat {
        request.risk == .low ? 80 : .infinity
    }

    var body: some View {
        HStack(spacing: 12) {
            // Deny button
            if isCritical {
                denyLabel
                    .buttonStyle(.borderedProminent)
                    .tint(.tokyoRed)
            } else {
                denyLabel
                    .buttonStyle(.bordered)
                    .tint(.tokyoRed)
            }

            // Allow button
            if isCritical {
                allowLabel
                    .buttonStyle(.bordered)
                    .tint(allowTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.tokyoRed, lineWidth: 2)
                    )
            } else {
                allowLabel
                    .buttonStyle(.borderedProminent)
                    .tint(allowTint)
            }
        }
    }

    private var denyLabel: some View {
        Button {
            resolve(.deny)
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
            resolve(.allow)
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

    private func resolve(_ action: PermissionAction) {
        isResolving = true
        let style: UIImpactFeedbackGenerator.FeedbackStyle = action == .allow ? .light : .heavy
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        onAction(action)
    }
}

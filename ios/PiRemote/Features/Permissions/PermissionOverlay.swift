import SwiftUI

/// Container for the floating permission pill and detail sheet.
///
/// Designed to be used as `.safeAreaInset(edge: .bottom)` on the chat ScrollView.
/// When no permissions are pending, renders as zero-height (no inset).
struct PermissionOverlay: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(PermissionStore.self) private var permissionStore
    @State private var showSheet = false

    private var pending: [PermissionRequest] {
        permissionStore.pending(for: sessionId)
    }

    var body: some View {
        if let first = pending.first {
            PermissionPill(
                request: first,
                totalCount: pending.count,
                onAllow: { respond(id: first.id, action: .allow) },
                onDeny: { respond(id: first.id, action: .deny) },
                onTap: { showSheet = true }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy(duration: 0.3), value: pending.count)
            .sheet(isPresented: $showSheet) {
                PermissionSheet(
                    requests: pending,
                    onRespond: { id, action in
                        respond(id: id, action: action)
                    }
                )
                .presentationDetents([.height(340), .medium])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: pending.isEmpty) { _, isEmpty in
                if isEmpty {
                    showSheet = false
                }
            }
        }
    }

    private func respond(id: String, action: PermissionAction) {
        Task { @MainActor in
            // Biometric gate: require Face ID for high-risk approvals
            if action == .allow {
                let request = pending.first { $0.id == id }
                if let request, BiometricService.shared.requiresBiometric(for: request.risk) {
                    let toolLabel = request.tool
                    let reason = "Approve \(toolLabel): \(request.displaySummary)"
                    let authenticated = await BiometricService.shared.authenticate(reason: reason)
                    guard authenticated else {
                        // Biometric failed or cancelled — don't send allow
                        return
                    }
                }
            }

            do {
                try await connection.respondToPermission(id: id, action: action)
            } catch {
                // Permission response failed — will timeout server-side
            }
        }
    }
}

import SwiftUI

@main
struct OppiMacApp: App {
    @State private var store = OppiMacStore()

    var body: some Scene {
        WindowGroup {
            OppiMacRootView(store: store)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .commands {
            CommandMenu("Session") {
                Button("New Session") {
                    Task {
                        await store.createSessionInSelectedWorkspace()
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!store.isConnected || store.selectedWorkspaceID == nil)

                Button("Refresh Sessions") {
                    Task {
                        await store.refreshSessions()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!store.isConnected)

                Button("Resume Selected Session") {
                    Task {
                        await store.resumeSelectedSession()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selectedSession?.status != .stopped)

                Button("Stop Selected Session") {
                    Task {
                        await store.stopSelectedSession()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(store.selectedSession == nil)

                Button("Delete Selected Session") {
                    Task {
                        await store.deleteSelectedSession()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(store.selectedSession == nil)

                Divider()

                Button("Stop Turn") {
                    Task {
                        await store.sendStopTurn()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!store.isStreamConnected)
            }

            CommandMenu("Permissions") {
                Button("Approve Next Permission") {
                    Task {
                        await store.approveFirstPendingPermission()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store.selectedSessionPendingPermissions.isEmpty)

                Button("Deny Next Permission") {
                    Task {
                        await store.denyFirstPendingPermission()
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.selectedSessionPendingPermissions.isEmpty)
            }

            CommandMenu("Focus") {
                Button("Sessions") {
                    store.requestFocus(.sessions)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Timeline") {
                    store.requestFocus(.timeline)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Button("Composer") {
                    store.requestComposerFocus()
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("View") {
                Button("Larger Text") {
                    store.increaseTimelineTextScale()
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("Smaller Text") {
                    store.decreaseTimelineTextScale()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Reset Text Size") {
                    store.resetTimelineTextScale()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

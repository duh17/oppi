import SwiftUI
import UIKit

/// About This Server: connection and version facts, plus the update flow.
struct ServerAboutPage: View {
    let model: ServerSettingsModel
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var showUpdateConfirmation = false
    /// Captured when the confirmation opens, so its list cannot shift under the finger.
    @State private var busySessionTitles: [String] = []
    @State private var copiedManualCommand = false

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Connection",
                    value: ServerSettingsRootView.connectionStatusTitle(for: server, coordinator: coordinator)
                )
                if let info = model.info {
                    LabeledContent("Uptime", value: info.uptimeLabel)
                    LabeledContent("Pi SDK", value: info.piVersion)
                    if let piCliVersion = info.piCliVersion, !piCliVersion.isEmpty {
                        LabeledContent("Pi TUI", value: piCliVersion)
                    }
                    LabeledContent("Server", value: info.version)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Pi SDK is the embedded Pi coding-agent package that runs Oppi sessions. Pi TUI is the installed pi CLI on this host.")
            }

            if model.info != nil {
                updateSection
            }
        }
        .settingsPage("About This Server")
        .accessibilityIdentifier("server.about.list")
        .confirmationDialog(
            ServerUpdatePresentation.confirmationTitle(model.info?.update),
            isPresented: $showUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.info?.update.map(ServerUpdatePresentation.actionTitle) ?? "Update") {
                Task { await model.startServerUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ServerUpdatePresentation.confirmationMessage(busySessionTitles: busySessionTitles))
        }
    }

    /// Sessions on this server that a restart would interrupt.
    private func currentBusySessionTitles() -> [String] {
        guard let store = coordinator.connection(for: server.id)?.sessionStore else { return [] }
        return store.sessions(forServer: server.id)
            .filter { $0.status == .starting || $0.status.isRunning }
            .map(\.displayTitle)
    }

    @ViewBuilder
    private var updateSection: some View {
        let update = model.info?.update
        let belowMinimum = ServerReleaseVersion.isBelowMinimum(model.info?.version)
        let updateInFlight = model.updateInFlight
        let updateDidNotReturn = model.updateDidNotReturn
        if belowMinimum || update?.available == true || update?.isInstalling == true
            || update?.isRestarting == true || update?.isRestartNeeded == true
            || update?.isFailed == true || updateInFlight || updateDidNotReturn
            || (update != nil && update?.isAppUpdatable == false) {
            Section {
                if updateDidNotReturn {
                    Label("Server did not come back. Nothing was rolled back — check the host.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.themeOrange)
                        .accessibilityIdentifier("server.update.didNotReturn")
                } else if let update {
                    if update.isInstalling || update.isRestarting || updateInFlight {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                ServerUpdatePresentation.progressLabel(
                                    status: update.status,
                                    restartMode: update.restartMode,
                                    isSourceLink: update.isSourceLink
                                )
                            )
                        }
                        .accessibilityIdentifier("server.update.progress")
                    } else if update.isRestartNeeded {
                        Label("\(update.isSourceLink ? "Built" : "Installed"). Restart this Oppi server on the host to use the new version.",
                              systemImage: "arrow.clockwise")
                            .accessibilityIdentifier("server.update.restartNeeded")
                    } else if update.isFailed, let message = update.error, !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.themeOrange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("server.update.error")
                    }

                    let settled = !update.isInstalling && !update.isRestarting
                        && !update.isRestartNeeded && !updateInFlight
                    if belowMinimum, settled {
                        minimumVersionNotice(update: update)
                    }

                    if update.available, update.isAppUpdatable, !update.isInstalling,
                       !update.isRestarting, !update.isRestartNeeded, !updateDidNotReturn {
                        if let title = ServerUpdatePresentation.availableTitle(update) {
                            Text(title)
                                .accessibilityIdentifier("server.update.available")
                        }
                        Button(ServerUpdatePresentation.actionTitle(update)) {
                            busySessionTitles = currentBusySessionTitles()
                            showUpdateConfirmation = true
                        }
                        .disabled(updateInFlight)
                        .accessibilityIdentifier("server.update.button")
                    } else if !update.isAppUpdatable {
                        manualCommand(update.manualCommand)
                    }
                } else if belowMinimum {
                    minimumVersionNotice(update: nil)
                    manualCommand(ServerUpdatePresentation.fallbackManualCommand)
                }
            } header: {
                Text("Update")
            } footer: {
                Text(ServerUpdatePresentation.footer(update))
            }
        }
    }

    /// Below-minimum notice. When the server's npm lookup has no qualifying
    /// version it says why, so the section is never an empty dead end. A server
    /// without update info gets only the title; the manual command follows.
    @ViewBuilder
    private func minimumVersionNotice(update: ServerInfo.UpdateInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ServerUpdatePresentation.minimumVersionNoticeTitle)
            if let update, let detail = ServerUpdatePresentation.minimumVersionUnpublishedDetail(
                latestVersion: update.latestVersion,
                isSourceLink: update.isSourceLink
            ) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.themeFgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server.update.minimumVersion")
    }

    @ViewBuilder
    private func manualCommand(_ command: String) -> some View {
        Text(command)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .accessibilityIdentifier("server.update.manualCommand")
        Button(copiedManualCommand ? "Copied" : "Copy Command") {
            UIPasteboard.general.string = command
            copiedManualCommand = true
        }
        .accessibilityIdentifier("server.update.manualCopy")
    }
}

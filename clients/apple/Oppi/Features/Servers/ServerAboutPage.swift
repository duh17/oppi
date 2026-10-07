import SwiftUI
import UIKit

/// About This Server: connection and version facts, plus the update flow.
struct ServerAboutPage: View {
    let model: ServerSettingsModel
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var showUpdateConfirmation = false
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
            updateConfirmationTitle,
            isPresented: $showUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update") {
                Task { await model.startServerUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ServerUpdatePresentation.confirmationMessage)
        }
    }

    private var updateConfirmationTitle: String {
        let update = model.info?.update
        let version = update?.latestVersion ?? update?.targetVersion ?? "the latest version"
        return ServerUpdatePresentation.confirmationTitle(version: version)
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
                                    restartMode: update.restartMode
                                )
                            )
                        }
                        .accessibilityIdentifier("server.update.progress")
                    } else if update.isRestartNeeded {
                        Label("Installed. Restart this Oppi server on the host to use the new version.",
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

                    if update.available, update.isAppUpdatable, !update.isInstalling,
                       !update.isRestarting, !update.isRestartNeeded, !updateDidNotReturn {
                        if let latest = update.latestVersion {
                            Text(ServerUpdatePresentation.availableTitle(latestVersion: latest))
                                .accessibilityIdentifier("server.update.available")
                        }
                        Button("Update") {
                            showUpdateConfirmation = true
                        }
                        .disabled(updateInFlight)
                        .accessibilityIdentifier("server.update.button")
                    } else if !update.isAppUpdatable {
                        manualCommand(update.manualCommand)
                    }
                } else if belowMinimum {
                    Text(ServerUpdatePresentation.minimumVersionNoticeTitle)
                        .accessibilityIdentifier("server.update.available")
                    manualCommand(ServerUpdatePresentation.fallbackManualCommand)
                }
            } header: {
                Text("Update")
            } footer: {
                if update?.isAppUpdatable == true {
                    Text("Updating installs a new oppi-server from npm and restarts this host. Running sessions are interrupted.")
                } else {
                    Text("This install cannot be updated from the app. Run the command on the host, then restart the server.")
                }
            }
        }
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

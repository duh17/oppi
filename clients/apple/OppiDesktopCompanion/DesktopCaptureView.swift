import AppKit
import SwiftUI

struct DesktopCaptureView: View {
    @Bindable var session: DesktopCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select a window. Capture a still, or start a local live preview. Preview is not shared.")
                .foregroundStyle(.secondary)

            statusRow

            localPreview

            stillPreview

            if let message = session.failure?.userMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("capture-failure")
            }

            HStack {
                Button("Select Window", action: session.selectWindow)
                Button("Capture Once", action: session.captureOnce)
                    .disabled(!session.canCapture)
                Button("Cancel", action: session.cancelCapture)
                    .disabled(!session.canCancel)
                Button("Clear", action: session.clear)
                    .disabled(!session.canClear)
            }

            HStack {
                Button("Start Local Preview", action: session.startLocalPreview)
                    .disabled(!session.canStartLocalPreview)
                    .accessibilityIdentifier("start-local-preview")
                Button("Stop Preview", action: session.stopLocalPreview)
                    .disabled(!session.canStopLocalPreview)
                    .accessibilityIdentifier("stop-local-preview")
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            session.refreshAvailability()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let selection = session.selection {
            Text("Selected: \(selection.title)")
        } else {
            Text("No window selected")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var localPreview: some View {
        if session.selection != nil || session.isLocalPreviewActive || session.previewState == .unavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.previewStatusText)
                    .font(session.previewState == .live ? .headline : .body)
                    .foregroundStyle(session.previewState == .unavailable ? .red : .primary)
                    .accessibilityIdentifier(
                        session.previewState == .live ? "local-preview-caption" : "local-preview-status"
                    )
                if let frame = session.previewFrame {
                    Image(nsImage: NSImage(cgImage: frame, size: .zero))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .accessibilityLabel(
                            Text(session.previewLabel ?? session.previewStatusText)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var stillPreview: some View {
        if let still = session.still {
            VStack(alignment: .leading, spacing: 8) {
                Text(DesktopCaptureCopy.stillCaption)
                    .font(.headline)
                    .accessibilityIdentifier("still-caption")
                Text(still.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("still-captured-at")
                Image(nsImage: NSImage(cgImage: still.image, size: .zero))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .accessibilityLabel(Text(DesktopCaptureCopy.stillCaption))
                Toggle(
                    "Share current still locally",
                    isOn: Binding(
                        get: { session.isLocalShareEnabled },
                        set: { enabled in
                            if enabled {
                                session.enableLocalShare()
                            } else {
                                session.revokeLocalShare()
                            }
                        }
                    )
                )
                .accessibilityIdentifier("local-share-toggle")
                Text("Off by default. Local owner presence is not a view grant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Allow paired devices to view this still",
                    isOn: Binding(
                        get: { session.isRemoteViewEnabled },
                        set: { enabled in
                            if enabled {
                                session.enableRemoteView()
                            } else {
                                session.revokeRemoteView()
                            }
                        }
                    )
                )
                .accessibilityIdentifier("remote-view-toggle")
                Text("Off by default. Local share is not remote permission. Still—not live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "No still",
                systemImage: "macwindow",
                description: Text("Capture once to inspect a still locally. This is never live.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

struct DesktopCaptureCommands: Commands {
    var session: DesktopCaptureSession

    var body: some Commands {
        CommandMenu("Capture") {
            Button("Select Window", action: session.selectWindow)
            Button("Capture Once", action: session.captureOnce)
                .disabled(!session.canCapture)
            Button("Start Local Preview", action: session.startLocalPreview)
                .disabled(!session.canStartLocalPreview)
            Button("Stop Preview", action: session.stopLocalPreview)
                .disabled(!session.canStopLocalPreview)
            Button("Cancel", action: session.cancelCapture)
                .disabled(!session.canCancel)
            Button("Clear", action: session.clear)
                .disabled(!session.canClear)
            Divider()
            Button("Share Still Locally", action: session.enableLocalShare)
                .disabled(!session.canEnableLocalShare)
            Button("Revoke Local Share", action: session.revokeLocalShare)
                .disabled(!session.canRevokeLocalShare)
            Divider()
            Button("Allow Paired Devices", action: session.enableRemoteView)
                .disabled(!session.canEnableRemoteView)
            Button("Revoke Paired View", action: session.revokeRemoteView)
                .disabled(!session.canRevokeRemoteView)
        }
    }
}

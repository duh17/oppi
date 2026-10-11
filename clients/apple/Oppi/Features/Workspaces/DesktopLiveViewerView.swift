import SwiftUI

/// iPhone live viewer for a granted Mac window. Picture is the job; Live/Paused
/// is derived from frame arrival. HIG: Feedback (status next to the picture),
/// Loading (show something immediately), Gestures (pinch zoom + double-tap
/// alternative), Accessibility (text status, not color alone; custom action
/// shares the double-tap owner), Scroll views (min/max zoom), Privacy (no
/// stored frames; close on background/lock).
struct DesktopLiveViewerView: View {
    var connection: ServerConnection?

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: DesktopLiveViewerModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView("Connecting…")
                    .accessibilityIdentifier("desktop.live.connecting")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.primary)
        .navigationTitle(model?.arrival.presentation.windowTitle ?? "Remote Screen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model?.retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .disabled(model == nil)
                .accessibilityIdentifier("desktop.live.refresh")
            }
        }
        .task {
            let next = DesktopLiveViewerModel {
                guard let client = connection?.makeDesktopLiveViewStreamClient() else { return nil }
                return (events: client.connect(), disconnect: { client.disconnect() })
            }
            model = next
            next.appear()
        }
        .onAppear {
            model?.appear()
            model?.setSceneActive(scenePhase == .active && !AppLockService.shared.isLocked)
        }
        .onDisappear {
            model?.disappear()
        }
        .onChange(of: scenePhase) { _, phase in
            model?.setSceneActive(phase == .active && !AppLockService.shared.isLocked)
            switch phase {
            case .background:
                model?.backgrounded()
            case .active:
                if !AppLockService.shared.requiresUnlock() {
                    model?.foregrounded()
                }
            default:
                break
            }
        }
        .onChange(of: AppLockService.shared.isLocked) { _, locked in
            model?.setSceneActive(scenePhase == .active && !locked)
            if locked {
                model?.backgrounded()
            } else if scenePhase == .active {
                model?.foregrounded()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: DesktopLiveViewerModel) -> some View {
        switch model.arrival.presentation {
        case .connecting where !model.hasPicture:
            ProgressView("Connecting…")
                .accessibilityIdentifier("desktop.live.connecting")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .waitingForGrant(let message):
            ContentUnavailableView {
                Label("Waiting for grant", systemImage: "macwindow")
            } description: {
                Text(message)
            } actions: {
                retryButton(model)
            }
            .accessibilityIdentifier("desktop.live.waitingForGrant")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't show Remote Screen", systemImage: "macwindow")
            } description: {
                Text(message)
            } actions: {
                retryButton(model)
            }
            .accessibilityIdentifier("desktop.live.failure")
        default:
            picture(model)
        }
    }

    private func picture(_ model: DesktopLiveViewerModel) -> some View {
        ZStack(alignment: .top) {
            DesktopLiveSampleBufferRepresentable(
                accessibilityLabel: model.arrival.presentation.windowTitle ?? "Remote Screen",
                accessibilityValue: statusValue(model.arrival.presentation),
                onView: { model.attachPicture($0) }
            )
            .ignoresSafeArea(edges: .bottom)

            if scenePhase == .active, !AppLockService.shared.isLocked {
                statusChip(model.arrival.presentation)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusChip(_ presentation: DesktopLivePresentation) -> some View {
        let status = presentation.statusText
        let age = presentation.detailText
        let text = age.map { "\(status) · \($0)" } ?? status
        return Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.themeFg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .themedSurface(.floatingControl, in: Capsule())
            .accessibilityIdentifier("desktop.live.status")
            .accessibilityHidden(true)
    }

    private func retryButton(_ model: DesktopLiveViewerModel) -> some View {
        Button("Retry") {
            model.retry()
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("desktop.live.retry")
    }

    private func statusValue(_ presentation: DesktopLivePresentation) -> String {
        if let detail = presentation.detailText {
            return "\(presentation.statusText), \(detail)"
        }
        return presentation.statusText
    }
}

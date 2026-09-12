import SwiftUI
import UIKit

struct DesktopCurrentStillViewerView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.theme) private var theme
    @State private var model: DesktopCurrentStillViewerModel?

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone {
                phoneBody
            } else {
                EmptyView()
            }
        }
    }

    private var phoneBody: some View {
        Group {
            if let model {
                content(model)
            } else if apiClient == nil {
                ContentUnavailableView {
                    Label("Can't show this still", systemImage: "macwindow")
                } description: {
                    Text(DesktopCurrentStillViewerFailure.unavailable.message)
                }
                .accessibilityIdentifier("desktop.still.connectingUnavailable")
            } else {
                ProgressView("Connecting…")
                    .accessibilityIdentifier("desktop.still.connecting")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.primary)
        .navigationTitle("Mac Still")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model?.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(model == nil || model?.canRetry == false)
                .accessibilityLabel("Refresh")
                .accessibilityHint("Reloads the current Mac still without capturing again")
                .accessibilityIdentifier("desktop.still.refresh")
            }
        }
        .task(id: apiClient.map { ObjectIdentifier($0) }) {
            guard let apiClient else {
                model = nil
                return
            }
            let next = DesktopCurrentStillViewerModel {
                try await apiClient.getDesktopCurrentStill()
            }
            model = next
            await next.load()
        }
    }

    @ViewBuilder
    private func content(_ model: DesktopCurrentStillViewerModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…")
                .accessibilityIdentifier("desktop.still.loading")
        case .loaded(let still):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(still.caption)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                        .accessibilityIdentifier("desktop.still.caption")
                    Text(still.surfaceTitle)
                        .font(.body)
                        .foregroundStyle(.themeFg)
                        .accessibilityIdentifier("desktop.still.windowTitle")
                    Text(still.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                        .accessibilityIdentifier("desktop.still.capturedAt")
                    stillImage(still)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if model.isRefreshing {
                    ProgressView()
                        .accessibilityIdentifier("desktop.still.refreshing")
                }
            }
            .refreshable { await model.refresh() }
        case .failed(let failure):
            ContentUnavailableView {
                Label("Can't show this still", systemImage: "macwindow")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Retry") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!model.canRetry)
                .accessibilityIdentifier("desktop.still.retry")
            }
            .accessibilityIdentifier("desktop.still.failure")
        }
    }

    @ViewBuilder
    private func stillImage(_ still: DesktopCurrentStill) -> some View {
        if let image = UIImage(data: still.pngData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(still.caption)
                .accessibilityIdentifier("desktop.still.image")
        }
    }
}

import AppKit
import RealityKit
import SwiftUI

/// Bubbles inline Interact up to `MacSessionTimelineScrollView` so chat scroll locks.
enum MacUSDZInspectScrollLockKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Oppi `![[scene.usdz]]` embed. Chat scroll wins until Interact.
struct MacMarkdownUSDZView: View {
    let embed: MarkdownUSDZEmbed
    var worktreeId: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.macOpenFileViewer) private var openFileViewer
    @State private var handle: USDZLocalFileStore.Handle?
    @State private var didFail = false
    @State private var isInteracting = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let handle {
                MacUSDZRealityCanvas(
                    fileURL: handle.url,
                    cameraControlsEnabled: isInteracting,
                    onLoadFailed: {
                        didFail = true
                        isInteracting = false
                        releaseHandle()
                    }
                )
            } else if didFail {
                VStack(spacing: 8) {
                    Text("Unable to load 3D scene")
                    Text(embed.displayLabel)
                        .foregroundStyle(theme.text.secondary)
                    HStack {
                        Button("Retry") { Task { await load() } }
                        Button("Open file") { openFile() }
                    }
                }
                .font(.caption)
            } else {
                ProgressView()
            }

            HStack(spacing: 8) {
                if handle != nil {
                    if isInteracting {
                        Button("Done") { isInteracting = false }
                    } else {
                        Button("Interact") { isInteracting = true }
                    }
                    Button("Expand") { openFile() }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 360)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(embed.displayLabel)
        .accessibilityIdentifier("markdown-usdz")
        .contentShape(Rectangle())
        .scrollDisabled(isInteracting)
        .preference(key: MacUSDZInspectScrollLockKey.self, value: isInteracting)
        .task(id: loadIdentity) {
            await load()
        }
        .onDisappear {
            isInteracting = false
            releaseHandle()
        }
    }

    private var loadIdentity: String {
        [
            embed.filePath,
            embed.reference.workspaceID ?? "",
            embed.reference.sourceSessionID ?? "",
            worktreeId ?? "",
        ].joined(separator: "|")
    }

    private func load() async {
        didFail = false
        releaseHandle()
        let requested = loadIdentity
        let key = USDZLocalFileStore.cacheKey(
            kind: embed.reference.kind,
            workspaceID: embed.reference.workspaceID,
            sessionID: embed.reference.sourceSessionID,
            worktreeID: worktreeId,
            path: embed.filePath
        )
        let data: Data?
        switch embed.reference.kind {
        case .hostFile:
            data = await MacMarkdownWorkspaceFileLoader.data(
                for: .hostFile(path: embed.filePath),
                sessionID: nil
            )
        case .workspaceFile:
            guard let workspaceID = embed.reference.workspaceID, !workspaceID.isEmpty else {
                didFail = true
                return
            }
            data = await MacMarkdownWorkspaceFileLoader.data(
                path: embed.filePath,
                workspaceID: workspaceID,
                sessionID: embed.reference.sourceSessionID,
                worktreeId: worktreeId
            )
        }
        guard !Task.isCancelled, loadIdentity == requested else { return }
        guard let data, !data.isEmpty else {
            didFail = true
            return
        }
        do {
            let stored = try await USDZLocalFileStore.shared.store(key: key, data: data)
            guard !Task.isCancelled, loadIdentity == requested else {
                await USDZLocalFileStore.shared.release(stored)
                return
            }
            handle = stored
        } catch {
            didFail = true
        }
    }

    private func openFile() {
        if let plan = FileViewerPlan.opening(reference: embed.reference, worktreeId: worktreeId) {
            openFileViewer(plan)
        }
    }

    private func releaseHandle() {
        isInteracting = false
        guard let handle else { return }
        self.handle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }
}

/// Document-column USDZ viewer. Immediately interactive.
struct MacToolDocumentUSDZView: View {
    let file: ToolContentDescriptor.File
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    @State private var handle: USDZLocalFileStore.Handle?
    @State private var didFail = false

    var body: some View {
        Group {
            if let handle {
                MacUSDZRealityCanvas(fileURL: handle.url, cameraControlsEnabled: true)
                    .accessibilityIdentifier("mac.documentColumn.usdz")
            } else if didFail {
                ContentUnavailableView(
                    "Unable to Display 3D Scene",
                    systemImage: "cube",
                    description: Text(file.filePath ?? "USDZ")
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadIdentity) {
            await load()
        }
        .onDisappear {
            releaseHandle()
        }
    }

    private var loadIdentity: String {
        "\(file.filePath ?? "")|\(workspaceID ?? "")|\(sessionID ?? "")|\(worktreeId ?? "")"
    }

    private func load() async {
        let requestedIdentity = loadIdentity
        didFail = false
        releaseHandle()
        guard let path = file.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            didFail = true
            return
        }
        let data: Data?
        if path.hasPrefix("/") || path.hasPrefix("~") {
            data = await MacMarkdownWorkspaceFileLoader.data(
                for: .hostFile(path: path),
                sessionID: nil
            )
        } else if let workspaceID, !workspaceID.isEmpty {
            data = await MacMarkdownWorkspaceFileLoader.data(
                path: path,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        } else {
            didFail = true
            return
        }
        guard !Task.isCancelled, loadIdentity == requestedIdentity else { return }
        guard let data, !data.isEmpty else {
            didFail = true
            return
        }
        let key = USDZLocalFileStore.cacheKey(
            kind: path.hasPrefix("/") || path.hasPrefix("~") ? .hostFile : .workspaceFile,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeId,
            path: path
        )
        do {
            let stored = try await USDZLocalFileStore.shared.store(key: key, data: data)
            guard !Task.isCancelled, loadIdentity == requestedIdentity else {
                await USDZLocalFileStore.shared.release(stored)
                return
            }
            handle = stored
        } catch {
            didFail = true
        }
    }

    private func releaseHandle() {
        guard let handle else { return }
        self.handle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }
}

struct MacUSDZRealityCanvas: View {
    let fileURL: URL
    var cameraControlsEnabled: Bool
    var onLoadFailed: (() -> Void)? = nil
    @State private var yaw: Float = 0
    @State private var pitch: Float = 0
    @State private var zoom: Float = 1
    @State private var pan: SIMD2<Float> = .zero
    @State private var pinchStart: Float = 1
    @State private var isMagnifying = false
    @GestureState private var dragStart: CGSize = .zero

    var body: some View {
        let canvas = RealityView { content in
            do {
                let model = try await Entity(contentsOf: fileURL, withName: nil)
                content.add(Self.inspectionRoot(for: model))
            } catch {
                onLoadFailed?()
            }
        } update: { content in
            guard let gimbal = content.entities.first?.findEntity(named: Self.gimbalName) else { return }
            let clampedPitch = min(1.2, max(-1.2, pitch))
            let clampedZoom = min(3, max(0.35, zoom))
            let clampedPan = SIMD2(min(1.6, max(-1.6, pan.x)), min(1.6, max(-1.6, pan.y)))
            let pitchQ = simd_quatf(angle: clampedPitch, axis: SIMD3<Float>(1, 0, 0))
            let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            gimbal.orientation = pitchQ * yawQ
            gimbal.scale = SIMD3<Float>(repeating: clampedZoom)
            gimbal.position = SIMD3<Float>(clampedPan.x, clampedPan.y, 0)
        }
        .realityViewCameraControls(.none)
        .modifier(USDZCenteredLayout())
        .accessibilityHint("Drag to orbit, pinch to zoom, shift-drag to pan")

        if cameraControlsEnabled {
            canvas
                .contentShape(Rectangle())
                .highPriorityGesture(orbitAndPan)
                .simultaneousGesture(magnifyZoom)
        } else {
            canvas
        }
    }

    private var orbitAndPan: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - dragStart.width,
                    height: value.translation.height - dragStart.height
                )
                if NSEvent.modifierFlags.contains(.shift) {
                    pan += SIMD2(Float(delta.width) * 0.004, Float(-delta.height) * 0.004)
                } else {
                    yaw += Float(delta.width) * 0.01
                    pitch -= Float(delta.height) * 0.01
                }
            }
            .updating($dragStart) { value, state, _ in
                state = value.translation
            }
    }

    private var magnifyZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    pinchStart = zoom
                }
                zoom = min(3, max(0.35, pinchStart * Float(value.magnification)))
            }
            .onEnded { _ in
                isMagnifying = false
                pinchStart = zoom
            }
    }

    private static let gimbalName = "usdz-gimbal"

    @discardableResult
    private static func inspectionRoot(for model: Entity) -> Entity {
        let gimbal = Entity()
        gimbal.name = gimbalName
        gimbal.addChild(model)
        let root = Entity()
        root.name = "usdz-root"
        root.addChild(gimbal)
        return root
    }
}

private struct USDZCenteredLayout: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.realityViewLayoutBehavior(.centered)
        } else {
            content
        }
    }
}

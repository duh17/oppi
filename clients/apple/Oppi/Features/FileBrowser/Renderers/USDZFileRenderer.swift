import UIKit

/// A 3D scene, stored as a local file the interactive scene view opens.
final class USDZFileRenderer: FileRenderer {
    private let handle: USDZLocalFileStore.Handle
    private let fileName: String

    private init(handle: USDZLocalFileStore.Handle, fileName: String) {
        self.handle = handle
        self.fileName = fileName
    }

    static func load(_ file: FileRenderInput) async throws -> USDZFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        let access = file.access
        let key = USDZLocalFileStore.cacheKey(
            kind: access.source == .hostFile ? .hostFile : .workspaceFile,
            workspaceID: access.workspaceId,
            sessionID: access.sessionId,
            worktreeID: access.worktreeId,
            path: access.revision.map { "\($0):\(file.path)" } ?? file.path
        )
        let handle = try await USDZLocalFileStore.shared.store(key: key, data: read.data)
        guard file.isCurrent() else {
            await USDZLocalFileStore.shared.release(handle)
            return nil
        }
        return USDZFileRenderer(handle: handle, fileName: file.fileName)
    }

    /// The interactive scene keeps horizontal drags; the viewer adds no back swipe.
    var ownsBackSwipe: Bool { true }
    /// The local file goes when the viewer leaves the screen.
    var retention: FileRendererRetention { .releaseOffScreen }

    func release() {
        let handle = handle
        Task { await USDZLocalFileStore.shared.release(handle) }
    }

    func mount(in host: FileRendererHost) -> UIView {
        let page = UIView()
        host.addPage(page)
        let scene = USDZSceneView()
        scene.isInteractive = true
        scene.accessibilityIdentifier = "file-browser-usdz"
        scene.accessibilityLabel = fileName
        scene.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scene)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scene.topAnchor.constraint(equalTo: safe.topAnchor),
            scene.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scene.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scene.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        let fileName = fileName
        let fileURL = handle.url
        scene.onLoadFailed = { [weak host, weak page, weak scene] in
            guard let host, let page, let scene else { return }
            scene.clear()
            scene.isHidden = true
            let unavailable = host.makeStateView(.failed(
                title: String(localized: "Unable to load 3D scene"),
                message: fileName,
                retry: RetryAction { [weak host, weak scene] in
                    guard let scene else { return }
                    host?.removeStateView()
                    scene.isHidden = false
                    scene.show(fileURL: fileURL)
                }
            ))
            unavailable.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(unavailable)
            NSLayoutConstraint.activate([
                unavailable.topAnchor.constraint(equalTo: page.safeAreaLayoutGuide.topAnchor),
                unavailable.bottomAnchor.constraint(equalTo: page.safeAreaLayoutGuide.bottomAnchor),
                unavailable.leadingAnchor.constraint(equalTo: page.safeAreaLayoutGuide.leadingAnchor),
                unavailable.trailingAnchor.constraint(equalTo: page.safeAreaLayoutGuide.trailingAnchor),
            ])
        }
        scene.show(fileURL: handle.url)
        return page
    }
}

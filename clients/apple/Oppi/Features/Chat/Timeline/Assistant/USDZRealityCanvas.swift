import RealityKit
import SwiftUI

/// The one SwiftUI leaf of the USDZ preview: RealityKit's `RealityView` is
/// SwiftUI-only, so the canvas stays SwiftUI and everything around it
/// (`USDZSceneView`'s gestures and accessibility, the inline card's chrome,
/// the full-screen controller) is UIKit.
///
/// Inputs are values: the file, the inspect pose the UIKit gestures edit, and
/// a load-failure callback. `USDZSceneView` mounts `USDZRealityCanvasHost` and
/// hands it a new pose as the gestures move.
struct USDZRealityCanvas: View {
    let fileURL: URL
    let pose: USDZInspectPose
    let onLoadFailed: () -> Void

    var body: some View {
        RealityView { content in
            do {
                let model = try await Entity(contentsOf: fileURL, withName: nil)
                content.add(Self.inspectionRoot(for: model))
            } catch {
                onLoadFailed()
            }
        } update: { content in
            pose.apply(to: content.entities.first?.findEntity(named: Self.gimbalName))
        } placeholder: {
            ProgressView()
                .tint(.themeBlue)
        }
        .realityViewCameraControls(.none)
        .realityViewLayoutBehavior(.centered)
    }

    private static let gimbalName = "usdz-gimbal"

    /// Do not call `visualBounds` in `make` — it can hang USDZ loads on iOS.
    /// `.centered` measures bounds after `make` returns.
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

extension USDZInspectPose {
    @MainActor
    func apply(to gimbal: Entity?) {
        guard let gimbal else { return }
        let pitchQ = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        gimbal.orientation = pitchQ * yawQ
        gimbal.scale = SIMD3<Float>(repeating: zoom)
        gimbal.position = SIMD3<Float>(pan.x, pan.y, 0)
    }
}

/// The canvas as UIKit: `USDZSceneView` mounts this in its own view and keeps the
/// inspect gestures, which is why the canvas itself takes no touches. This file's one
/// `UIHostingController` (allowed by `scripts/uikit-structure-guard.ts`); it publishes
/// no app environment, because the canvas takes values only.
@MainActor
final class USDZRealityCanvasHost: UIHostingController<USDZRealityCanvas> {
    private let onLoadFailed: () -> Void

    init(fileURL: URL, pose: USDZInspectPose, onLoadFailed: @escaping () -> Void) {
        self.onLoadFailed = onLoadFailed
        super.init(rootView: USDZRealityCanvas(fileURL: fileURL, pose: pose, onLoadFailed: onLoadFailed))
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    /// The gestures moved: RealityKit applies the pose in `update`.
    func show(fileURL: URL, pose: USDZInspectPose) {
        rootView = USDZRealityCanvas(fileURL: fileURL, pose: pose, onLoadFailed: onLoadFailed)
    }
}

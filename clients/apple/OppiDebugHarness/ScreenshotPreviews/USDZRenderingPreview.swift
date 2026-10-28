#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - USDZ inspect preview

/// Production RealityView USDZ viewer, mounted the way the file viewer mounts
/// it (`USDZSceneView`, interactive). Not a snapshot Image.
struct USDZRenderingPreview: View {
    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        Group {
            if let url = Bundle.main.url(
                forResource: "suzanne-garden",
                withExtension: "usdz"
            ) {
                USDZSceneHost(fileURL: url, accessibilityName: "Suzanne garden")
            } else {
                Text("Missing suzanne-garden.usdz")
                    .foregroundStyle(.red)
            }
        }
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}

/// A controller around one interactive `USDZSceneView`, so the canvas has a
/// parent controller to join, as it does in the file viewer.
private struct USDZSceneHost: UIViewControllerRepresentable {
    let fileURL: URL
    let accessibilityName: String

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let scene = USDZSceneView()
        scene.isInteractive = true
        scene.accessibilityIdentifier = "file-browser-usdz"
        scene.accessibilityLabel = accessibilityName
        scene.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(scene)
        NSLayoutConstraint.activate([
            scene.topAnchor.constraint(equalTo: controller.view.topAnchor),
            scene.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            scene.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            scene.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
        ])
        scene.show(fileURL: fileURL)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// `SCREENSHOT_SCREEN=usdz-fullscreen` (the expanded scene loaded through its
/// file provider) and `usdz-fullscreen-failed` (the provider throws: Retry and
/// Open file): the production `FullScreenUSDZViewController` in the
/// navigation controller the router presents it in.
struct USDZFullScreenPreviewHost: UIViewControllerRepresentable {
    let failing: Bool

    func makeUIViewController(context: Context) -> UINavigationController {
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
        let embed = MarkdownUSDZEmbed(reference: ResourceReference(
            target: "models/suzanne-garden.usdz",
            sourceServerID: "preview",
            workspaceID: "preview",
            sourceSessionID: nil,
            fileCandidatePath: "models/suzanne-garden.usdz",
            visibleLabel: "Suzanne garden"
        ))
        let failing = failing
        let screen = FullScreenUSDZViewController(
            embed: embed,
            initialHandle: nil,
            fileProvider: { _ in
                guard !failing,
                      let url = Bundle.main.url(forResource: "suzanne-garden", withExtension: "usdz") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try await USDZLocalFileStore.shared.store(key: "preview-suzanne", data: Data(contentsOf: url))
            }
        )
        let navigation = UINavigationController(rootViewController: screen)
        navigation.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        navigation.view.accessibilityIdentifier = "screenshot.ready"
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {}
}
#endif

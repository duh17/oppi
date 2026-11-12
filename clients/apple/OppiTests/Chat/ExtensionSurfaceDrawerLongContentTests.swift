import Foundation
import Testing
import UIKit
@testable import Oppi

/// A drawer whose body is taller than its cap: it scrolls, offers full screen, and a code block in
/// it offers to expand. Drawn in a real window at a phone's width.
@Suite("Composable extension surface drawer, long content (UIKit)")
@MainActor
struct ExtensionSurfaceDrawerLongContentTests {
    private let themeID = ThemeID.dark
    private static var windows: [UIWindow] = []

    private static let pillId = "extension-strip-aboveEditor-pill-surface-output"
    private static let fullScreenId = "extension.strip.fullScreen.aboveEditor"
    private static let expandId = "extension.surface.output.card.log.expand"

    // MARK: - Drawer

    @Test func aDrawerTallerThanItsCapScrollsAndOffersFullScreen() throws {
        let log = (1...40).map { "line \($0) of a long log" }.joined(separator: "\n")
        var opened: [ChatReaderPayload] = []
        let panel = try makePanel(surface(log: log), onOpen: { opened.append($0) })
        open(panel)

        let capped = try #require(subviews(of: CappedScrollView.self, in: panel).first)
        #expect(capped.overflows, "40 lines are taller than the cap")
        #expect(capped.scrollView.isScrollEnabled, "a body taller than the cap scrolls")
        #expect(capped.bounds.height <= ExtensionNativeSurfaceLayout.expandedMaxHeight + 0.5)
        let button = try #require(control(Self.fullScreenId, in: panel) as? UIControl)
        #expect(!button.isHidden, "a drawer that outgrew its cap offers full screen")

        button.sendActions(for: .touchUpInside)
        let payload = try #require(opened.first)
        guard case .extensionSurface(let reader) = payload.kind else {
            Issue.record("full screen opens the surface reader, got \(payload.kind)")
            return
        }
        #expect(reader.surface.id == "output")
        #expect(reader.title == "Output")
    }

    @Test func aDrawerThatFitsItsCapOffersNoFullScreen() throws {
        let panel = try makePanel(surface(log: "one\ntwo"), onOpen: { _ in })
        open(panel)

        let capped = try #require(subviews(of: CappedScrollView.self, in: panel).first)
        #expect(!capped.overflows)
        #expect(!capped.scrollView.isScrollEnabled)
        let button = try #require(control(Self.fullScreenId, in: panel))
        #expect(button.isHidden, "there is nothing more to see full screen")
    }

    @Test func aCodeBlockInTheDrawerExpandsToTheCodeReader() throws {
        let log = (1...40).map { "line \($0)" }.joined(separator: "\n")
        var opened: [ChatReaderPayload] = []
        let panel = try makePanel(surface(log: log), onOpen: { opened.append($0) })
        open(panel)

        let expand = try #require(control(Self.expandId, in: panel) as? UIControl)
        #expect(!expand.isHidden)
        expand.sendActions(for: .touchUpInside)
        let payload = try #require(opened.first)
        guard case .document(let content, _) = payload.kind, case .code(let text, let language, _, _) = content else {
            Issue.record("expand opens the code reader, got \(payload.kind)")
            return
        }
        #expect(text == log, "the reader holds the whole block")
        #expect(language == "output")
    }

    @Test func aCodeBlockOnAHostWithNoReaderHasNoExpandControl() throws {
        let view = ExtensionSurfaceCompositesView()
        show(view)
        view.apply(surface: try surface(log: "one\ntwo"), pending: nil, themeID: themeID, onAction: nil)
        view.layoutIfNeeded()

        let expand = try #require(control(Self.expandId, in: view))
        #expect(expand.isHidden, "no reader to open: the header shows wrap and copy only")
    }

    // MARK: - Helpers

    /// A surface with one `blocks` card holding a code node named `log`.
    private func surface(log: String) throws -> ExtensionUISurface {
        let object: [String: Any] = [
            "version": 2, "id": "output", "title": "Output",
            "placement": ["kind": "strip"],
            "lifecycle": "persistent",
            "header": ["title": "Output", "subtitle": "a long log"],
            "actions": [String: Any](),
            "fallback": ["text": "Output"],
            "revision": 1,
            "sections": [[
                "composite": "blocks", "id": "card",
                "state": ["kind": "content"],
                "fallback": ["text": "Output"],
                "body": [
                    "type": "stack", "id": "list",
                    "children": [["type": "code", "id": "log", "language": "output", "text": log]],
                ],
            ]],
        ]
        return try JSONDecoder().decode(ExtensionUISurface.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func makePanel(
        _ surface: ExtensionUISurface,
        onOpen: @escaping (ChatReaderPayload) -> Void
    ) -> ExtensionSurfacePanelView {
        let state = ExtensionSurfaceState(composableSurfaces: [
            surface.id: ExtensionComposableSurfaceState(surface: surface, order: 1),
        ])
        let panel = ExtensionSurfacePanelView(
            placement: .aboveEditor,
            actions: ExtensionSurfaceDrawerActions(openReader: onOpen)
        )
        panel.apply(ExtensionSurfacePanelView.Content(
            surface: state,
            messageQueue: nil,
            themeID: themeID,
            collapseRequestID: 0
        ))
        show(panel, inset: 0)
        panel.layoutIfNeeded()
        return panel
    }

    /// Taps the surface's pill, then lays the drawer out twice: the scroll view measures its
    /// content in its own pass, after its parent's.
    private func open(_ panel: ExtensionSurfacePanelView) {
        (control(Self.pillId, in: panel) as? UIControl)?.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        panel.layoutIfNeeded()
    }

    private func show(_ view: UIView, inset: CGFloat = 28) {
        for window in Self.windows { window.isHidden = true }
        Self.windows.removeAll()
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 2400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.view.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -inset),
        ])
        host.view.layoutIfNeeded()
        Self.windows.append(window)
    }

    private func control(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + subviews(of: UIView.self, in: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) + subviews(of: type, in: child)
        }
    }
}

import Foundation
import Testing
import UIKit
@testable import Oppi

/// Badge Icon marks and saves the store's own answer.
@Suite("Badge Icon page", .serialized)
@MainActor
struct ServerBadgePageTests {
    private func present(_ page: UIViewController, height: CGFloat = 1600) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        return window
    }

    private func makeServer() throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: "about.test", port: 7749, token: "sk_test", name: "about", scheme: .https, serverFingerprint: "about-server"),
            sortOrder: 0
        ))
    }


    private func loadedStore(_ server: PairedServer) -> ServerStore {
        let store = ServerStore(loadServers: { .init(records: [server], unreadableIds: []) })
        store.load()
        return store
    }

    @Test("Choosing an icon saves it for the pinned server, and the grid marks the saved one")
    func choosingSavesAndMarks() async throws {
        let server = try makeServer()
        let store = loadedStore(server)
        defer { KeychainService.deleteServer(id: server.id) }
        let root = makeTestAppRoot(coordinator: ConnectionCoordinator(serverStore: store))
        let page = ServerBadgeViewController(server: server, root: root)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(Self.selectedIcons(in: page.view) == [ServerBadgeIcon.defaultValue.rawValue])

        page.choose(.cloud)

        #expect(store.server(for: server.id)?.resolvedBadgeIcon == .cloud)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.selectedIcons(in: page.view) == [ServerBadgeIcon.cloud.rawValue]
        })
    }

    @Test("A save the store refuses leaves the old icon marked")
    func refusedSaveKeepsTheOldMark() async throws {
        let server = try makeServer()
        // A store that never loaded the pairing list refuses every change.
        let store = ServerStore()
        store.replaceServersForPreview([server])
        let root = makeTestAppRoot(coordinator: ConnectionCoordinator(serverStore: store))
        let page = ServerBadgeViewController(server: server, root: root)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }

        page.choose(.cloud)
        page.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        page.view.layoutIfNeeded()

        #expect(store.server(for: server.id)?.resolvedBadgeIcon == .defaultValue)
        #expect(Self.selectedIcons(in: page.view) == [ServerBadgeIcon.defaultValue.rawValue])
    }

    @Test("Every icon has a button of its own with a name VoiceOver can speak")
    func everyIconHasAButton() async throws {
        let server = try makeServer()
        let root = makeTestAppRoot(coordinator: ConnectionCoordinator(serverStore: loadedStore(server)))
        let page = ServerBadgeViewController(server: server, root: root)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil; KeychainService.deleteServer(id: server.id) }

        let buttons = Self.iconButtons(in: page.view)
        #expect(Set(buttons.keys) == Set(ServerBadgeIcon.allCases.map { "server.badge.\($0.rawValue)" }))
        #expect(Set(buttons.values.compactMap(\.accessibilityLabel)).count == ServerBadgeIcon.allCases.count)
        #expect(ServerBadgeViewController.footer.contains("orange recovering"))
    }

    private static func iconButtons(in view: UIView) -> [String: UIButton] {
        var found: [String: UIButton] = [:]
        func walk(_ view: UIView) {
            if let button = view as? UIButton, let id = button.accessibilityIdentifier, id.hasPrefix("server.badge.") { found[id] = button }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private static func selectedIcons(in view: UIView) -> [String] {
        iconButtons(in: view).filter { $0.value.accessibilityTraits.contains(.selected) }
            .map { String($0.key.dropFirst("server.badge.".count)) }
    }
}

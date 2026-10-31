import Foundation
import Testing
import UIKit
@testable import Oppi

/// The one menu of paired servers the session lists' switcher, a catalog's
/// server row, and a locked cover's Switch Server button all open: every row
/// wears its server's badge, the shown server is the menu's own checkmark, a
/// gated server wears its lock, and a cover leaves out the server it is on.
@Suite("Server switch menu")
@MainActor
struct ServerSwitchMenuTests {
    private func server(_ id: String, _ name: String, badge: ServerBadgeIcon) throws -> PairedServer {
        var server = try #require(PairedServer(
            from: ServerCredentials(host: "\(UUID().uuidString).held.test", port: 7749, token: "sk_test", name: name, scheme: .https, serverFingerprint: id),
            sortOrder: 0
        ))
        server.badgeIcon = badge
        return server
    }

    /// Paired but never connected, so every row says it is offline.
    private func coordinator(_ servers: [PairedServer]) -> ConnectionCoordinator {
        let store = ServerStore()
        store.replaceServersForPreview(servers)
        return ConnectionCoordinator(serverStore: store)
    }

    private func rows(_ elements: [UIMenuElement]) throws -> [UIAction] {
        let group = try #require(elements.first as? UIMenu)
        return group.children.compactMap { $0 as? UIAction }
    }

    @Test("The shown server is the menu's checkmark, and every row wears its badge")
    func shownServerIsCheckedAndRowsWearBadges() throws {
        let alpha = try server("sha256:menu-alpha", "Alpha", badge: .macStudio)
        let beta = try server("sha256:menu-beta", "Beta", badge: .desktop)
        let menu = ServerSwitchMenu(
            coordinator: coordinator([alpha, beta]),
            currentServerId: alpha.id,
            activate: { _ in }
        )

        let rows = try rows(menu.elements())
        #expect(rows.count == 2)
        // Offline servers name their state beside the name, as the switcher always has.
        #expect(rows.map { $0.title.hasPrefix("Alpha") || $0.title.hasPrefix("Beta") } == [true, true])
        // The current one is checked by the menu, so it keeps its own artwork.
        #expect(rows.map(\.state) == [.on, .off])
        #expect(rows[0].image?.pngData() == EntityIcon.image(.server(alpha.id, .macStudio), size: 22).pngData())
        #expect(rows[1].image?.pngData() == EntityIcon.image(.server(beta.id, .desktop), size: 22).pngData())
        #expect(rows[0].image?.pngData() != rows[1].image?.pngData())
    }

    @Test("A gated server's row wears its lock and says it is locked")
    func gatedServerWearsItsLock() throws {
        let locked = try server("sha256:menu-locked-\(UUID().uuidString)", "Locked", badge: .macStudio)
        let unlocked = try server("sha256:menu-open-\(UUID().uuidString)", "Open", badge: .macPro)
        let free = try server("sha256:menu-free-\(UUID().uuidString)", "Free", badge: .laptop)
        let locks = ScopedLockService.shared
        defer {
            locks.forgetServer(locked.id)
            locks.forgetServer(unlocked.id)
        }
        locks.lock(.server(serverId: locked.id))
        locks.lock(.server(serverId: unlocked.id))
        locks.noteCreated(.server(unlocked.id))

        let rows = try rows(ServerSwitchMenu(
            coordinator: coordinator([locked, unlocked, free]),
            currentServerId: free.id,
            activate: { _ in }
        ).elements())

        // Both gated servers show a lock in place of their badge, and the open one
        // shows a different lock; an ungated server keeps its badge.
        #expect(rows[0].image?.pngData() != EntityIcon.image(.server(locked.id, .macStudio), size: 22).pngData())
        #expect(rows[1].image?.pngData() != EntityIcon.image(.server(unlocked.id, .macPro), size: 22).pngData())
        #expect(rows[0].image?.pngData() != rows[1].image?.pngData())
        #expect(rows[2].image?.pngData() == EntityIcon.image(.server(free.id, .laptop), size: 22).pngData())
        #expect(rows[0].accessibilityValue?.hasSuffix(", Locked") == true)
        #expect(rows[1].accessibilityValue?.hasSuffix(", Unlocked") == true)
        #expect(rows[2].accessibilityValue?.hasSuffix("Locked") == false)
    }

    @Test("A cover leaves out the server it is on and adds the caller's rows after the servers")
    func coverOmitsItsServerAndAddsExtras() throws {
        let alpha = try server("sha256:menu-cover-alpha", "Alpha", badge: .macStudio)
        let beta = try server("sha256:menu-cover-beta", "Beta", badge: .macMini)
        let elements = ServerSwitchMenu(
            coordinator: coordinator([alpha, beta]),
            currentServerId: nil,
            omitting: alpha.id,
            extras: { [UIAction(title: "Usage") { _ in }] },
            activate: { _ in }
        ).elements()

        let rows = try rows(elements)
        #expect(rows.map { $0.title.hasPrefix("Beta") } == [true])
        // Nothing is current on a cover, so nothing is checked.
        #expect(rows.allSatisfy { $0.state == .off })
        #expect(elements.count == 2)
        #expect((elements.last as? UIAction)?.title == "Usage")
    }
}

import Foundation
import LocalAuthentication
import Synchronization
import Testing
import UIKit
@testable import Oppi

/// Saved hosts and tailnet Rex nodes for a test: its own defaults suites and the
/// shared in-memory keychain, so nothing reaches the app's real stores.
private struct IsolatedStores {

    /// The suites this test owns, made once and named, so they can be taken away
    /// again. A `UserDefaults` is thread-safe, which is the one thing this says to
    /// the compiler (as `SSHTerminalProfileStore` says for its own), and a test
    /// never falls back to the app's domain: another test running beside it reads
    /// that.
    private final class Suites: @unchecked Sendable {
        let hosts: UserDefaults
        let rex: UserDefaults
        let bar: UserDefaults
        private let names: [String]
        /// A suite made for one test after this object was built (a corrupt
        /// catalog), named so it goes with the rest.
        private let tracked = Mutex<[String]>([])

        init() throws {
            let hostName = "SSHTerminalSettingsTests.hosts.\(UUID().uuidString)"
            let rexName = "SSHTerminalSettingsTests.rex.\(UUID().uuidString)"
            let barName = "SSHTerminalSettingsTests.bar.\(UUID().uuidString)"
            hosts = try #require(UserDefaults(suiteName: hostName))
            rex = try #require(UserDefaults(suiteName: rexName))
            bar = try #require(UserDefaults(suiteName: barName))
            names = [hostName, rexName, barName]
        }

        func track(_ name: String) {
            tracked.withLock { $0.append(name) }
        }

        func remove() {
            for name in names + tracked.withLock({ $0 }) { hosts.removePersistentDomain(forName: name) }
        }
    }

    private let suites: Suites
    private let keychain = MemoryKeychain()

    init() throws {
        suites = try Suites()
    }

    var profileStore: @Sendable () -> SSHTerminalProfileStore {
        let suites = self.suites
        let keychain = self.keychain
        return { SSHTerminalProfileStore(defaults: suites.hosts, keychain: keychain) }
    }

    var rexStore: RexDirectStore {
        RexDirectStore(defaults: suites.rex)
    }

    var barStore: SSHTerminalBarStore {
        SSHTerminalBarStore(defaults: suites.bar)
    }

    func save(_ profiles: [SSHTerminalProfile]) throws {
        let store = profileStore()
        for profile in profiles { try store.save(profile) }
    }

    /// A host store whose saved metadata does not decode, in a suite of its own.
    func corruptProfileStore() throws -> SSHTerminalProfileStore {
        let name = "SSHTerminalSettingsTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        suites.track(name)
        // A slot's container can hold an older run's suite under this name.
        defaults.removePersistentDomain(forName: name)
        defaults.set(Data("not a catalog".utf8), forKey: SSHTerminalProfileStore.catalogKey)
        return SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
    }

    /// The suites go with the test, so a slot's container does not fill up.
    func removeSuites() {
        suites.remove()
    }
}

/// Settings › Terminal and its Rex on Your Tailnet page: the setup the Terminal
/// page no longer carries.
@Suite("Terminal settings", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalSettingsTests {
    private let hosts: IsolatedStores

    private let plain = SSHTerminalProfile(host: "devbox.local", port: 2222, username: "dev", authentication: .deviceKey)
    private let other = SSHTerminalProfile(host: "mac-studio.local", username: "chen", startupCommand: "herdr")

    init() throws {
        hosts = try IsolatedStores()
    }

    // MARK: - Settings › Terminal

    /// Every saved host is a row that opens its form, beside Rex on Your Tailnet
    /// and the Bottom Bar.
    @Test func savedHostsAreRowsThatNameTheirHost() throws {
        defer { hosts.removeSuites() }
        try hosts.save([plain, other])
        let page = try mountSettings()
        defer { page.window.isHidden = true }

        #expect(page.identifiers.contains("settings.sshTerminal.list"))
        #expect(page.identifiers.contains("settings.sshTerminal.host.\(plain.id.uuidString)"))
        #expect(page.identifiers.contains("settings.sshTerminal.host.\(other.id.uuidString)"))
        #expect(page.identifiers.contains("settings.sshTerminal.rexTailnet"))
        #expect(page.identifiers.contains("settings.sshTerminal.bar"))

        let row = try #require(page.element("settings.sshTerminal.host.\(plain.id.uuidString)"))
        #expect(row.accessibilityLabel == "dev@devbox.local")
        #expect(row.accessibilityValue == "Port 2222")
    }

    /// Metadata that cannot be read says so, with no host row to open.
    @Test func unreadableHostsSaySoAndListNothing() throws {
        defer { hosts.removeSuites() }
        let broken = try hosts.corruptProfileStore()
        #expect(broken.metadataIsCorrupt)
        let page = try mountSettings(profileStore: { broken })
        defer { page.window.isHidden = true }

        #expect(page.identifiers.contains("settings.sshTerminal.hosts.unreadable"))
        #expect(!page.identifiers.contains { $0.hasPrefix("settings.sshTerminal.host.") })
    }

    /// The tailnet row counts what was added, so the page says at a glance
    /// whether anything is listed there.
    @Test func theTailnetRowCountsWhatWasAdded() throws {
        defer { hosts.removeSuites() }
        let page = try mountSettings()
        defer { page.window.isHidden = true }
        #expect(try #require(page.element("settings.sshTerminal.rexTailnet")).accessibilityValue == "None added")

        hosts.rexStore.saveTailnetHost(try #require(RexTailnetHost(dnsName: "rex.tail0000.ts.net")))
        hosts.rexStore.saveTailnetHost(try #require(RexTailnetHost(dnsName: "build.tail0000.ts.net")))
        page.reload()
        #expect(try #require(page.element("settings.sshTerminal.rexTailnet")).accessibilityValue == "2 Rex")
    }

    /// The Bottom Bar row names the buttons the bar draws now, and follows the
    /// layout when one is turned off.
    @Test func theBarRowNamesTheButtonsTheBarDraws() throws {
        defer { hosts.removeSuites() }
        let page = try mountSettings()
        defer { page.window.isHidden = true }
        let keyboard = SSHTerminalBarItem.action(.keyboard).title(customKeys: [])
        let herdr = SSHTerminalBarItem.action(.herdr).title(customKeys: [])
        #expect(try #require(page.element("settings.sshTerminal.bar")).accessibilityValue?.contains(keyboard) == true)

        hosts.barStore.setLayout(hosts.barStore.layout.setting(.action(.herdr), shown: false))
        page.reload()
        let row = try #require(page.element("settings.sshTerminal.bar"))
        let value = try #require(row.accessibilityValue)
        #expect(!value.contains(herdr))
        #expect(value.contains(keyboard))
    }

    // MARK: - Experiments

    /// Rex off: the page has no Rex on Your Tailnet row at all (its section is
    /// dropped), and the Bottom Bar summary names neither Rex nor Herdr while their
    /// switches are off.
    @Test func withTheExperimentsOffThereIsNoRexRowAndTheBarSummaryLeavesThemOut() throws {
        defer { hosts.removeSuites() }
        try hosts.save([plain])
        let off = SSHTerminalExperimentAccess(rex: false, herdr: false)
        let page = try mountSettings(experiments: { off })
        defer { page.window.isHidden = true }

        #expect(!page.identifiers.contains("settings.sshTerminal.rexTailnet"))
        let summary = try #require(page.element("settings.sshTerminal.bar")?.accessibilityValue)
        let rex = SSHTerminalBarItem.action(.rex).title(customKeys: [])
        let herdr = SSHTerminalBarItem.action(.herdr).title(customKeys: [])
        let keyboard = SSHTerminalBarItem.action(.keyboard).title(customKeys: [])
        #expect(!summary.contains(rex), "the summary names Rex off: \(summary)")
        #expect(!summary.contains(herdr), "the summary names Herdr off: \(summary)")
        #expect(summary.contains(keyboard), "the summary keeps the buttons that are not experiments: \(summary)")
    }

    // MARK: - Rex on Your Tailnet

    /// A name typed by hand is saved and listed, and one that is not a Rex's
    /// Tailscale name is refused.
    @Test func aNameTypedIsSavedAndListed() throws {
        defer { hosts.removeSuites() }
        let page = try mountTailnet()
        defer { page.window.isHidden = true }
        #expect(page.identifiers.contains("settings.sshTerminal.rexTailnet.list"))
        #expect(page.identifiers.contains("settings.sshTerminal.rexTailnet.add"))
        #expect(!page.identifiers.contains("settings.sshTerminal.rexTailnet.rex.tail0000.ts.net"))

        #expect(page.page.addTailnetRex(named: "https://Rex.tail0000.ts.net/"))
        page.reload()
        #expect(page.identifiers.contains("settings.sshTerminal.rexTailnet.rex.tail0000.ts.net"))
        #expect(hosts.rexStore.tailnetHosts().map(\.dnsName) == ["rex.tail0000.ts.net"])

        #expect(!page.page.addTailnetRex(named: "rex.example.com"), "a name off the tailnet is refused")
    }

    /// A saved name can be swiped away: the swipe's own handler leaves the store
    /// empty and the row gone, and the Add row has no swipe.
    @Test func aSavedNameCanBeRemovedAndTheAddRowCannot() throws {
        defer { hosts.removeSuites() }
        let name = try #require(RexTailnetHost(dnsName: "rex.tail0000.ts.net"))
        hosts.rexStore.saveTailnetHost(name)
        let page = try mountTailnet()
        defer { page.window.isHidden = true }
        let row = "settings.sshTerminal.rexTailnet.\(name.dnsName)"
        #expect(page.identifiers.contains(row))
        #expect(page.page.trailingSwipeActions(for: .add) == nil)
        let swipe = try #require(page.page.trailingSwipeActions(for: .rex(name.dnsName)))
        #expect(swipe.actions.map(\.style) == [.destructive])

        // What that swipe runs: the store empties, and the list it draws is the Add
        // row alone. The list is read through its snapshot, because a collection view
        // can keep a removed cell in its hierarchy for a turn.
        page.page.remove(dnsName: name.dnsName)
        #expect(hosts.rexStore.tailnetHosts().isEmpty)
        page.reload()
        #expect(page.page.items(in: .names).isEmpty)
    }


    private func mountSettings(
        profileStore: (@Sendable () -> SSHTerminalProfileStore)? = nil,
        experiments: @escaping @MainActor () -> SSHTerminalExperimentAccess = { .all }
    ) throws -> MountedPage<SSHTerminalSettingsViewController> {
        try mountPage(
            SSHTerminalSettingsViewController(
                profileStore: profileStore ?? hosts.profileStore,
                rexStore: hosts.rexStore,
                reach: { .systemOnly },
                barStore: hosts.barStore,
                experiments: experiments
            )
        )
    }

    private func mountTailnet() throws -> MountedPage<SSHTerminalRexTailnetSettingsViewController> {
        try mountPage(SSHTerminalRexTailnetSettingsViewController(store: hosts.rexStore, reach: { .systemOnly }))
    }
}

// MARK: - Mounting

/// A page mounted in a window that has appeared: what it draws, by identifier.
/// File-scope, so both suites in this file mount the same way.
@MainActor
private struct MountedPage<Page: UIViewController> {
    let window: UIWindow
    let page: Page

    /// Every accessible identifier on screen, so a test asks what the page shows.
    var identifiers: [String] { Self.allIdentifiers(in: page.view) }

    func element(_ identifier: String) -> UIView? { Self.view(identifier, in: page.view) }

    /// Draws the page again, as a pass after a store change would.
    func reload() {
        page.setNeedsUpdateProperties()
        page.updatePropertiesIfNeeded()
        page.view.layoutIfNeeded()
    }

    private static func allIdentifiers(in view: UIView) -> [String] {
        (view.accessibilityIdentifier.map { [$0] } ?? [])
            + view.subviews.flatMap { allIdentifiers(in: $0) }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { view(identifier, in: $0) }.first
    }
}


@MainActor
private func mountPage<Page: UIViewController>(_ page: Page) throws -> MountedPage<Page> {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.traitOverrides.appRootEnvironment = makeTestAppRoot()
    window.rootViewController = RouterNavigationController(rootViewController: page)
    window.makeKeyAndVisible()
    page.beginAppearanceTransition(true, animated: false)
    page.endAppearanceTransition()
    page.setNeedsUpdateProperties()
    page.updatePropertiesIfNeeded()
    page.view.layoutIfNeeded()
    return MountedPage(window: window, page: page)
}

/// The Terminal page's host row: its ⋯ menu is the only way a host is edited or
/// deleted now that the row has no Edit button, and the menu asks before it
/// removes anything.
@Suite("Terminal host row actions", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalHostRowActionTests {
    private let hosts: IsolatedStores
    private let plain = SSHTerminalProfile(host: "devbox.local", port: 2222, username: "dev", authentication: .deviceKey)
    private let other = SSHTerminalProfile(host: "mac-studio.local", username: "chen", startupCommand: "herdr")

    init() throws {
        hosts = try IsolatedStores()
    }

    /// **Delete Host** in the row's ⋯ asks first, and the sheet's own button removes
    /// the host and its row: the two steps are the same owner actions a touch takes.
    @Test func theMenuAsksToDeleteAndTheSheetsButtonRemovesTheHost() async throws {
        defer { hosts.removeSuites() }
        try hosts.save([plain, other])
        let tab = try mountPage(SSHTerminalHostListViewController(
            profileStore: hosts.profileStore,
            tailnetRex: RexTailnetSection(
                store: hosts.rexStore,
                discovery: RexTailnetDiscovery { _ in .unreachable },
                reach: { .none }
            ),
            startsTailnet: {}
        ))
        defer { tab.window.isHidden = true }

        // What the row's ⋯ **Delete Host** item runs: it asks, and nothing is removed
        // before the sheet's button runs.
        tab.page.confirmDelete(plain)
        let sheet = try #require(tab.page.presentedViewController as? UIAlertController, "Delete Host must ask first")
        #expect(sheet.actions.contains { $0.accessibilityIdentifier == "sshTerminal.host.delete.confirm" })
        #expect(hosts.profileStore().profile(id: plain.id) != nil)
        sheet.dismiss(animated: false)

        // What that button runs.
        tab.page.deleteHost(plain)
        #expect(hosts.profileStore().profile(id: plain.id) == nil)
        #expect(hosts.profileStore().profile(id: other.id) != nil, "the other host stays")
        // The list's own rows follow: one host left, and it is the other one.
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            tab.reload()
            return itemCount(in: tab.page) == 1
        })
        #expect(tab.identifiers.contains("sshTerminal.host.row.\(other.id.uuidString)"))
    }

    /// How many rows the page's list shows now: the diffable data source's count,
    /// not the cells in the view tree (a removed cell can stay a turn).
    private func itemCount(in page: UIViewController) -> Int {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let collection = find(page.view) else { return -1 }
        return (0..<collection.numberOfSections).reduce(0) { total, section in
            total + collection.numberOfItems(inSection: section)
        }
    }
}

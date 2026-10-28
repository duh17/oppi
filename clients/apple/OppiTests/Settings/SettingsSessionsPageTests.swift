import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Sessions over the real page, a real `SettingsStore`, and a fake
/// server route: what a person sees and what each control writes.
@Suite("Settings Sessions page", .serialized)
@MainActor
struct SettingsSessionsPageTests {
    private let serverId = "sessions-page-server"

    private struct Harness {
        var page: SettingsSessionsViewController
        var transport: FakeSettingsTransport
        var defaults: UserDefaults
        var window: UIWindow
    }

    private func makeHarness(
        fields: [String: JSONValue] = ["enabled": true, "model": "anthropic/claude-haiku-5"],
        revision: Int? = 4,
        size: UIContentSizeCategory = .large
    ) throws -> Harness {
        let transport = FakeSettingsTransport(fields: fields, revision: revision)
        let defaults = makeSettingsDefaults()
        let store = SettingsStore(
            device: DeviceAdapter(defaults: defaults),
            server: ServerAdapter { _ in transport },
            serverName: { _ in "Ready" }
        )
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: SessionsPageURLProtocol.makeClient(), settings: store)
        let page = SettingsSessionsViewController(root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        window.rootViewController = page
        window.makeKeyAndVisible()
        page.traitOverrides.preferredContentSizeCategory = size
        return Harness(page: page, transport: transport, defaults: defaults, window: window)
    }

    private func hide(_ harness: Harness) {
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    private typealias Item = SettingsSessionsViewController.Item

    private func cell(_ item: Item, in page: SettingsSessionsViewController) -> UICollectionViewCell? {
        page.view.layoutIfNeeded()
        return page.dataSource?.indexPath(for: item).flatMap { page.collectionView.cellForItem(at: $0) }
    }

    private func button(_ item: Item, in page: SettingsSessionsViewController) -> UIButton? {
        cell(item, in: page)?.accessibilityElements?.first as? UIButton
    }

    /// Every switch drawn in the server toggle's cell: what a person sees, not the cell's model.
    private func drawnSwitches(in page: SettingsSessionsViewController) -> [UISwitch] {
        cell(.serverEnabled, in: page).map(Self.switches) ?? []
    }

    /// The switch on screen, once the cell draws exactly one.
    private func toggle(in page: SettingsSessionsViewController) -> UISwitch? {
        let drawn = drawnSwitches(in: page)
        return drawn.count == 1 ? drawn.first : nil
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        let own = (view as? UISwitch).map { [$0] } ?? []
        return own + view.subviews.flatMap(switches)
    }

    /// The titles of every action in a button's menu, groups flattened.
    private func menuActions(of button: UIButton) -> [UIAction] {
        func flatten(_ elements: [UIMenuElement]) -> [UIAction] {
            elements.flatMap { element -> [UIAction] in
                if let menu = element as? UIMenu { return flatten(menu.children) }
                return (element as? UIAction).map { [$0] } ?? []
            }
        }
        return flatten(button.menu?.children ?? [])
    }

    private func ready(_ page: SettingsSessionsViewController, _ item: Item) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) { cell(item, in: page) != nil }
    }

    private func footers(_ page: SettingsSessionsViewController) -> [String] {
        let kind = UICollectionView.elementKindSectionFooter
        return page.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind)
            .sorted { $0.section < $1.section }
            .compactMap { indexPath in
                let view = page.collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
                return (view?.contentConfiguration as? UIListContentConfiguration)?.text
            }
    }

    // MARK: - Behavior

    @Test("Choosing On-device or Off on this device saves on this device and never writes the server's flag")
    func providerChoiceNeverTouchesTheServer() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await ready(h.page, .provider))
        // The server section has loaded too, so a stray write would have a document to change.
        #expect(await waitForMainActorCondition { h.transport.loads >= 1 })

        for (title, stored) in [("On-device", "onDevice"), ("Off", "off")] {
            let provider = try #require(button(.provider, in: h.page))
            let action = try #require(menuActions(of: provider).first { $0.title == title })
            action.performWithSender(nil, target: nil)
            #expect(h.defaults.string(forKey: AppPreferenceStore.Session.autoTitleProviderKey) == stored)
        }
        #expect(h.transport.saves.isEmpty, "a device choice wrote to the server: \(h.transport.saves)")
    }

    @Test("Each section says where its settings are kept")
    func sectionsSayWhereTheyAreKept() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await ready(h.page, .serverEnabled))
        #expect(await waitForMainActorCondition { footers(h.page).count == 3 })

        let texts = footers(h.page)
        #expect(texts[0].hasPrefix("Saved on this device."))
        #expect(texts[1].hasPrefix("Applies to every device on Ready."))
        #expect(texts[2] == "Choose the details shown on session rows in every session list.")
    }

    @Test("A failed server save goes back to the old value, says why under the row, and Retry saves it")
    func failedSaveShowsReasonAndRetries() async throws {
        let h = try makeHarness(fields: ["enabled": false, "model": "anthropic/claude-haiku-5"])
        defer { hide(h) }
        #expect(await waitForMainActorCondition { toggle(in: h.page)?.isEnabled == true })
        let control = try #require(toggle(in: h.page))
        #expect(!control.isOn)

        h.transport.failNextSave(with: SettingsTestError())
        control.isOn = true
        control.sendActions(for: .valueChanged)

        #expect(await ready(h.page, .failure(SettingsCatalog.autoNameServerEnabled.id)))
        let failure = try #require(button(.failure(SettingsCatalog.autoNameServerEnabled.id), in: h.page))
        #expect(failure.accessibilityIdentifier == "\(SettingsCatalog.autoNameServerEnabled.id).failure")
        #expect(failure.accessibilityLabel == "The server said no.")
        #expect(
            await waitForMainActorCondition { toggle(in: h.page)?.isOn == false },
            "the drawn switch should be one switch, rolled back; the cell draws \(drawnSwitches(in: h.page).map(\.isOn))"
        )

        // It stays one switch, back where it was: no replaced switch lingers beside it.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            let drawn = drawnSwitches(in: h.page)
            return drawn.count == 1 && drawn.first?.isOn == false
        }, "the cell draws \(drawnSwitches(in: h.page).map(\.isOn))")

        failure.sendActions(for: .touchUpInside)
        // The second write lands, and the redrawn switch shows the saved value with no failure under it.
        #expect(await waitForMainActorCondition {
            h.transport.saves.count == 2 && toggle(in: h.page)?.isOn == true
                && cell(.failure(SettingsCatalog.autoNameServerEnabled.id), in: h.page) == nil
        })
        #expect(h.transport.saves.map(\.fields) == [["enabled": true], ["enabled": true]])
    }

    @Test("The Model menu offers the server's compatible models by provider and keeps the stored one")
    func modelMenuListsModels() async throws {
        let h = try makeHarness(fields: ["enabled": true, "model": "retired/model"])
        defer { hide(h) }
        #expect(await ready(h.page, .serverModel))
        #expect(await waitForMainActorCondition { (button(.serverModel, in: h.page).map(menuActions)?.count ?? 0) > 1 })
        let model = try #require(button(.serverModel, in: h.page))
        // A model the server no longer lists is still shown and checked.
        let titles = menuActions(of: model).map(\.title)
        #expect(titles.contains("retired/model"))
        #expect(titles.contains("Claude Haiku 5"))
        #expect(menuActions(of: model).first { $0.title == "retired/model" }?.state == .on)

        try #require(menuActions(of: model).first { $0.title == "GPT-5 mini" }).performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition { !h.transport.saves.isEmpty })
        #expect(h.transport.saves.first?.fields == ["model": "openai/gpt-5-mini"])
    }

    // MARK: - Largest text size

    @Test("At the largest accessibility text size every row grows and none of its text is cut off")
    func rowsGrowAtAccessibilityXXXL() async throws {
        let h = try makeHarness(fields: ["enabled": true, "model": "anthropic/claude-haiku-5"])
        defer { hide(h) }
        // A failure line under the toggle, so every row type the page has is on screen.
        #expect(await waitForMainActorCondition { toggle(in: h.page)?.isEnabled == true })
        let control = try #require(toggle(in: h.page))
        h.transport.failNextSave(with: SettingsTestError())
        control.isOn = false
        control.sendActions(for: .valueChanged)
        let failureItem = Item.failure(SettingsCatalog.autoNameServerEnabled.id)
        #expect(await ready(h.page, failureItem))
        #expect(await waitForMainActorCondition { cell(.serverModel, in: h.page) != nil && cell(.sessionRows, in: h.page) != nil })

        let items: [Item] = [.provider, .serverEnabled, failureItem, .serverModel, .sessionRows]
        func heights() -> [CGFloat] { items.map { cell($0, in: h.page)?.bounds.height ?? 0 } }
        let before = heights()
        #expect(before.allSatisfy { $0 > 0 })

        h.page.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            let now = heights()
            return zip(now, before).allSatisfy { $0 > $1 }
        }, "rows did not all grow: \(before) -> \(heights())")

        for item in items {
            let row = try #require(cell(item, in: h.page), "\(item) has no cell")
            var checked = 0
            for label in Self.labels(in: row) where !(label.text ?? "").isEmpty && !label.isHidden && label.bounds.width > 0 {
                checked += 1
                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                #expect(needed.height <= label.bounds.height + 1, "\(item): \"\(label.text ?? "")\" is clipped")
                if label.numberOfLines == 1 {
                    #expect(label.intrinsicContentSize.width <= label.bounds.width + 1, "\(item): \"\(label.text ?? "")\" is truncated")
                }
            }
            // A switch row draws its title in a list content configuration, not a label.
            #expect(checked > 0 || item == .serverEnabled, "\(item): no text was checked")
        }
    }

    private static func labels(in view: UIView) -> [UILabel] {
        let own = (view as? UILabel).map { [$0] } ?? []
        return own + view.subviews.flatMap(labels)
    }
}

/// Answers `GET /models` with three models over two providers.
private final class SessionsPageURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "sessions-page.test"

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionsPageURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"), token: "test-token", configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let models = #"{"models":[{"id":"claude-haiku-5","name":"Claude Haiku 5","provider":"anthropic","contextWindow":200000},{"id":"gpt-5-mini","name":"GPT-5 mini","provider":"openai","contextWindow":400000},{"id":"gpt-5.3-codex","name":"Codex","provider":"openai-codex","contextWindow":400000}]}"#
        let isModels = request.url?.path.hasSuffix("/models") == true
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: isModels ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(isModels ? models.utf8 : #"{"error":"not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

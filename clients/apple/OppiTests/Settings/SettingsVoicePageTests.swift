import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Voice & Dictation over the real page: the Dictation Dictionary row
/// is disabled with its reason while no server is paired and names the server
/// once one is; the three choices write their preferences.
@Suite("Settings Voice page", .serialized)
@MainActor
struct SettingsVoicePageTests {
    private struct Harness {
        let page: SettingsVoiceViewController
        let window: UIWindow
        let restore: () -> Void
    }

    private func makeHarness(withServer: Bool) throws -> Harness {
        let replyMode = AppPreferences.Voice.replyMode
        let engine = AppPreferences.Voice.engineMode
        let style = AppPreferences.Appearance.dictationIndicatorStyle
        let serverStore = ServerStore()
        let credentials = ServerCredentials(
            host: "mac-studio.test", port: 7749, token: "sk_test", name: "mac-studio", serverFingerprint: "sha256:voice-test"
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        if withServer { serverStore.replaceServersForPreview([server]) }
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        if withServer { #expect(coordinator.restoreActiveServer(server.id)) }
        let page = SettingsVoiceViewController(root: makeTestAppRoot(coordinator: coordinator))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1000)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return Harness(page: page, window: window) {
            AppPreferences.Voice.setReplyMode(replyMode)
            AppPreferences.Voice.setEngineMode(engine)
            AppPreferences.Appearance.setDictationIndicatorStyle(style)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func button(_ item: SettingsVoiceViewController.Item, in page: SettingsVoiceViewController) -> UIButton? {
        page.view.layoutIfNeeded()
        return page.indexPath(for: item)
            .flatMap { page.collectionView.cellForItem(at: $0) }?
            .accessibilityElements?.first as? UIButton
    }

    private func footers(_ page: SettingsVoiceViewController) -> [String] {
        let kind = UICollectionView.elementKindSectionFooter
        return page.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind)
            .sorted { $0.section < $1.section }
            .compactMap { indexPath in
                (page.collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell)
                    .flatMap { ($0.contentConfiguration as? UIListContentConfiguration)?.text }
            }
    }

    @Test("With no server paired the Dictation Dictionary row cannot open and says why")
    func dictionaryRowIsDisabledWithoutAServer() async throws {
        let h = try makeHarness(withServer: false)
        defer { h.restore() }
        #expect(await waitForMainActorCondition { button(.dictionary, in: h.page) != nil && footers(h.page).count == 3 })
        let row = try #require(button(.dictionary, in: h.page))
        #expect(row.accessibilityIdentifier == "settings.dictationDictionary")
        #expect(!row.isEnabled)
        #expect(row.accessibilityTraits.contains(.notEnabled))
        #expect(row.accessibilityValue == "No server paired")
        #expect(footers(h.page)[2].contains("Pair a server"))
    }

    @Test("With a server the row opens, and its footer names the server whose list it is")
    func dictionaryRowNamesTheServer() async throws {
        let h = try makeHarness(withServer: true)
        defer { h.restore() }
        #expect(await waitForMainActorCondition { button(.dictionary, in: h.page) != nil && footers(h.page).count == 3 })
        let row = try #require(button(.dictionary, in: h.page))
        #expect(row.isEnabled)
        #expect(footers(h.page)[2].hasPrefix("Applies to every device on mac-studio."))
    }

    @Test("Each choice writes its preference with the id it has always had")
    func choicesWritePreferences() async throws {
        let h = try makeHarness(withServer: false)
        defer { h.restore() }
        AppPreferences.Voice.setEngineMode(.onDevice)
        AppPreferences.Voice.setReplyMode(.manual)
        AppPreferences.Appearance.setDictationIndicatorStyle(.ring)
        #expect(await waitForMainActorCondition { button(.engine, in: h.page) != nil && button(.animation, in: h.page) != nil })

        func choose(_ item: SettingsVoiceViewController.Item, _ title: String) throws {
            let row = try #require(button(item, in: h.page))
            try #require(row.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == title })
                .performWithSender(nil, target: nil)
        }
        try choose(.engine, "Server")
        #expect(AppPreferences.Voice.engineMode == .remote)
        try choose(.replies, "Agent decides")
        #expect(AppPreferences.Voice.replyMode == .autoplay)
        let other = try #require(DictationIndicatorStyle.allCases.first { $0 != .ring })
        try choose(.animation, other.displayName)
        #expect(AppPreferences.Appearance.dictationIndicatorStyle == other)
        #expect(button(.animation, in: h.page)?.accessibilityIdentifier == "settings.dictationIndicatorStyle")
    }

    @Test("The footers follow the engine and the reply mode")
    func footersFollowTheChoices() {
        #expect(SettingsVoiceViewController.dictationFooter(engine: .remote).contains("configured on your paired server"))
        #expect(SettingsVoiceViewController.dictationFooter(engine: .onDevice).contains("Apple's local dictation"))
        #expect(SettingsVoiceViewController.dictationFooter(engine: .onDevice).contains("does not use the microphone"))
    }
}

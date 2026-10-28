import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Dictation Dictionary page over a fake server: a row acts on the phrase it
/// shows even after a rename or delete above it, and only a notice about the
/// server offers Retry.
@Suite("Dictation Dictionary page", .serialized)
@MainActor
struct DictationDictionaryPageTests {
    private final class Server: DictationDictionaryService, @unchecked Sendable {
        struct Offline: Error {}
        var global = DictationDictionaryList(revision: 1, phrases: ["Oppi", "Tailscale", "Herdr"], provider: nil)
        var failWrites = false
        func dictationDictionary(workspaceId: String?) async throws -> DictationDictionaryList { global }
        func saveDictationDictionary(workspaceId: String?, revision: Int, phrases: [String]) async throws -> DictationDictionaryList {
            if failWrites { throw Offline() }
            return global
        }
    }

    private typealias Item = DictationDictionaryViewController.Item

    private func mount(_ model: DictationDictionaryModel) throws -> (page: DictationDictionaryViewController, window: UIWindow) {
        let page = DictationDictionaryViewController(model: model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return (page, window)
    }

    private func button(_ item: Item, in page: DictationDictionaryViewController) -> UIButton? {
        page.view.layoutIfNeeded()
        return page.dataSource?.indexPath(for: item)
            .flatMap { page.collectionView.cellForItem(at: $0) }?
            .accessibilityElements?.first as? UIButton
    }

    /// The page loads the lists when it appears; edits made before that load ends are replaced by it.
    private func mountLoaded(_ model: DictationDictionaryModel) async throws -> (page: DictationDictionaryViewController, window: UIWindow) {
        let mounted = try mount(model)
        #expect(await waitForMainActorCondition { model.loadState == .loaded })
        return mounted
    }

    private func model(_ server: Server) -> DictationDictionaryModel {
        DictationDictionaryModel(serverId: "s1", serverName: "mac-studio", service: server)
    }

    @Test("After a rename above, tapping a row edits the phrase it shows, and its id follows its place")
    func tapAfterRenameAboveEditsTheTappedPhrase() async throws {
        let model = model(Server())
        let (page, window) = try await mountLoaded(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        let herdr = Item.phrase(.global, "Herdr", occurrence: 0)
        #expect(await waitForMainActorCondition { button(herdr, in: page) != nil })
        #expect(button(herdr, in: page)?.accessibilityIdentifier == "settings.dictionary.phrase.global.2")

        // Oppi becomes Oppi 2 and moves to the end: Tailscale and Herdr each move up one.
        model.beginEditing(workspaceScope: false, index: 0)
        model.phrase = "Oppi 2"
        model.addPhrase()
        #expect(model.globalDraft == ["Tailscale", "Herdr", "Oppi 2"])

        #expect(await waitForMainActorCondition { button(herdr, in: page)?.accessibilityIdentifier == "settings.dictionary.phrase.global.1" })
        try #require(button(herdr, in: page)).sendActions(for: .touchUpInside)
        #expect(model.editing == .init(workspace: false, index: 1, phrase: "Herdr"))
        #expect(model.phrase == "Herdr")

        // Renaming that row replaces Herdr, not the row that used to be at its old place.
        model.phrase = "Herdr 2"
        model.addPhrase()
        #expect(model.globalDraft == ["Tailscale", "Oppi 2", "Herdr 2"])
    }

    @Test("A notice about the draft has nothing to press; one about the server retries the load")
    func onlyServerNoticesOfferRetry() async throws {
        let model = model(Server())
        let (page, window) = try await mountLoaded(model)
        defer { window.isHidden = true; window.rootViewController = nil }

        // A duplicate phrase is the person's to fix.
        model.beginAdding()
        model.phrase = "Oppi"
        model.addPhrase()
        #expect(await waitForMainActorCondition { button(.notice, in: page) != nil })
        let notice = try #require(button(.notice, in: page))
        #expect(!notice.isUserInteractionEnabled, "Retry would reload the lists and discard the draft")
        #expect(model.globalDraft == ["Oppi", "Tailscale", "Herdr"])
    }

    @Test("A save the server refuses leaves a notice whose Retry reloads the lists")
    func serverNoticeRetriesTheLoad() async throws {
        let server = Server()
        server.failWrites = true
        let model = model(server)
        let (page, window) = try await mountLoaded(model)
        defer { window.isHidden = true; window.rootViewController = nil }
        model.beginAdding()
        model.phrase = "Ghostty"
        model.addPhrase()
        await model.save()
        #expect(await waitForMainActorCondition { button(.notice, in: page) != nil })
        let notice = try #require(button(.notice, in: page))
        #expect(notice.isUserInteractionEnabled)
        notice.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition { model.loadState == .loaded && model.notice == nil && !model.hasChanges })
        #expect(model.globalDraft == ["Oppi", "Tailscale", "Herdr"], "Retry reloads the server's lists and drops the draft")
    }
}

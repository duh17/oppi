import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Icon picker screen")
struct IconPickerViewControllerTests {
    /// Picks a symbol; a failed save keeps the choice and says why, and Retry
    /// commits the same icon and closes the picker.
    @Test("a failed save keeps the choice and Retry commits it")
    func failedSaveKeepsTheChoice() async throws {
        let committed = Committed()
        let harness = try Harness(commit: { icon in
            await committed.record(icon)
            if await committed.count == 1 { throw StubError.offline }
        })
        defer { harness.hide() }

        let symbol = try await harness.symbolButton("folder")
        #expect(symbol.accessibilityValue == "Not selected")
        #expect(!harness.save.isEnabled, "nothing changed yet")
        symbol.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition { harness.save.isEnabled })
        #expect(harness.button("agent.iconPicker.symbol.folder")?.accessibilityValue == "Selected")

        harness.tapSave()
        let error = try await harness.waitForButton("agent.iconPicker.saveError")
        #expect(error.accessibilityLabel?.contains("Save error: Couldn’t save. offline") == true)
        #expect(harness.save.isEnabled, "the choice is kept so the save can be retried")
        #expect(harness.button("agent.iconPicker.symbol.folder")?.accessibilityValue == "Selected")
        #expect(harness.presented.presentedViewController != nil)

        error.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            harness.presented.presentedViewController == nil
        }, "a saved icon closes the picker")
        #expect(await committed.icons == [.symbol("folder"), .symbol("folder")])
    }

    @Test("the search field narrows the grid and says when nothing matches")
    func searchNarrowsTheGrid() async throws {
        let harness = try Harness(commit: { _ in })
        defer { harness.hide() }
        _ = try await harness.symbolButton("folder")
        let allSymbols = harness.symbolIdentifiers().count
        #expect(allSymbols > 10)

        let field = try #require(harness.searchField())
        field.text = "branch"
        field.sendActions(for: .editingChanged)
        #expect(await waitForMainActorCondition {
            harness.view.layoutIfNeeded()
            let shown = harness.symbolIdentifiers()
            return shown.contains("agent.iconPicker.symbol.arrow.triangle.branch") && shown.count < allSymbols
        })

        field.text = "no-such-icon"
        field.sendActions(for: .editingChanged)
        #expect(await waitForMainActorCondition {
            harness.view.layoutIfNeeded()
            return harness.symbolIdentifiers().isEmpty
                && harness.view.containsLabel("No results for \u{201C}no-such-icon\u{201D}")
        })
    }

    @Test("a custom emoji choice shows in the chooser and saves as an emoji icon")
    func savedEmojiIsShownInTheChooser() async throws {
        let committed = Committed()
        let harness = try Harness(saved: .emoji("🦊"), commit: { await committed.record($0) })
        defer { harness.hide() }
        let chooser = try await harness.waitForButton("agent.iconPicker.emojiGenmoji")
        #expect(chooser.accessibilityValue == "Emoji 🦊")
        #expect(!harness.save.isEnabled, "the saved icon is not a change")
    }

    /// One picker for every owner: a workspace's icon offers the same image
    /// import and symbol Animation as an Agent's.
    @Test("every owner's picker offers image import and a symbol's Animation", arguments: [
        IconPickerPurpose.agent, .workspace,
    ])
    func sameSectionsForEveryOwner(purpose: IconPickerPurpose) async throws {
        let harness = try Harness(purpose: purpose, saved: .symbol("folder", effect: .bounce), commit: { _ in })
        defer { harness.hide() }
        let prefix = purpose.accessibilityPrefix
        let animation = try await harness.waitForButton("\(prefix).symbolEffect")
        #expect(animation.accessibilityValue == "Bounce")
        _ = try await harness.waitForButton("\(prefix).importPhotos")
        _ = try await harness.waitForButton("\(prefix).importFiles")
        _ = try await harness.waitForButton("\(prefix).emojiGenmoji")
        #expect(try await harness.symbolButton("folder").accessibilityValue == "Selected")
    }
}

private enum StubError: LocalizedError {
    case offline

    var errorDescription: String? { "offline" }
}

private actor Committed {
    private(set) var icons: [IconChoice] = []
    var count: Int { icons.count }

    func record(_ icon: IconChoice) { icons.append(icon) }
}

/// The picker presented over a plain screen, as the router presents it, in a
/// window tall enough to lay out the first symbols.
@MainActor
private final class Harness {
    let window: UIWindow
    let presented: UIViewController
    let picker: IconPickerViewController
    let prefix: String

    var view: UIView { picker.view }
    var save: UIBarButtonItem { picker.navigationItem.rightBarButtonItem ?? UIBarButtonItem() }

    init(
        purpose: IconPickerPurpose = .agent,
        saved: IconChoice = .defaultValue,
        commit: @escaping (IconChoice) async throws -> Void
    ) throws {
        prefix = purpose.accessibilityPrefix
        picker = IconPickerViewController(source: .init(
            purpose: purpose,
            savedValue: saved,
            assetCache: nil,
            uploadAsset: { _, _ in throw StubError.offline },
            commit: commit
        ))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1600)
        presented = UIViewController()
        window.rootViewController = presented
        window.makeKeyAndVisible()
        presented.present(RouterNavigationController(rootViewController: picker), animated: false)
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func tapSave() {
        save.primaryAction?.performWithSender(save, target: nil)
    }

    func symbolButton(_ name: String) async throws -> UIButton {
        try await waitForButton("\(prefix).symbol.\(name)")
    }

    func waitForButton(_ identifier: String) async throws -> UIButton {
        var found: UIButton?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            view.layoutIfNeeded()
            found = button(identifier)
            return found != nil
        }
        return try #require(found, "no button \(identifier)")
    }

    /// The button of a row the list shows now; a pooled cell is not one.
    func button(_ identifier: String) -> UIButton? {
        guard let list = collectionView() else { return nil }
        return list.visibleCells.lazy.compactMap { $0.firstButton(identifier) }.first
    }

    func symbolIdentifiers() -> [String] {
        guard let list = collectionView() else { return [] }
        let symbolPrefix = "\(prefix).symbol."
        return list.visibleCells.compactMap { cell in
            cell.allButtons().first { $0.accessibilityIdentifier?.hasPrefix(symbolPrefix) == true }?.accessibilityIdentifier
        }
    }

    func searchField() -> UITextField? {
        let identifier = "\(prefix).symbolSearch"
        return collectionView()?.visibleCells.lazy.compactMap { $0.firstField(identifier) }.first
    }

    private func collectionView() -> UICollectionView? {
        view.firstSubview(of: UICollectionView.self)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstSubview(of: type) { return found }
        }
        return nil
    }

    func allButtons() -> [UIButton] {
        var found = (self as? UIButton).map { [$0] } ?? []
        for subview in subviews { found += subview.allButtons() }
        return found
    }

    func firstButton(_ identifier: String) -> UIButton? {
        allButtons().first { $0.accessibilityIdentifier == identifier }
    }

    func firstField(_ identifier: String) -> UITextField? {
        if let field = self as? UITextField, field.accessibilityIdentifier == identifier { return field }
        for subview in subviews {
            if let found = subview.firstField(identifier) { return found }
        }
        return nil
    }

    func containsLabel(_ text: String) -> Bool {
        if (self as? UILabel)?.text == text { return true }
        return subviews.contains { $0.containsLabel(text) }
    }
}

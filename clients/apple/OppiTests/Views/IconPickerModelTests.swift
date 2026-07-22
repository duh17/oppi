import Foundation
import Testing
@testable import Oppi

@Suite("Unified icon picker model")
@MainActor
struct IconPickerModelTests {
    private struct InjectedFailure: LocalizedError {
        let errorDescription: String?
    }

    @Test("the standard cart symbol is available to the runtime picker")
    func cartSymbolIsAvailable() {
        #expect(IconSymbolCatalog.isAvailable("cart"))
    }

    @Test("catalog search exposes only matching symbols available on this device")
    func catalogSearchExposesAvailableCart() {
        let available = IconSymbolCatalog.availableOptions(
            matching: "cart",
            isAvailable: { $0 == "cart" }
        )
        let unavailable = IconSymbolCatalog.availableOptions(
            matching: "cart",
            isAvailable: { _ in false }
        )

        #expect(available == [.init(symbolName: "cart", label: "Shop")])
        #expect(unavailable.isEmpty)
    }

    @Test("purpose allows only its supported media")
    func allowedMediaByPurpose() {
        #expect(IconPickerPurpose.assistant.allowedMedia == [.emoji, .genmoji])
        #expect(IconPickerPurpose.agent.allowedMedia == [.emoji, .genmoji, .symbol])
        #expect(IconPickerPurpose.workspace.allowedMedia == [.emoji, .genmoji, .symbol])
    }

    @Test("draft transitions do not mutate the committed value")
    func draftTransitionsDoNotCommit() {
        let model = IconPickerModel(
            purpose: .workspace,
            savedValue: IconChoice.emoji("🧠"),
            defaultValue: .defaultValue
        )

        model.selectValue(.symbol("folder"))
        #expect(model.savedValue == .emoji("🧠"))
        #expect(model.draft == .value(.symbol("folder")))

        model.selectDefault()
        #expect(model.savedValue == .emoji("🧠"))
        #expect(model.draft == .value(.defaultValue))
    }

    @Test("emoji input requires exactly one valid Unicode emoji sequence", arguments: [
        ("👨‍👩‍👧‍👦", true),
        ("👋🏽", true),
        ("🇺🇸", true),
        ("1️⃣", true),
        ("🧠🦊", false),
        ("A", false),
        ("", false),
    ])
    func emojiValidation(example: (String, Bool)) {
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: IconChoice.defaultValue,
            defaultValue: .defaultValue
        )

        let accepted = model.selectEmoji(example.0, transform: IconChoice.emoji)

        #expect(accepted == example.1)
        if example.1 {
            #expect(model.draft == .value(.emoji(example.0)))
            #expect(model.validationMessage == nil)
        } else {
            #expect(model.draft == .value(.defaultValue))
            #expect(model.validationMessage != nil)
        }
    }

    @Test("custom input tracks an explicit selected emoji and clears for built-in choices")
    func customEmojiSelectionAndInputSynchronization() {
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: IconChoice.emoji("🧠"),
            defaultValue: .defaultValue,
            customChoice: Self.customChoice
        )

        #expect(model.selectedCustomChoice == .emoji("🧠"))
        #expect(model.customInputText == "🧠")

        #expect(model.selectEmoji("🧘", transform: IconChoice.emoji))
        #expect(model.selectedCustomChoice == .emoji("🧘"))
        #expect(model.customInputText == "🧘")

        model.selectValue(.symbol("folder"))
        #expect(model.selectedCustomChoice == nil)
        #expect(model.customInputText.isEmpty)

        model.selectDefault()
        #expect(model.selectedCustomChoice == nil)
        #expect(model.customInputText.isEmpty)
    }

    @Test("Genmoji remains an explicit selected custom choice without raw text")
    func genmojiSelectionHasDescriptionButNoRawText() {
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: .defaultValue,
            defaultValue: .defaultValue,
            customChoice: Self.customChoice
        )

        model.selectGenmoji(data: Data([1, 2, 3]), contentDescription: "A smiling fox")

        #expect(model.selectedCustomChoice == .genmoji("A smiling fox"))
        #expect(model.customInputText.isEmpty)
    }

    @Test("invalid custom input clears its selected state and blocks Save")
    func invalidCustomInputBlocksSaveWithoutStaleSelection() {
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: IconChoice.emoji("🧠"),
            defaultValue: .defaultValue,
            customChoice: Self.customChoice
        )

        #expect(!model.selectEmoji("not emoji", transform: IconChoice.emoji))
        #expect(model.selectedCustomChoice == nil)
        #expect(model.customInputText == "not emoji")
        #expect(model.validationMessage == "Enter exactly one Unicode emoji.")
        #expect(!model.canSave)
    }

    @Test("an existing Genmoji remains selected until explicit replacement")
    func existingGenmojiIsPreserved() {
        let existing = IconChoice.genmoji(
            assetId: "ia_" + String(repeating: "A", count: 43),
            contentDescription: "A smiling fox"
        )
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: existing,
            defaultValue: .defaultValue
        )

        #expect(model.savedValue == existing)
        #expect(model.draft == .value(existing))
        #expect(!model.hasChanges)

        model.selectDefault()
        #expect(model.savedValue == existing)
        #expect(model.draft == .value(.defaultValue))
        #expect(model.hasChanges)
    }

    @Test("failed Genmoji upload retains the draft and permits retry")
    func failedGenmojiUploadRetainsDraft() async {
        let model = IconPickerModel(
            purpose: .workspace,
            savedValue: IconChoice.defaultValue,
            defaultValue: .defaultValue
        )
        let data = Data([1, 2, 3])
        model.selectGenmoji(data: data, contentDescription: "Blue bird")
        var commitCount = 0

        let saved = await model.save(
            prepareGenmoji: { _, _ in
                throw InjectedFailure(errorDescription: "upload unavailable")
            },
            commit: { _ in commitCount += 1 }
        )

        #expect(!saved)
        #expect(commitCount == 0)
        #expect(model.draft == .genmoji(data: data, contentDescription: "Blue bird"))
        #expect(model.errorMessage?.contains("upload unavailable") == true)
        #expect(model.canSave)
    }

    @Test("failed persistence retains the prepared value and retries without another upload")
    func failedSaveRetainsPreparedGenmoji() async {
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: IconChoice.defaultValue,
            defaultValue: .defaultValue
        )
        let data = Data([4, 5, 6])
        let uploaded = IconChoice.genmoji(
            assetId: "ia_" + String(repeating: "B", count: 43),
            contentDescription: "Orange cat"
        )
        model.selectGenmoji(data: data, contentDescription: "Orange cat")
        var uploadCount = 0
        var commitCount = 0

        let firstSave = await model.save(
            prepareGenmoji: { _, _ in
                uploadCount += 1
                return uploaded
            },
            commit: { _ in
                commitCount += 1
                throw InjectedFailure(errorDescription: "save unavailable")
            }
        )

        #expect(!firstSave)
        #expect(uploadCount == 1)
        #expect(commitCount == 1)
        #expect(model.draft == .value(uploaded))
        #expect(model.savedValue == .defaultValue)

        let retry = await model.save(
            prepareGenmoji: { _, _ in
                uploadCount += 1
                return uploaded
            },
            commit: { value in
                commitCount += 1
                #expect(value == uploaded)
            }
        )

        #expect(retry)
        #expect(uploadCount == 1)
        #expect(commitCount == 2)
        #expect(model.savedValue == uploaded)
        #expect(!model.hasChanges)
    }

    @Test("symbol availability is rechecked before commit")
    func unavailableSymbolNeverCommits() async {
        var isAvailable = true
        let model = IconPickerModel(
            purpose: .agent,
            savedValue: IconChoice.defaultValue,
            defaultValue: .defaultValue,
            valueValidation: { value in
                guard case .symbol(let name) = value, !isAvailable else { return nil }
                return "The SF Symbol \(name) is unavailable on this device."
            }
        )
        model.selectValue(.symbol("cart"))
        isAvailable = false
        var commitCount = 0

        let saved = await model.save(
            prepareGenmoji: { _, _ in .defaultValue },
            commit: { _ in commitCount += 1 }
        )

        #expect(!saved)
        #expect(commitCount == 0)
        #expect(model.savedValue == .defaultValue)
        #expect(model.draft == .value(.symbol("cart")))
        #expect(model.validationMessage?.contains("unavailable") == true)
    }

    @Test("workspace save failure preserves the selected draft for retry")
    func workspaceSaveFailurePreservesDraft() async {
        let model = IconPickerModel(
            purpose: .workspace,
            savedValue: IconChoice.defaultValue,
            defaultValue: .defaultValue,
            customChoice: Self.customChoice
        )
        model.selectValue(.symbol("folder"))

        let saved = await model.save(
            prepareGenmoji: { _, _ in .defaultValue },
            commit: { _ in throw InjectedFailure(errorDescription: "workspace update unavailable") }
        )

        #expect(!saved)
        #expect(model.savedValue == .defaultValue)
        #expect(model.draft == .value(.symbol("folder")))
        #expect(model.errorMessage?.contains("workspace update unavailable") == true)
        #expect(model.canSave)
    }

    @Test("Default commits only through Save and exactly once")
    func defaultCommitsExactlyOnce() async {
        let model = IconPickerModel(
            purpose: .workspace,
            savedValue: IconChoice.symbol("folder"),
            defaultValue: .defaultValue
        )
        var commitCount = 0
        model.selectDefault()

        #expect(model.savedValue == .symbol("folder"))
        #expect(commitCount == 0)

        let saved = await model.save(
            prepareGenmoji: { _, _ in .defaultValue },
            commit: { value in
                commitCount += 1
                #expect(value == .defaultValue)
            }
        )

        #expect(saved)
        #expect(commitCount == 1)
        #expect(model.savedValue == .defaultValue)

        let secondSave = await model.save(
            prepareGenmoji: { _, _ in .defaultValue },
            commit: { _ in commitCount += 1 }
        )
        #expect(!secondSave)
        #expect(commitCount == 1)
    }

    private static func customChoice(_ value: IconChoice) -> IconPickerCustomChoice? {
        switch value {
        case .emoji(let emoji): return .emoji(emoji)
        case .genmoji(_, let contentDescription): return .genmoji(contentDescription)
        case .defaultValue, .symbol: return nil
        }
    }
}

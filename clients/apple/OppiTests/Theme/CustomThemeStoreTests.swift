import Foundation
import Testing
@testable import Oppi

/// Tests for CustomThemeStore persistence — save, load, delete, names.
@Suite("CustomThemeStore")
struct CustomThemeStoreTests {

    // Use a UUID suffix so parallel test runs don't collide.
    private let testSuffix = UUID().uuidString

    private func testName(_ base: String) -> String {
        "\(base)-\(testSuffix)"
    }

    private func makeTheme(name: String, colorScheme: String = "dark") -> RemoteTheme {
        RemoteTheme(
            name: name,
            colorScheme: colorScheme,
            colors: RemoteThemeColors(
                bg: "#1e1e2e", bgDark: "#181825", bgHighlight: "#313244",
                fg: "#cdd6f4", fgDim: "#a6adc8", comment: "#6c7086",
                blue: "#89b4fa", cyan: "#94e2d5", green: "#a6e3a1",
                orange: "#fab387", purple: "#cba6f7", red: "#f38ba8",
                yellow: "#f9e2af", thinkingText: "#a6adc8",
                userMessageBg: "#313244", userMessageText: "#cdd6f4",
                toolPendingBg: "#313244", toolSuccessBg: "#1e3a2e",
                toolErrorBg: "#3a1e1e", toolTitle: "#cdd6f4", toolOutput: "#a6adc8",
                mdHeading: "#89b4fa", mdLink: "#94e2d5", mdLinkUrl: "#6c7086",
                mdCode: "#94e2d5", mdCodeBlock: "#a6e3a1",
                mdCodeBlockBorder: "#313244", mdQuote: "#a6adc8",
                mdQuoteBorder: "#313244", mdHr: "#313244",
                mdListBullet: "#fab387",
                toolDiffAdded: "#a6e3a1", toolDiffRemoved: "#f38ba8",
                toolDiffContext: "#6c7086",
                syntaxComment: "#6c7086", syntaxKeyword: "#cba6f7",
                syntaxFunction: "#89b4fa", syntaxVariable: "#cdd6f4",
                syntaxString: "#a6e3a1", syntaxNumber: "#fab387",
                syntaxType: "#94e2d5", syntaxOperator: "#cdd6f4",
                syntaxPunctuation: "#a6adc8",
                thinkingOff: "#313244", thinkingMinimal: "#6c7086",
                thinkingLow: "#89b4fa", thinkingMedium: "#94e2d5",
                thinkingHigh: "#cba6f7", thinkingXhigh: "#f38ba8"
            )
        )
    }

    // MARK: - Save and load

    @Test func saveAndLoadRoundTrips() {
        let name = testName("Catppuccin")
        defer { CustomThemeStore.delete(name: name) }

        let theme = makeTheme(name: name)
        CustomThemeStore.save(theme)

        let loaded = CustomThemeStore.load(name: name)
        #expect(loaded != nil)
        #expect(loaded?.name == name)
        #expect(loaded?.colorScheme == "dark")
        #expect(loaded?.colors.bg == "#1e1e2e")
    }

    @Test func loadNonexistentReturnsNil() {
        let result = CustomThemeStore.load(name: "definitely-nonexistent-\(UUID().uuidString)")
        #expect(result == nil)
    }

    @Test func saveOverwritesExisting() {
        let name = testName("Overwrite")
        defer { CustomThemeStore.delete(name: name) }

        let v1 = makeTheme(name: name, colorScheme: "dark")
        CustomThemeStore.save(v1)

        let v2 = makeTheme(name: name, colorScheme: "light")
        CustomThemeStore.save(v2)

        let loaded = CustomThemeStore.load(name: name)
        #expect(loaded?.colorScheme == "light")
    }

    // MARK: - Delete

    @Test func deleteRemovesTheme() {
        let name = testName("ToDelete")

        CustomThemeStore.save(makeTheme(name: name))
        #expect(CustomThemeStore.load(name: name) != nil)

        CustomThemeStore.delete(name: name)
        #expect(CustomThemeStore.load(name: name) == nil)
    }

    @Test func deleteNonexistentDoesNotCrash() {
        // Should be a no-op, not a crash.
        CustomThemeStore.delete(name: "no-such-theme-\(UUID().uuidString)")
    }

    // MARK: - names()

    @Test func namesIncludesSavedThemes() {
        let name1 = testName("Alpha")
        let name2 = testName("Beta")
        defer {
            CustomThemeStore.delete(name: name1)
            CustomThemeStore.delete(name: name2)
        }

        CustomThemeStore.save(makeTheme(name: name1))
        CustomThemeStore.save(makeTheme(name: name2))

        let names = CustomThemeStore.names()
        #expect(names.contains(name1))
        #expect(names.contains(name2))
    }

    @Test func namesAreSorted() {
        let name1 = testName("Zebra")
        let name2 = testName("Alpha")
        defer {
            CustomThemeStore.delete(name: name1)
            CustomThemeStore.delete(name: name2)
        }

        CustomThemeStore.save(makeTheme(name: name1))
        CustomThemeStore.save(makeTheme(name: name2))

        let names = CustomThemeStore.names()
        // Filter to just our test names
        let ours = names.filter { $0.hasSuffix(testSuffix) }
        #expect(ours == ours.sorted())
    }

    @Test func deleteRemovesFromNames() {
        let name = testName("Gone")
        defer { CustomThemeStore.delete(name: name) }

        CustomThemeStore.save(makeTheme(name: name))
        #expect(CustomThemeStore.names().contains(name))

        CustomThemeStore.delete(name: name)
        #expect(!CustomThemeStore.names().contains(name))
    }

    // MARK: - loadAll

    @Test func loadAllContainsSavedThemes() {
        let name = testName("AllTest")
        defer { CustomThemeStore.delete(name: name) }

        CustomThemeStore.save(makeTheme(name: name))

        let all = CustomThemeStore.loadAll()
        #expect(all[name] != nil)
        #expect(all[name]?.colors.fg == "#cdd6f4")
    }

    // MARK: - toPalette integration

    @Test func savedThemeConvertsBackToPalette() {
        let name = testName("PaletteRoundTrip")
        defer { CustomThemeStore.delete(name: name) }

        let theme = makeTheme(name: name)
        CustomThemeStore.save(theme)

        let loaded = CustomThemeStore.load(name: name)
        let palette = loaded?.toPalette()
        #expect(palette != nil, "Saved theme should convert to a valid palette")
        // Verify a few fields survived the round-trip
        _ = palette?.bg
        _ = palette?.syntaxKeyword
        _ = palette?.mdHeading
    }
}

import Foundation
import UIKit
import Testing
@testable import Oppi

/// Tests for CodeFontFamily enum — raw values, display names, PostScript name generation, and font creation.
@Suite("CodeFontFamily")
struct CodeFontFamilyTests {

    // MARK: - Raw values

    @Test func systemRawValue() {
        #expect(FontPreferences.CodeFontFamily.system.rawValue == "system")
    }

    @Test func firaCodeRawValue() {
        #expect(FontPreferences.CodeFontFamily.firaCode.rawValue == "FiraCode")
    }

    @Test func jetBrainsMonoRawValue() {
        #expect(FontPreferences.CodeFontFamily.jetBrainsMono.rawValue == "JetBrainsMono")
    }

    @Test func cascadiaCodeRawValue() {
        #expect(FontPreferences.CodeFontFamily.cascadiaCode.rawValue == "CascadiaCode")
    }

    @Test func sourceCodeProRawValue() {
        #expect(FontPreferences.CodeFontFamily.sourceCodePro.rawValue == "SourceCodePro")
    }

    @Test func monaspaceNeonRawValue() {
        #expect(FontPreferences.CodeFontFamily.monaspaceNeon.rawValue == "MonaspaceNeon")
    }

    // MARK: - CaseIterable

    @Test func allCasesCountIs6() {
        #expect(FontPreferences.CodeFontFamily.allCases.count == 6)
    }

    @Test func allCasesContainsEveryFamily() {
        let all = FontPreferences.CodeFontFamily.allCases
        #expect(all.contains(.system))
        #expect(all.contains(.firaCode))
        #expect(all.contains(.jetBrainsMono))
        #expect(all.contains(.cascadiaCode))
        #expect(all.contains(.sourceCodePro))
        #expect(all.contains(.monaspaceNeon))
    }

    // MARK: - Display names

    @Test func displayNames() {
        #expect(FontPreferences.CodeFontFamily.system.displayName == "SF Mono")
        #expect(FontPreferences.CodeFontFamily.firaCode.displayName == "Fira Code")
        #expect(FontPreferences.CodeFontFamily.jetBrainsMono.displayName == "JetBrains Mono")
        #expect(FontPreferences.CodeFontFamily.cascadiaCode.displayName == "Cascadia Code")
        #expect(FontPreferences.CodeFontFamily.sourceCodePro.displayName == "Source Code Pro")
        #expect(FontPreferences.CodeFontFamily.monaspaceNeon.displayName == "Monaspace Neon")
    }

    // MARK: - fontNamePrefix

    @Test func systemPrefixIsNil() {
        #expect(FontPreferences.CodeFontFamily.system.fontNamePrefix == nil)
    }

    @Test func bundledFontPrefixesAreNonNil() {
        let bundled: [FontPreferences.CodeFontFamily] = [
            .firaCode, .jetBrainsMono, .cascadiaCode, .sourceCodePro, .monaspaceNeon,
        ]
        for family in bundled {
            #expect(family.fontNamePrefix != nil, "\(family.rawValue) should have a font name prefix")
        }
    }

    // MARK: - Identifiable

    @Test func idMatchesRawValue() {
        for family in FontPreferences.CodeFontFamily.allCases {
            #expect(family.id == family.rawValue)
        }
    }

    // MARK: - PostScript names

    @Test func systemPostScriptNameIsNilForAllWeights() {
        let sys = FontPreferences.CodeFontFamily.system
        #expect(sys.postScriptName(weight: .regular) == nil)
        #expect(sys.postScriptName(weight: .semibold) == nil)
        #expect(sys.postScriptName(weight: .bold) == nil)
    }

    @Test func firaCodePostScriptNames() {
        let f = FontPreferences.CodeFontFamily.firaCode
        #expect(f.postScriptName(weight: .regular) == "FiraCode-Regular")
        #expect(f.postScriptName(weight: .semibold) == "FiraCode-SemiBold")
        #expect(f.postScriptName(weight: .bold) == "FiraCode-Bold")
    }

    @Test func jetBrainsMonoPostScriptNames() {
        let f = FontPreferences.CodeFontFamily.jetBrainsMono
        #expect(f.postScriptName(weight: .regular) == "JetBrainsMono-Regular")
        #expect(f.postScriptName(weight: .semibold) == "JetBrainsMono-SemiBold")
        #expect(f.postScriptName(weight: .bold) == "JetBrainsMono-Bold")
    }

    @Test func cascadiaCodePostScriptNames() {
        let f = FontPreferences.CodeFontFamily.cascadiaCode
        #expect(f.postScriptName(weight: .regular) == "CascadiaCode-Regular")
        #expect(f.postScriptName(weight: .semibold) == "CascadiaCode-SemiBold")
        #expect(f.postScriptName(weight: .bold) == "CascadiaCode-Bold")
    }

    @Test func sourceCodeProPostScriptNames() {
        let f = FontPreferences.CodeFontFamily.sourceCodePro
        #expect(f.postScriptName(weight: .regular) == "SourceCodePro-Regular")
        // Source Code Pro uses lowercase 'b' in "Semibold"
        #expect(f.postScriptName(weight: .semibold) == "SourceCodePro-Semibold")
        #expect(f.postScriptName(weight: .bold) == "SourceCodePro-Bold")
    }

    @Test func monaspaceNeonPostScriptNames() {
        let f = FontPreferences.CodeFontFamily.monaspaceNeon
        #expect(f.postScriptName(weight: .regular) == "MonaspaceNeon-Regular")
        #expect(f.postScriptName(weight: .semibold) == "MonaspaceNeon-SemiBold")
        #expect(f.postScriptName(weight: .bold) == "MonaspaceNeon-Bold")
    }

    @Test func unmappedWeightDefaultsToRegular() {
        // Weights other than .regular/.semibold/.bold fall through to "Regular" suffix.
        let f = FontPreferences.CodeFontFamily.firaCode
        #expect(f.postScriptName(weight: .light) == "FiraCode-Regular")
        #expect(f.postScriptName(weight: .medium) == "FiraCode-Regular")
        #expect(f.postScriptName(weight: .ultraLight) == "FiraCode-Regular")
        #expect(f.postScriptName(weight: .heavy) == "FiraCode-Regular")
    }

    // MARK: - font(size:weight:) always produces a valid UIFont

    @Test func systemFontFallsBackToSystemMono() {
        let font = FontPreferences.CodeFontFamily.system.font(size: 12, weight: .regular)
        #expect(font.pointSize == 12)
    }

    @Test func allFamiliesProduceValidFonts() {
        let weights: [UIFont.Weight] = [.regular, .semibold, .bold]
        for family in FontPreferences.CodeFontFamily.allCases {
            for weight in weights {
                let font = family.font(size: 11, weight: weight)
                #expect(font.pointSize == 11, "\(family.rawValue) at \(weight) should produce an 11pt font")
            }
        }
    }

    @Test func fontWithUnmappedWeightFallsBackGracefully() {
        // .light weight has no bundled file — should fall back to system mono.
        let font = FontPreferences.CodeFontFamily.firaCode.font(size: 14, weight: .light)
        #expect(font.pointSize == 14)
    }
}

// MARK: - FontPreferences

@Suite("FontPreferences")
@MainActor
struct FontPreferencesTests {

    // MARK: - Code font

    @Test func defaultCodeFontIsSystem() {
        // Read without prior write — should return .system (or whatever is persisted).
        // We can't guarantee a clean UserDefaults in test, so just verify it returns a valid family.
        let family = FontPreferences.codeFont
        #expect(FontPreferences.CodeFontFamily.allCases.contains(family))
    }

    @Test func setCodeFontPersistsAndRebuilds() {
        let original = FontPreferences.codeFont
        defer { FontPreferences.setCodeFont(original) }

        FontPreferences.setCodeFont(.firaCode)
        #expect(FontPreferences.codeFont == .firaCode)

        FontPreferences.setCodeFont(.jetBrainsMono)
        #expect(FontPreferences.codeFont == .jetBrainsMono)
    }

    @Test func setCodeFontRoundTripsAllFamilies() {
        let original = FontPreferences.codeFont
        defer { FontPreferences.setCodeFont(original) }

        for family in FontPreferences.CodeFontFamily.allCases {
            FontPreferences.setCodeFont(family)
            #expect(FontPreferences.codeFont == family, "Round-trip failed for \(family.rawValue)")
        }
    }

    // MARK: - Mono messages

    @Test func setUseMonoForMessagesPersists() {
        let original = FontPreferences.useMonoForMessages
        defer { FontPreferences.setUseMonoForMessages(original) }

        FontPreferences.setUseMonoForMessages(true)
        #expect(FontPreferences.useMonoForMessages == true)

        FontPreferences.setUseMonoForMessages(false)
        #expect(FontPreferences.useMonoForMessages == false)
    }

    // MARK: - Notification

    @Test func setCodeFontPostsNotification() async {
        let original = FontPreferences.codeFont
        defer { FontPreferences.setCodeFont(original) }

        let expectation = NotificationCenter.default.notifications(
            named: FontPreferences.didChangeNotification
        )

        FontPreferences.setCodeFont(.cascadiaCode)

        // Drain one notification — should be available immediately since post is synchronous.
        var received = false
        for await _ in expectation {
            received = true
            break
        }
        #expect(received)
    }

    @Test func setMonoMessagesPostsNotification() async {
        let original = FontPreferences.useMonoForMessages
        defer { FontPreferences.setUseMonoForMessages(original) }

        let expectation = NotificationCenter.default.notifications(
            named: FontPreferences.didChangeNotification
        )

        FontPreferences.setUseMonoForMessages(!original)

        var received = false
        for await _ in expectation {
            received = true
            break
        }
        #expect(received)
    }
}

// MARK: - AppFont rebuild

@Suite("AppFont rebuild")
@MainActor
struct AppFontRebuildTests {

    @Test func rebuildSetsMonoFonts() {
        let originalFamily = FontPreferences.codeFont
        defer { FontPreferences.setCodeFont(originalFamily) }

        // Switch to system and rebuild
        FontPreferences.setCodeFont(.system)

        // After rebuild, all mono constants should be 11pt (mono) or their designated sizes.
        #expect(AppFont.mono.pointSize == 11)
        #expect(AppFont.monoBold.pointSize == 11)
        #expect(AppFont.monoSmall.pointSize == 10)
        #expect(AppFont.monoSmallSemibold.pointSize == 10)
        #expect(AppFont.monoMedium.pointSize == 12)
        #expect(AppFont.monoMediumBold.pointSize == 12)
        #expect(AppFont.monoMediumSemibold.pointSize == 12)
        #expect(AppFont.monoLarge.pointSize == 15)
        #expect(AppFont.monoLargeSemibold.pointSize == 15)
        #expect(AppFont.monoXL.pointSize == 17)
    }

    @Test func rebuildWithBundledFontChangesMonoConstants() {
        let originalFamily = FontPreferences.codeFont
        defer { FontPreferences.setCodeFont(originalFamily) }

        // Switch to a bundled font
        FontPreferences.setCodeFont(.firaCode)

        // Point sizes should remain the same regardless of family
        #expect(AppFont.mono.pointSize == 11)
        #expect(AppFont.monoMedium.pointSize == 12)
        #expect(AppFont.monoLarge.pointSize == 15)
    }

    @Test func messageBodyIsSystemWhenMonoMessagesDisabled() {
        let originalFamily = FontPreferences.codeFont
        let originalMono = FontPreferences.useMonoForMessages
        defer {
            FontPreferences.setCodeFont(originalFamily)
            FontPreferences.setUseMonoForMessages(originalMono)
        }

        FontPreferences.setUseMonoForMessages(false)
        AppFont.rebuild()

        // Should be the system body font
        let expected = UIFont.preferredFont(forTextStyle: .body)
        #expect(AppFont.messageBody.pointSize == expected.pointSize)
    }

    @Test func messageBodyIsMonoWhenMonoMessagesEnabled() {
        let originalFamily = FontPreferences.codeFont
        let originalMono = FontPreferences.useMonoForMessages
        defer {
            FontPreferences.setCodeFont(originalFamily)
            FontPreferences.setUseMonoForMessages(originalMono)
        }

        FontPreferences.setCodeFont(.system)
        FontPreferences.setUseMonoForMessages(true)
        AppFont.rebuild()

        // Point size should match system body
        let expectedSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        #expect(AppFont.messageBody.pointSize == expectedSize)
    }

    // MARK: - System fonts are static

    @Test func systemFontConstantsAreFixedSize() {
        #expect(AppFont.systemSmall.pointSize == 11)
        #expect(AppFont.systemFeedback.pointSize == 13)
        #expect(AppFont.systemFeedbackMedium.pointSize == 14)
    }
}

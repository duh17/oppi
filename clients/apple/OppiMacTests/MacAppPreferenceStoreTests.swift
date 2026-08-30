import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("FontPreferenceStore", .serialized)
struct FontPreferenceStoreTests {
    @Test func usesTheSameUserDefaultsKeysAsIOS() {
        #expect(FontPreferenceStore.codeFontKey == "codeFontFamily")
        #expect(FontPreferenceStore.codeTextScaleKey == "codeTextRelativeScale")
        #expect(FontPreferenceStore.storedEffectiveCodeTextScaleKey == "codeTextScale")
        #expect(FontPreferenceStore.codeFontSizePresetKey == "codeFontSize")
        #expect(FontPreferenceStore.messageTextScaleKey == "messageTextScale")
        #expect(FontPreferenceStore.monoMessagesKey == "useMonoForMessages")
    }

    @Test func codeFontFamilyRawValuesMatchIOS() {
        #expect(FontPreferenceStore.CodeFontFamily.system.rawValue == "system")
        #expect(FontPreferenceStore.CodeFontFamily.firaCode.rawValue == "FiraCode")
        #expect(FontPreferenceStore.CodeFontFamily.jetBrainsMono.rawValue == "JetBrainsMono")
        #expect(FontPreferenceStore.CodeFontFamily.cascadiaCode.rawValue == "CascadiaCode")
        #expect(FontPreferenceStore.CodeFontFamily.sourceCodePro.rawValue == "SourceCodePro")
        #expect(FontPreferenceStore.CodeFontFamily.monaspaceNeon.rawValue == "MonaspaceNeon")
        #expect(FontPreferenceStore.CodeFontFamily.allCases.count == 6)
    }

    @Test func persistsCodeFontFamily() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setCodeFont(.jetBrainsMono)
        #expect(FontPreferenceStore.codeFont == .jetBrainsMono)
        #expect(UserDefaults.standard.string(forKey: FontPreferenceStore.codeFontKey) == "JetBrainsMono")
    }

    @Test func defaultsCodeFontToSystem() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeFontKey)
        #expect(FontPreferenceStore.codeFont == .system)
    }

    @Test func persistsAndClampsCodeTextScale() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setCodeTextScale(1.25)
        #expect(FontPreferenceStore.codeTextScale == 1.25)

        FontPreferenceStore.setCodeTextScale(99)
        #expect(FontPreferenceStore.codeTextScale == FontPreferenceStore.maximumCodeTextScale)
        #expect(UserDefaults.standard.object(forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey) == nil)
        #expect(UserDefaults.standard.object(forKey: FontPreferenceStore.codeFontSizePresetKey) == nil)
    }

    @Test func persistsAndClampsMessageTextScale() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setMessageTextScale(1.2)
        #expect(FontPreferenceStore.messageTextScale == 1.2)

        FontPreferenceStore.setMessageTextScale(0.1)
        #expect(FontPreferenceStore.messageTextScale == FontPreferenceStore.minimumMessageTextScale)
    }

    @Test func defaultCodeTextScaleIsOneHundredPercent() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeFontSizePresetKey)

        #expect(FontPreferenceStore.codeTextScale == FontPreferenceStore.standardCodeTextScale)
        #expect(FontPreferenceStore.codePointSize(baseSize: 11) == 12)
    }

    @Test func storedEffectiveScaleMapsCurrentReadableSizeToOneHundredPercent() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeTextScaleKey)
        UserDefaults.standard.set(1.10, forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeFontSizePresetKey)

        #expect(FontPreferenceStore.codeTextScale == 1.0)
        #expect(FontPreferenceStore.codePointSize(baseSize: 11) == 12)
    }

    @Test func storedCodeFontSizePresetsMapToScale() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.codeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey)
        UserDefaults.standard.set("compact", forKey: FontPreferenceStore.codeFontSizePresetKey)
        #expect(FontPreferenceStore.codeTextScale == 1.0)

        UserDefaults.standard.set("large", forKey: FontPreferenceStore.codeFontSizePresetKey)
        #expect(FontPreferenceStore.codeTextScale == FontPreferenceStore.maximumCodeTextScale)
    }

    @Test func persistsMonoMessages() {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setUseMonoForMessages(true)
        #expect(FontPreferenceStore.useMonoForMessages)
        FontPreferenceStore.setUseMonoForMessages(false)
        #expect(!FontPreferenceStore.useMonoForMessages)
    }

    @Test func bundledMacCodeFontFamiliesAreRegistered() throws {
        for name in [
            "FiraCode-Regular", "FiraCode-SemiBold", "FiraCode-Bold",
            "JetBrainsMono-Regular", "JetBrainsMono-SemiBold", "JetBrainsMono-Bold",
            "CascadiaCode-Regular", "CascadiaCode-SemiBold", "CascadiaCode-Bold",
            "SourceCodePro-Regular", "SourceCodePro-Semibold", "SourceCodePro-Bold",
            "MonaspaceNeon-Regular", "MonaspaceNeon-SemiBold", "MonaspaceNeon-Bold",
        ] {
            let font = try #require(NSFont(name: name, size: 12), "Missing bundled font \(name)")
            #expect(font.fontName == name)
        }
    }

    @Test func macCodePainterUsesSelectedFamilyAndScale() throws {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setCodeFont(.monaspaceNeon)
        FontPreferenceStore.setCodeTextScale(FontPreferenceStore.maximumCodeTextScale)

        let attributed = MacSyntaxHighlighter.attributedCode(
            "let value = 42",
            language: .swift,
            includeLineNumbers: false
        )
        let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let expectedSize = CGFloat(FontPreferenceStore.codePointSize(baseSize: 11))
        let requested = try #require(NSFont(name: "MonaspaceNeon-Regular", size: expectedSize))

        #expect(font.pointSize == expectedSize)
        #expect(font.fontName == requested.fontName)
    }

    @Test func macMessageFontUsesMessageScaleAndMonoIndependently() throws {
        let snapshot = captureFontDefaults()
        defer { restoreFontDefaults(snapshot) }

        FontPreferenceStore.setCodeFont(.monaspaceNeon)
        FontPreferenceStore.setCodeTextScale(FontPreferenceStore.minimumCodeTextScale)
        FontPreferenceStore.setMessageTextScale(FontPreferenceStore.maximumMessageTextScale)
        FontPreferenceStore.setUseMonoForMessages(true)

        let monoFont = FontPreferenceStore.macMessageFont(forTextStyle: .body)
        let expectedSize = CGFloat(FontPreferenceStore.messagePointSize(
            baseSize: Double(NSFont.preferredFont(forTextStyle: .body).pointSize)
        ))
        let requested = try #require(NSFont(name: "MonaspaceNeon-Regular", size: expectedSize))

        #expect(monoFont.pointSize == expectedSize)
        #expect(monoFont.fontName == requested.fontName)

        FontPreferenceStore.setUseMonoForMessages(false)
        let proportionalFont = FontPreferenceStore.macMessageFont(forTextStyle: .body)
        #expect(proportionalFont.pointSize == expectedSize)
        #expect(proportionalFont.fontName == NSFont.systemFont(ofSize: expectedSize).fontName)
    }

    @Test func liveMacTypographyRepaintsWithoutReplacingTimelineOrDocumentSubtrees() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let macViews = testsURL.deletingLastPathComponent().appending(path: "OppiMac/Views")
        let timeline = try String(
            contentsOf: macViews.appending(path: "MacSessionTimelineViews.swift"),
            encoding: .utf8
        )
        let document = try String(
            contentsOf: macViews.appending(path: "MacToolDocumentColumn.swift"),
            encoding: .utf8
        )
        let markdown = try String(
            contentsOf: macViews.appending(path: "MacMarkdownBlockViews.swift"),
            encoding: .utf8
        )

        #expect(timeline.contains("FontPreferenceStore.didChangeNotification"))
        #expect(timeline.contains("let _ = fontPreferenceRevision"))
        #expect(!timeline.contains(".id(fontPreferenceRevision)"))
        #expect(timeline.contains("usesMessageTypography: true"))
        #expect(document.contains("FontPreferenceStore.didChangeNotification"))
        #expect(document.contains("let _ = fontPreferenceRevision"))
        #expect(!document.contains(".id(fontPreferenceRevision)"))
        #expect(markdown.contains("FontPreferenceStore.macMessageFont"))
    }

    @Test func remainingMacCodePaintersUseFontPreferences() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let macViews = testsURL.deletingLastPathComponent().appending(path: "OppiMac/Views")
        let shell = try String(
            contentsOf: macViews.appending(path: "MacSessionShellViews.swift"),
            encoding: .utf8
        )
        let extensions = try String(
            contentsOf: macViews.appending(path: "MacExtensionSurfacePanel.swift"),
            encoding: .utf8
        )

        #expect(shell.contains("FontPreferenceStore.macCodeFont"))
        #expect(shell.contains("FontPreferenceStore.didChangeNotification"))
        #expect(shell.contains("let _ = fontPreferenceRevision"))
        #expect(!shell.contains(".id(fontPreferenceRevision)"))
        #expect(!shell.contains("design: .monospaced"))
        #expect(!shell.contains(".caption.monospaced()"))
        #expect(extensions.contains("FontPreferenceStore.macCodeFont"))
        #expect(!extensions.contains("design: .monospaced"))
        #expect(!extensions.contains(".caption.monospaced()"))
        #expect(!extensions.contains(".caption2.monospaced()"))
    }
}

@Suite("AppPreferenceStore.Session", .serialized)
struct SessionPreferenceStoreTests {
    @Test func usesTheSameAutoTitleKeyAsIOS() {
        #expect(
            AppPreferenceStore.Session.autoTitleProviderKey
                == "\(AppIdentifiers.subsystem).session.autoTitle.provider"
        )
    }

    @Test func defaultsAutoTitleProviderToServer() {
        let key = AppPreferenceStore.Session.autoTitleProviderKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { restoreObject(original, forKey: key) }

        #expect(AppPreferenceStore.Session.autoTitleProvider == .server)
        #expect(AppPreferenceStore.Session.isAutoTitleEnabled)
    }

    @Test func persistsAutoTitleProvider() {
        let key = AppPreferenceStore.Session.autoTitleProviderKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreObject(original, forKey: key) }

        AppPreferenceStore.Session.setAutoTitleProvider(.onDevice)
        #expect(AppPreferenceStore.Session.autoTitleProvider == .onDevice)
        #expect(UserDefaults.standard.string(forKey: key) == "onDevice")

        AppPreferenceStore.Session.setAutoTitleProvider(.off)
        #expect(AppPreferenceStore.Session.autoTitleProvider == .off)
        #expect(!AppPreferenceStore.Session.isAutoTitleEnabled)
    }
}

@Suite("AppPreferenceStore.ScreenAwake", .serialized)
struct ScreenAwakePreferenceStoreTests {
    @Test func usesTheSameTimeoutKeyAndPresetsAsIOS() {
        #expect(
            AppPreferenceStore.ScreenAwake.timeoutPresetKey
                == "\(AppIdentifiers.subsystem).screenAwake.timeoutPreset"
        )
        #expect(AppPreferenceStore.ScreenAwake.TimeoutPreset.allCases.map(\.rawValue) == [
            0, 60, 120, 300, 600,
        ])
        #expect(AppPreferenceStore.ScreenAwake.TimeoutPreset.allCases.map(\.label) == [
            "Off",
            "1 minute",
            "2 minutes",
            "5 minutes",
            "10 minutes",
        ])
        #expect(AppPreferenceStore.ScreenAwake.TimeoutPreset.off.duration == nil)
        #expect(AppPreferenceStore.ScreenAwake.TimeoutPreset.twoMinutes.duration == .seconds(120))
    }

    @Test func defaultsTimeoutPresetToTwoMinutes() {
        let key = AppPreferenceStore.ScreenAwake.timeoutPresetKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { restoreObject(original, forKey: key) }

        #expect(AppPreferenceStore.ScreenAwake.timeoutPreset == .twoMinutes)
        #expect(AppPreferenceStore.ScreenAwake.keepAwakeDuration == .seconds(120))
    }

    @Test func persistsTimeoutPreset() {
        let key = AppPreferenceStore.ScreenAwake.timeoutPresetKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreObject(original, forKey: key) }

        AppPreferenceStore.ScreenAwake.setTimeoutPreset(.off)
        #expect(AppPreferenceStore.ScreenAwake.timeoutPreset == .off)
        #expect(AppPreferenceStore.ScreenAwake.keepAwakeDuration == nil)
        #expect(UserDefaults.standard.object(forKey: key) as? Int == 0)

        AppPreferenceStore.ScreenAwake.setTimeoutPreset(.fiveMinutes)
        #expect(AppPreferenceStore.ScreenAwake.timeoutPreset == .fiveMinutes)
        #expect(AppPreferenceStore.ScreenAwake.keepAwakeDuration == .seconds(300))
    }
}

@Suite("AppPreferenceStore.Voice", .serialized)
struct VoiceEnginePreferenceStoreTests {
    @Test func usesTheSameEngineKeyAsIOS() {
        #expect(
            AppPreferenceStore.Voice.engineModeKey
                == "\(AppIdentifiers.subsystem).voice.engineMode"
        )
    }

    @Test func supportedModesExcludeAuto() {
        #expect(AppPreferenceStore.Voice.supportedModes == [.remote, .onDevice])
    }

    @Test func defaultsEngineModeToRemote() {
        let key = AppPreferenceStore.Voice.engineModeKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { restoreObject(original, forKey: key) }

        #expect(AppPreferenceStore.Voice.engineMode == .remote)
    }

    @Test func migratesStoredAutoEngineModeToRemote() {
        let key = AppPreferenceStore.Voice.engineModeKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreObject(original, forKey: key) }

        UserDefaults.standard.set("auto", forKey: key)
        #expect(AppPreferenceStore.Voice.engineMode == .remote)

        AppPreferenceStore.Voice.setEngineMode(.auto)
        #expect(UserDefaults.standard.string(forKey: key) == "remote")
        #expect(AppPreferenceStore.Voice.engineMode == .remote)
    }

    @Test func persistsOnDeviceEngineMode() {
        let key = AppPreferenceStore.Voice.engineModeKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreObject(original, forKey: key) }

        AppPreferenceStore.Voice.setEngineMode(.onDevice)
        #expect(AppPreferenceStore.Voice.engineMode == .onDevice)
        #expect(UserDefaults.standard.string(forKey: key) == "onDevice")
    }

    @Test func usesTheSameReplyModeKeysAsIOS() {
        #expect(
            AppPreferenceStore.Voice.replyModeKey
                == "\(AppIdentifiers.subsystem).voice.replyMode"
        )
        #expect(
            AppPreferenceStore.Voice.sessionReplyModeOverridesKey
                == "\(AppIdentifiers.subsystem).voice.sessionReplyModeOverrides"
        )
    }

    @Test func defaultsReplyModeToAutoplay() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        UserDefaults.standard.removeObject(forKey: AppPreferenceStore.Voice.replyModeKey)
        #expect(AppPreferenceStore.Voice.replyMode == .autoplay)
    }

    @Test func migratesStoredVoiceReplyModeAliases() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        let key = AppPreferenceStore.Voice.replyModeKey
        UserDefaults.standard.set("voice", forKey: key)
        #expect(AppPreferenceStore.Voice.replyMode == .manual)
        UserDefaults.standard.set("audioMessage", forKey: key)
        #expect(AppPreferenceStore.Voice.replyMode == .manual)
        UserDefaults.standard.set("directSpeak", forKey: key)
        #expect(AppPreferenceStore.Voice.replyMode == .autoplay)
    }

    @Test func persistsSessionReplyModeOverride() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        AppPreferenceStore.Voice.setReplyMode(.autoplay)
        AppPreferenceStore.Voice.setSessionReplyMode(.manual, for: "sess-voice-1")
        #expect(AppPreferenceStore.Voice.sessionReplyMode(for: "sess-voice-1") == .manual)
        #expect(!AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .playNow, sessionId: "sess-voice-1"))
        #expect(AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .playNow, sessionId: "sess-other"))
    }

    @Test func applySessionReplyModeDetailsPersistsAndClears() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        let sessionId = "sess-voice-details"
        AppPreferenceStore.Voice.setReplyMode(.autoplay)
        AppPreferenceStore.Voice.applySessionReplyModeDetails(
            ["kind": "voice_reply_mode", "mode": "manual"],
            sessionId: sessionId
        )
        #expect(AppPreferenceStore.Voice.sessionReplyMode(for: sessionId) == .manual)

        AppPreferenceStore.Voice.applySessionReplyModeDetails(
            ["kind": "voice_reply_mode", "mode": "default"],
            sessionId: sessionId
        )
        #expect(AppPreferenceStore.Voice.sessionReplyMode(for: sessionId) == nil)
        #expect(AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .playNow, sessionId: sessionId))
    }

    @Test func agentDecidesModeOnlyAutoplaysPlayNowReplies() {
        let snapshot = captureVoiceReplyDefaults()
        defer { restoreVoiceReplyDefaults(snapshot) }

        AppPreferenceStore.Voice.setReplyMode(.autoplay)
        AppPreferenceStore.Voice.setSessionReplyMode(nil, for: "sess-voice-agent")
        #expect(AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .playNow))
        #expect(!AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: .tapToPlay))
        #expect(!AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: nil))
    }
}

@Suite("Mac app settings preference controls")
struct MacAppSettingsPreferenceControlTests {
    @Test func exposesAvatarSpinnerTypographyAutoTitleAndDictationEngine() {
        let titles = MacAppSettingsPreferenceControl.allCases.map(\.title)
        #expect(titles == [
            "Assistant Avatar",
            "Spinner Style",
            "Keybindings",
            "Code Font",
            "Code Text Size",
            "Message Text Size",
            "Monospaced messages",
            "Auto-name Sessions",
            "Keep screen awake",
            "Dictation Engine",
        ])
    }

    @Test func avatarPickerOffersBuiltinsAndEmojiWithoutGenmoji() {
        #expect(MacAssistantAvatarKind.allCases == [
            .officialPi,
            .piText,
            .golGrid,
            .emoji,
        ])
        #expect(MacAssistantAvatarKind.allCases.map(\.title) == [
            "Official Pi",
            "Classic π",
            "Grid π",
            "Emoji",
        ])
    }
}

@Suite("AppPreferenceStore.Appearance", .serialized)
struct AppearancePreferenceStoreTests {
    @Test func usesTheSameSpinnerKeyAsIOS() {
        #expect(AppPreferenceStore.Appearance.spinnerStyleKey == "spinnerStyle")
    }

    @Test func displayNamesMatchIOSSettings() {
        #expect(SpinnerStyle.brailleDots.displayName == "Pi")
        #expect(SpinnerStyle.gameOfLife.displayName == "GoL")
        #expect(SpinnerStyle.allCases == [.brailleDots, .gameOfLife])
    }

    @Test func defaultsSpinnerStyleToPi() {
        let key = AppPreferenceStore.Appearance.spinnerStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { restoreObject(original, forKey: key) }

        #expect(AppPreferenceStore.Appearance.spinnerStyle == .brailleDots)
        #expect(SpinnerStyle.current == .brailleDots)
    }

    @Test func persistsSpinnerStyle() {
        let key = AppPreferenceStore.Appearance.spinnerStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreObject(original, forKey: key) }

        AppPreferenceStore.Appearance.setSpinnerStyle(.gameOfLife)
        #expect(AppPreferenceStore.Appearance.spinnerStyle == .gameOfLife)
        #expect(UserDefaults.standard.string(forKey: key) == "gameOfLife")
        #expect(SpinnerStyle.current == .gameOfLife)

        AppPreferenceStore.Appearance.setSpinnerStyle(.brailleDots)
        #expect(SpinnerStyle.current == .brailleDots)
    }
}

@Suite("AssistantAvatarPreference", .serialized)
@MainActor
struct AssistantAvatarPreferenceTests {
    @Test func builtinCasesMatchIOS() {
        #expect(AssistantAvatarPreference.builtinCases == [
            .officialPi,
            .piText,
            .golGrid,
        ])
        #expect(AssistantAvatarPreference.officialPi.displayName == "Official Pi")
        #expect(AssistantAvatarPreference.piText.displayName == "Classic π")
        #expect(AssistantAvatarPreference.golGrid.displayName == "Grid π")
    }

    @Test func usesTheSamePersistenceKeysAsIOS() {
        #expect(AssistantAvatarPreference.typeKey == "assistantAvatarType")
        #expect(AssistantAvatarPreference.emojiKey == "assistantAvatarEmoji")
    }

    @Test func persistsBuiltinsAndEmoji() throws {
        let snapshot = captureAvatarDefaults()
        defer { restoreAvatarDefaults(snapshot) }

        try AssistantAvatarPreference.setCurrent(.officialPi)
        #expect(AssistantAvatarPreference.current == .officialPi)
        #expect(UserDefaults.standard.string(forKey: AssistantAvatarPreference.typeKey) == "officialPi")

        try AssistantAvatarPreference.setCurrent(.golGrid)
        #expect(AssistantAvatarPreference.current == .golGrid)

        try AssistantAvatarPreference.setCurrent(.emoji("🦊"))
        #expect(AssistantAvatarPreference.current == .emoji("🦊"))
        #expect(UserDefaults.standard.string(forKey: AssistantAvatarPreference.typeKey) == "emoji")
        #expect(UserDefaults.standard.string(forKey: AssistantAvatarPreference.emojiKey) == "🦊")

        try AssistantAvatarPreference.setCurrent(.piText)
        #expect(AssistantAvatarPreference.current == .piText)
    }

    @Test func rejectsInvalidEmojiWithoutWriting() throws {
        let suiteName = "AssistantAvatarPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("piText", forKey: AssistantAvatarPreference.typeKey)

        let store = AssistantAvatarPreferenceStore(defaults: defaults)
        #expect(throws: AssistantAvatarPreference.PersistenceError.invalidEmoji) {
            try store.setCurrent(.emoji("plain text"))
        }
        #expect(store.current == .piText)
        #expect(defaults.string(forKey: AssistantAvatarPreference.typeKey) == "piText")
    }

    @Test func storedGenmojiReadsAsPiTextWithoutRewriting() throws {
        let suiteName = "AssistantAvatarPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("genmoji", forKey: AssistantAvatarPreference.typeKey)
        defaults.set(Data([0x00, 0x01]), forKey: AssistantAvatarPreference.genmojiKey)
        defaults.set("Pink square", forKey: AssistantAvatarPreference.genmojiDescriptionKey)

        let store = AssistantAvatarPreferenceStore(defaults: defaults)
        #expect(store.current == .piText)
        #expect(defaults.string(forKey: AssistantAvatarPreference.typeKey) == "genmoji")
        #expect(defaults.data(forKey: AssistantAvatarPreference.genmojiKey) == Data([0x00, 0x01]))
    }

    @Test func malformedPersistedEmojiNormalizesToPiText() throws {
        let suiteName = "AssistantAvatarPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("emoji", forKey: AssistantAvatarPreference.typeKey)
        defaults.set("plain text", forKey: AssistantAvatarPreference.emojiKey)

        let store = AssistantAvatarPreferenceStore(defaults: defaults)
        #expect(store.current == .piText)
        #expect(defaults.string(forKey: AssistantAvatarPreference.typeKey) == "piText")
    }
}

private struct FontDefaultsSnapshot {
    let codeFont: Any?
    let relativeScale: Any?
    let storedEffectiveScale: Any?
    let storedSizePreset: Any?
    let messageScale: Any?
    let monoMessages: Any?
}

private func captureFontDefaults() -> FontDefaultsSnapshot {
    FontDefaultsSnapshot(
        codeFont: UserDefaults.standard.object(forKey: FontPreferenceStore.codeFontKey),
        relativeScale: UserDefaults.standard.object(forKey: FontPreferenceStore.codeTextScaleKey),
        storedEffectiveScale: UserDefaults.standard.object(
            forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey
        ),
        storedSizePreset: UserDefaults.standard.object(forKey: FontPreferenceStore.codeFontSizePresetKey),
        messageScale: UserDefaults.standard.object(forKey: FontPreferenceStore.messageTextScaleKey),
        monoMessages: UserDefaults.standard.object(forKey: FontPreferenceStore.monoMessagesKey)
    )
}

private func restoreFontDefaults(_ snapshot: FontDefaultsSnapshot) {
    restoreObject(snapshot.codeFont, forKey: FontPreferenceStore.codeFontKey)
    restoreObject(snapshot.relativeScale, forKey: FontPreferenceStore.codeTextScaleKey)
    restoreObject(snapshot.storedEffectiveScale, forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey)
    restoreObject(snapshot.storedSizePreset, forKey: FontPreferenceStore.codeFontSizePresetKey)
    restoreObject(snapshot.messageScale, forKey: FontPreferenceStore.messageTextScaleKey)
    restoreObject(snapshot.monoMessages, forKey: FontPreferenceStore.monoMessagesKey)
}

private func restoreObject(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct AvatarDefaultsSnapshot {
    let type: Any?
    let emoji: Any?
    let genmoji: Any?
    let genmojiDescription: Any?
}

@MainActor
private func captureAvatarDefaults() -> AvatarDefaultsSnapshot {
    AvatarDefaultsSnapshot(
        type: UserDefaults.standard.object(forKey: AssistantAvatarPreference.typeKey),
        emoji: UserDefaults.standard.object(forKey: AssistantAvatarPreference.emojiKey),
        genmoji: UserDefaults.standard.object(forKey: AssistantAvatarPreference.genmojiKey),
        genmojiDescription: UserDefaults.standard.object(
            forKey: AssistantAvatarPreference.genmojiDescriptionKey
        )
    )
}

@MainActor
private func restoreAvatarDefaults(_ snapshot: AvatarDefaultsSnapshot) {
    restoreObject(snapshot.type, forKey: AssistantAvatarPreference.typeKey)
    restoreObject(snapshot.emoji, forKey: AssistantAvatarPreference.emojiKey)
    restoreObject(snapshot.genmoji, forKey: AssistantAvatarPreference.genmojiKey)
    restoreObject(snapshot.genmojiDescription, forKey: AssistantAvatarPreference.genmojiDescriptionKey)
}

struct VoiceReplyDefaultsSnapshot {
    let replyMode: Any?
    let sessionOverrides: Any?
}

func captureVoiceReplyDefaults() -> VoiceReplyDefaultsSnapshot {
    VoiceReplyDefaultsSnapshot(
        replyMode: UserDefaults.standard.object(forKey: AppPreferenceStore.Voice.replyModeKey),
        sessionOverrides: UserDefaults.standard.object(
            forKey: AppPreferenceStore.Voice.sessionReplyModeOverridesKey
        )
    )
}

func restoreVoiceReplyDefaults(_ snapshot: VoiceReplyDefaultsSnapshot) {
    restoreObject(snapshot.replyMode, forKey: AppPreferenceStore.Voice.replyModeKey)
    restoreObject(snapshot.sessionOverrides, forKey: AppPreferenceStore.Voice.sessionReplyModeOverridesKey)
}

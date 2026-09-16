import Foundation
import Testing
@testable import Oppi

@Suite("Mac chat display chrome")
struct MacChatDisplayChromeTests {
    @Test func settingsFormExposesSpinnerPickersWithoutAvatarChoice() throws {
        let source = try macSettingsSource()
        #expect(source.contains("MacAppSettingsPreferenceControl.spinnerStyle.title"))
        #expect(source.contains("MacAppSettingsPreferenceControl.keepScreenAwake.title"))
        #expect(source.contains("MacAppSettingsPreferenceControl.keybindings.title"))
        #expect(source.contains("KeybindingMode.allCases"))
        #expect(source.contains("KeybindingPreferenceStore().mode = newValue"))
        #expect(source.contains("AppPreferenceStore.ScreenAwake.TimeoutPreset.allCases"))
        #expect(source.contains("MacScreenAwakeController.shared.refreshFromPreferences"))
        #expect(source.contains("Clear Local Cache"))
        #expect(source.contains("MacPastedAttachmentFileStore.clearAll"))
        #expect(source.contains("SpinnerStyle.allCases"))
        #expect(source.contains("AppPreferenceStore.Appearance.setSpinnerStyle"))
        #expect(source.contains("MacWorkingSpinnerView("))
        #expect(!source.contains("Assistant Avatar"))
        #expect(!source.contains("MacAssistantAvatarKind"))
        #expect(!source.contains("AssistantAvatarPreference"))
        #expect(!source.contains("AvatarPickerView"))
        #expect(!source.contains("UnifiedIconPickerView"))
        #expect(!source.contains(".genmoji"))
        #expect(!source.contains("compactTurns"))
        #expect(!source.contains("TimelineCache.shared"))
        #expect(!source.contains("isIdleTimerDisabled"))
        #expect(!source.contains("UIApplication"))
    }

    @Test func timelinePaintsAssistantAvatarAndWorkingSpinner() throws {
        let source = try macTimelineSource()
        #expect(source.contains("showsAssistantAvatar: role == .assistant"))
        #expect(source.contains("MacAssistantAvatarView(size: 18)"))
        #expect(source.contains("MacWorkingIndicatorRow(state:"))
        #expect(source.contains("MacWorkingIndicatorRow.rowID"))
        #expect(source.contains("isBusy: Bool = false"))
        #expect(!source.contains("WorkingIndicatorTimelineRowContentView"))
        #expect(!source.contains("AvatarPickerView"))
        #expect(!source.contains("WindowGroup"))
    }

    @Test func shellPassesBusyStateIntoTimeline() throws {
        let source = try macShellSource()
        #expect(source.contains("isBusy: store.session?.status.isRunning == true"))
    }

    @Test func chromePaintsPreferenceBackedAvatarAndSpinner() throws {
        let source = try macChromeSource()
        #expect(source.contains("MacOfficialPiMark"))
        #expect(source.contains("SpinnerStyle"))
        #expect(source.contains("MacBrailleSpinner"))
        #expect(source.contains("MacGameOfLifeSpinner"))
        #expect(!source.contains("SessionGridRenderer"))
        #expect(!source.contains("AssistantAvatarPreference"))
        #expect(!source.contains("import UIKit"))
        #expect(!source.contains("UIImage"))
        #expect(!source.contains("UIViewRepresentable"))
    }

    @Test func assistantAvatarPaintReadsAndThreadsTheLiveTheme() throws {
        let source = try macChromeSource()
        let avatarPaint = try sourceSlice(
            named: "struct MacAssistantAvatarView: View {",
            until: "struct MacWorkingSpinnerView: View {",
            in: source
        )

        #expect(avatarPaint.contains("@Environment(\\.theme) private var theme"))
        #expect(avatarPaint.contains("MacOfficialPiMark(color: theme.text.primary)"))
        #expect(avatarPaint.contains("theme.text.tertiary.opacity(0.10)"))
        #expect(avatarPaint.contains("accessibilityLabel(\"Pi\")"))
        #expect(!avatarPaint.contains("golGrid"))
        #expect(!avatarPaint.contains("Color.theme"))
    }
}

private func macSettingsSource() throws -> String {
    try contents(of: "OppiMac/Views/SettingsView.swift")
}

private func macTimelineSource() throws -> String {
    try contents(of: "OppiMac/Views/MacSessionTimelineViews.swift")
}

private func macShellSource() throws -> String {
    try contents(of: "OppiMac/Views/MacSessionShellViews.swift")
}

private func macChromeSource() throws -> String {
    try contents(of: "OppiMac/Views/MacChatDisplayChrome.swift")
}

private func sourceSlice(named marker: String, until endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw SourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw SourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}

private func contents(of relativePath: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

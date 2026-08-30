import Foundation
import Testing
@testable import Oppi

@Suite("Mac composer action paint")
struct MacComposerActionPaintTests {
    @Test func sendFillUsesAccentWhenIdleAndSendable() {
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: false, canSend: true, isBusy: false) == .accent
        )
    }

    @Test func sendFillUsesPurpleWhenBusyAndSendableOrInFlight() {
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: false, canSend: true, isBusy: true) == .purple
        )
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: true, canSend: false, isBusy: true) == .purple
        )
    }

    @Test func sendFillUsesAccentWhenIdleAndInFlight() {
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: true, canSend: false, isBusy: false) == .accent
        )
    }

    @Test func sendFillUsesDisabledWhenEmpty() {
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: false, canSend: false, isBusy: false) == .disabled
        )
        #expect(
            MacComposerActionPaint.sendFill(isSendInFlight: false, canSend: false, isBusy: true) == .disabled
        )
    }

    @Test func stopFillTurnsOrangeWhileStopping() {
        #expect(MacComposerActionPaint.stopFill(isStoppingTurn: false) == .red)
        #expect(MacComposerActionPaint.stopFill(isStoppingTurn: true) == .orange)
    }

    @Test func modelPillUsesProviderGlyphKeyAndDownChevron() {
        #expect(MacComposerActionPaint.modelChevronSystemImage == "chevron.down")
        #expect(MacComposerActionPaint.modelChevronSystemImage != "chevron.up.chevron.down")
        #expect(MacComposerActionPaint.modelPillProviderKey(for: "openai/gpt-5.5") == "openai")
        #expect(MacComposerActionPaint.modelPillProviderKey(for: "anthropic/claude-sonnet-4") == "anthropic")
        #expect(MacComposerActionPaint.modelPillProviderKey(for: nil) == nil)
        #expect(MacComposerActionPaint.modelPillProviderKey(for: "gpt-5.5") == nil)
    }

    @Test func emptyFailedSessionLeavesFailureRecoveryToTimeline() {
        #expect(!MacSessionWindowChrome.showsComposerStateBar(
            surface: .failed,
            hasTimelineItems: false
        ))
        #expect(MacSessionWindowChrome.showsComposerStateBar(
            surface: .failed,
            hasTimelineItems: true
        ))
    }

    @Test func composerSourceIncludesCompactAndNamedInteractionStates() throws {
        let source = try composerSource()

        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains("compactComposerActionRow"))
        #expect(source.contains("private var showsMessageQueueEditor"))
        #expect(source.contains("if showsMessageQueueEditor"))
        #expect(source.contains("Cancel dictation setup"))
        #expect(source.contains("Finishing dictation"))
        #expect(source.contains("Resuming…"))
        #expect(source.contains("Sending answer…"))
        #expect(source.contains("Remove attachment"))
        #expect(source.contains("Move queued message earlier"))
        #expect(source.contains("Move queued message later"))
        #expect(source.contains("Move queued message to"))
        #expect(source.contains("Delete queued message"))
    }

    @Test func menuBackedPillsDoNotPaintTheirOwnDisclosureChevron() throws {
        let source = try composerSource()
        let busyMode = try sourceSlice(
            named: "private func busyModeSelector(compact: Bool) -> some View {",
            until: "private func modelPickerButton",
            in: source
        )
        let thinking = try sourceSlice(
            named: "private func thinkingLevelMenu(compact: Bool) -> some View {",
            until: "private func insertSlashCommand",
            in: source
        )

        #expect(!busyMode.contains("showChevron: true"))
        #expect(!thinking.contains("showChevron: true"))
    }

    @Test func compactModelPickerKeepsAVisibleSymbolAndAccessibleName() throws {
        let source = try composerSource()
        let modelPicker = try sourceSlice(
            named: "private func modelPickerButton(compact: Bool) -> some View {",
            until: "private func thinkingLevelMenu",
            in: source
        )

        #expect(modelPicker.contains("systemImage: compact ? \"cpu\" : nil"))
        #expect(modelPicker.contains("if !compact, let provider"))
        #expect(modelPicker.contains(".accessibilityValue("))
        #expect(modelPicker.contains("MacModelSelection.shortDisplayName"))
    }

    @Test func queueAndCustomAskFieldsUseTheSharedRecessedThemeSurface() throws {
        let source = try composerSource()
        let callCount = source.components(separatedBy: ".macComposerAuxiliaryFieldSurface()").count - 1
        #expect(callCount == 2)

        let surface = try sourceSlice(
            named: "private struct MacComposerAuxiliaryFieldSurface: ViewModifier {",
            until: "private extension View",
            in: source
        )
        #expect(surface.contains(".textFieldStyle(.plain)"))
        #expect(surface.contains(".themeRecessedInset"))
        #expect(surface.contains("RoundedRectangle(cornerRadius: 10, style: .continuous)"))

        let queueField = try sourceSlice(
            named: "private func queueMessageField(kind: MessageQueueKind, id: String) -> some View {",
            until: "private func queueRowControls",
            in: source
        )
        let customAnswer = try sourceSlice(
            named: "private func customAnswerField(_ question: AskQuestion) -> some View {",
            until: "private func sendSubmit",
            in: source
        )
        #expect(!queueField.contains(".roundedBorder"))
        #expect(!customAnswer.contains(".roundedBorder"))
    }
}

@Suite("Mac composer field paint")
struct MacComposerFieldPaintTests {
    @Test func idlePlaceholderUsesTertiaryThemeTextLikeIOS() {
        #expect(MacComposerFieldPaint.placeholderRole == .tertiary)
        #expect(MacComposerFieldPaint.valueRole == .primary)
        #expect(MacComposerFieldPaint.placeholderRole != .secondary)
    }
}

@Suite("Mac composer capsule paint")
struct MacComposerCapsulePaintTests {
    @Test func dictationPaintMapsIdleProgressAndRemoteRecordingStates() {
        let idle = MacComposerDictationPaint.presentation(for: .idle)
        #expect(idle.indicator == .comment)
        #expect(idle.content == .microphone)
        #expect(idle.ringOpacity == 0.35)
        #expect(idle.glyphOpacity == 0.75)

        for state in [
            MacComposerDictationController.State.requestingPermission,
            .connecting,
            .stopping,
        ] {
            let progress = MacComposerDictationPaint.presentation(for: state)
            #expect(progress.indicator == .comment)
            #expect(progress.content == .progress)
        }

        let recording = MacComposerDictationPaint.presentation(for: .recording)
        #expect(recording.indicator == .cyan)
        #expect(recording.content == .cloud)
        #expect(recording.ringOpacity == 1)
        #expect(recording.ringLineWidth == 1.5)
    }

    @Test func capsuleUsesLiveThemedElevatedSurface() throws {
        let source = try composerSource()
        let slice = try sourceSlice(
            named: "private var composerCapsule: some View {",
            until: "private var actionRowItems",
            in: source
        )
        #expect(slice.contains(".themedSurface("))
        #expect(slice.contains(".elevatedPanel"))
        #expect(slice.contains("RoundedRectangle(cornerRadius: 20, style: .continuous)"))
        #expect(!slice.contains(".glassEffect("))
        #expect(!slice.contains(".stroke("))
    }

    @Test func stateBarUsesTheSameLiveThemedPanelContract() throws {
        let source = try composerSource()
        let slice = try sourceSlice(
            named: "private var sessionStateBar: some View {",
            until: "private func stateText",
            in: source
        )

        #expect(slice.contains(".themedSurface("))
        #expect(slice.contains(".elevatedPanel"))
        #expect(slice.contains("RoundedRectangle(cornerRadius: 16, style: .continuous)"))
        #expect(!slice.contains(".glassEffect("))
    }

    @Test func dictationChromeUsesNeutralFillAndSemanticStatePaint() throws {
        let source = try composerSource()
        let slice = try sourceSlice(
            named: "private var dictationButton: some View {",
            until: "private var dictationActionLabel",
            in: source
        )

        #expect(slice.contains("MacComposerDictationPaint.presentation(for: dictation.state)"))
        #expect(slice.contains("Circle().fill(.themeBgHighlight)"))
        #expect(slice.contains("case .progress"))
        #expect(slice.contains("case .cloud"))
        #expect(slice.contains("case .microphone"))
    }
}

private func composerSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
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

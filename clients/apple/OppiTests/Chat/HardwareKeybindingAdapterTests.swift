import Testing
import UIKit
@testable import Oppi

@Suite("Hardware keybinding adapter")
@MainActor
struct HardwareKeybindingAdapterTests {
    @Test func iphoneSoftwareKeyboardDoesNotBindOrRegisterVimLetters() {
        let request = HardwareKeybindingAdapter.Request(
            hardwareKeyboardConnected: false,
            userInterfaceIdiom: .phone,
            mode: .vim,
            focus: .timeline,
            hostsComposer: false,
            composerIsFirstResponder: false
        )

        #expect(!HardwareKeybindingAdapter.shouldBind(request))
        #expect(HardwareKeybindingAdapter.registeredChords(for: request).isEmpty)
        #expect(HardwareKeybindingAdapter.action(for: .letter("j"), request: request) == nil)
        #expect(HardwareKeybindingAdapter.action(for: .letter("k"), request: request) == nil)
        #expect(!HardwareKeybindingAdapter.shouldBecomeFirstResponder(request))
    }

    @Test func iphoneSoftwareKeyboardResponderDoesNotExposeVimLetterCommands() {
        let responder = HardwareKeybindingResponder(frame: .zero)
        responder.hardwareKeyboardConnectedOverride = false
        responder.mode = .vim
        responder.focus = .timeline
        responder.composerIsFirstResponder = false

        let inputs = responder.keyCommands?.compactMap(\.input) ?? []
        #expect(!inputs.contains("j"))
        #expect(!inputs.contains("k"))
        #expect(!responder.canBecomeFirstResponder)
    }

    @Test(
        "composer vim letters do not yield a timeline action",
        arguments: KeybindingMode.allCases
    )
    func composerVimLettersProduceNoTimelineAction(_ mode: KeybindingMode) {
        let request = hardwareRequest(mode: mode, focus: .composer)
        for letter: Character in ["j", "k", "h", "l", "e", "g", "i"] {
            let action = HardwareKeybindingAdapter.action(for: .letter(letter), request: request)
            #expect(action == nil, "\(mode.rawValue) composer \(letter)")
            #expect(!isTimelineAction(action), "\(mode.rawValue) composer \(letter)")
            #expect(
                action == KeybindingCatalog.action(for: .letter(letter), mode: mode, focus: .composer),
                "\(mode.rawValue) composer \(letter) must share the catalog"
            )
        }
        #expect(HardwareKeybindingAdapter.registeredChords(for: request).isEmpty)
    }

    @Test(
        "Cmd-Return is composer-owned send when the composer is focused",
        arguments: KeybindingMode.allCases
    )
    func composerCommandReturnIsSendAndNotConsumed(_ mode: KeybindingMode) {
        let request = hardwareRequest(mode: mode, focus: .composer)
        let action = HardwareKeybindingAdapter.action(for: .commandReturn, request: request)
        #expect(action == .send, "\(mode.rawValue)")
        #expect(action != .openViewer, "\(mode.rawValue)")
        #expect(!HardwareKeybindingAdapter.consumes(action), "\(mode.rawValue)")
        #expect(
            action == KeybindingCatalog.action(for: .commandReturn, mode: mode, focus: .composer),
            "\(mode.rawValue) must share the catalog"
        )
        #expect(HardwareKeybindingAdapter.registeredChords(for: request).isEmpty)
    }

    @Test func timelineVimJKHitCatalogNextAndPreviousToolRow() {
        let request = hardwareRequest(mode: .vim, focus: .timeline, idiom: .pad)

        let next = HardwareKeybindingAdapter.action(for: .letter("j"), request: request)
        #expect(next == .nextToolRow)
        #expect(
            next == KeybindingCatalog.action(for: .letter("j"), mode: .vim, focus: .timeline)
        )

        let previous = HardwareKeybindingAdapter.action(for: .letter("k"), request: request)
        #expect(previous == .previousToolRow)
        #expect(
            previous == KeybindingCatalog.action(for: .letter("k"), mode: .vim, focus: .timeline)
        )

        let chords = HardwareKeybindingAdapter.registeredChords(for: request)
        #expect(chords.contains(.letter("j")))
        #expect(chords.contains(.letter("k")))
        #expect(
            chords == KeybindingCatalog.boundChords(mode: .vim, focus: .timeline).filter {
                HardwareKeybindingAdapter.consumes(
                    KeybindingCatalog.action(for: $0, mode: .vim, focus: .timeline)
                )
            }
        )
    }

    @Test func iphoneHardwareKeyboardUsesTheSameCatalogAsIPad() {
        let phone = hardwareRequest(mode: .vim, focus: .timeline, idiom: .phone)
        let pad = hardwareRequest(mode: .vim, focus: .timeline, idiom: .pad)

        #expect(HardwareKeybindingAdapter.shouldBind(phone))
        #expect(HardwareKeybindingAdapter.registeredChords(for: phone).contains(.letter("j")))
        #expect(
            HardwareKeybindingAdapter.action(for: .letter("j"), request: phone)
                == HardwareKeybindingAdapter.action(for: .letter("j"), request: pad)
        )
        #expect(
            HardwareKeybindingAdapter.action(for: .downArrow, request: phone)
                == KeybindingCatalog.action(for: .downArrow, mode: .macDefault, focus: .timeline)
        )
    }

    @Test func composerHostingResponderNeverRegistersVimLetters() {
        let request = HardwareKeybindingAdapter.Request(
            hardwareKeyboardConnected: true,
            userInterfaceIdiom: .pad,
            mode: .vim,
            focus: .timeline,
            hostsComposer: true,
            composerIsFirstResponder: false
        )

        let inputs = Set(
            HardwareKeybindingAdapter.registeredChords(for: request).compactMap { chord -> String? in
                if case .character(let character) = chord.key { return String(character) }
                return nil
            }
        )
        #expect(!inputs.contains("j"))
        #expect(!inputs.contains("k"))
        #expect(!inputs.contains("h"))
        #expect(!inputs.contains("l"))
        #expect(HardwareKeybindingAdapter.action(for: .letter("j"), request: request) == nil)
        #expect(HardwareKeybindingAdapter.action(for: .downArrow, request: request) == .nextToolRow)
    }

    @Test func registeredChordsAskTheCatalogInsteadOfALocalVimList() {
        let vim = hardwareRequest(mode: .vim, focus: .timeline)
        let mac = hardwareRequest(mode: .macDefault, focus: .timeline)

        let vimChords = HardwareKeybindingAdapter.registeredChords(for: vim)
        let macChords = HardwareKeybindingAdapter.registeredChords(for: mac)
        #expect(vimChords.contains(.letter("j")))
        #expect(vimChords.contains(.letter("k")))
        #expect(!macChords.contains(.letter("j")))
        #expect(macChords.contains(.downArrow))

        for chord in vimChords {
            #expect(
                KeybindingCatalog.action(for: chord, mode: .vim, focus: .timeline) != nil,
                "registered chord must be catalog-bound"
            )
        }
        for chord in macChords {
            #expect(
                KeybindingCatalog.action(for: chord, mode: .macDefault, focus: .timeline) != nil,
                "registered chord must be catalog-bound"
            )
        }
    }

    @Test func macDefaultKeepsComposerLetterKeys() {
        let request = hardwareRequest(mode: .macDefault, focus: .composer)
        #expect(HardwareKeybindingAdapter.action(for: .letter("j"), request: request) == nil)
        #expect(HardwareKeybindingAdapter.action(for: .letter("a"), request: request) == nil)
        #expect(HardwareKeybindingAdapter.registeredChords(for: request).isEmpty)
    }

    @Test func uiKeyCommandMappingSharesKeybindingEventMap() {
        let mappedJ = KeybindingEventMap.chord(
            characters: "j",
            isUpArrow: false,
            isDownArrow: false,
            isLeftArrow: false,
            isRightArrow: false,
            isReturn: false,
            isEscape: false,
            isTab: false,
            command: false,
            shift: false,
            option: false,
            control: false
        )
        #expect(mappedJ == .letter("j"))
        #expect(HardwareKeybindingAdapter.chord(input: "j", modifierFlags: []) == mappedJ)

        let mappedDown = KeybindingEventMap.chord(
            characters: "",
            isUpArrow: false,
            isDownArrow: true,
            isLeftArrow: false,
            isRightArrow: false,
            isReturn: false,
            isEscape: false,
            isTab: false,
            command: false,
            shift: false,
            option: false,
            control: false
        )
        #expect(mappedDown == .downArrow)
        #expect(
            HardwareKeybindingAdapter.chord(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: []
            ) == mappedDown
        )

        let mappedSend = HardwareKeybindingAdapter.chord(
            input: "\r",
            modifierFlags: .command
        )
        #expect(mappedSend == .commandReturn)
        #expect(
            KeybindingCatalog.action(for: mappedSend!, mode: .vim, focus: .composer) == .send
        )
        #expect(
            KeybindingCatalog.action(for: mappedJ!, mode: .vim, focus: .timeline) == .nextToolRow
        )
        #expect(
            KeybindingCatalog.action(for: mappedJ!, mode: .macDefault, focus: .timeline) == nil
        )
    }

    @Test func timelineResponderRegistersVimLettersOnlyWithHardwareKeyboard() {
        let responder = HardwareKeybindingResponder(frame: .zero)
        responder.hardwareKeyboardConnectedOverride = true
        responder.mode = .vim
        responder.focus = .timeline
        responder.composerIsFirstResponder = false

        let inputs = Set(responder.keyCommands?.compactMap(\.input) ?? [])
        #expect(inputs.contains("j"))
        #expect(inputs.contains("k"))
        #expect(responder.hostsComposer == false)
        #expect(responder.canBecomeFirstResponder)

        responder.composerIsFirstResponder = true
        let composerInputs = responder.keyCommands?.compactMap(\.input) ?? []
        #expect(!composerInputs.contains("j"))
        #expect(!responder.canBecomeFirstResponder)
    }
}

private func hardwareRequest(
    mode: KeybindingMode,
    focus: KeybindingFocus,
    idiom: UIUserInterfaceIdiom = .pad
) -> HardwareKeybindingAdapter.Request {
    HardwareKeybindingAdapter.Request(
        hardwareKeyboardConnected: true,
        userInterfaceIdiom: idiom,
        mode: mode,
        focus: focus,
        hostsComposer: false,
        composerIsFirstResponder: focus == .composer
    )
}

private func isTimelineAction(_ action: KeybindingAction?) -> Bool {
    switch action {
    case .nextToolRow, .previousToolRow, .collapse, .expand, .toggleExpanded,
         .openViewer, .moveToTop, .moveToBottom:
        return true
    case .focusComposer, .closeViewer, .send, nil:
        return false
    }
}

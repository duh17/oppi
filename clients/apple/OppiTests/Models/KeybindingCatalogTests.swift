import Foundation
import Testing
@testable import Oppi

@Suite("KeybindingCatalog")
struct KeybindingCatalogTests {
    struct CatalogRow: Sendable {
        let name: String
        let mode: KeybindingMode
        let focus: KeybindingFocus
        let chord: KeybindingChord
        let expected: KeybindingAction?
    }

    @Test(
        "composer focus never yields a timeline action for vim letters",
        arguments: Self.composerVimLetterRows
    )
    func composerVimLettersProduceNoTimelineAction(_ row: CatalogRow) {
        let action = KeybindingCatalog.action(for: row.chord, mode: row.mode, focus: row.focus)
        #expect(action == row.expected, "\(row.name)")
        #expect(!isTimelineAction(action), "\(row.name)")
    }

    @Test(
        "Cmd-Return is composer-owned send when the composer is focused",
        arguments: Self.composerCommandReturnRows
    )
    func composerCommandReturnIsNotConsumedByTimeline(_ row: CatalogRow) {
        let action = KeybindingCatalog.action(for: row.chord, mode: row.mode, focus: row.focus)
        #expect(action == .send, "\(row.name)")
        #expect(action != .openViewer, "\(row.name)")
        #expect(!isTimelineAction(action), "\(row.name)")
    }

    @Test(arguments: Self.timelineCatalogRows)
    func resolvesTimelineCatalog(_ row: CatalogRow) {
        let action = KeybindingCatalog.action(for: row.chord, mode: row.mode, focus: row.focus)
        #expect(action == row.expected, "\(row.name)")
    }

    @Test(arguments: Self.macDefaultUnmodifiedLetterRows)
    func macDefaultNeverConsumesUnmodifiedLetters(_ row: CatalogRow) {
        let action = KeybindingCatalog.action(for: row.chord, mode: row.mode, focus: row.focus)
        #expect(action == nil, "\(row.name)")
    }

    @Test(arguments: Self.viewerCatalogRows)
    func resolvesViewerCatalog(_ row: CatalogRow) {
        let action = KeybindingCatalog.action(for: row.chord, mode: row.mode, focus: row.focus)
        #expect(action == row.expected, "\(row.name)")
    }
}

@Suite("KeybindingPreferenceStore")
@MainActor
struct KeybindingPreferenceStoreTests {
    @Test func preferenceKeyIsNamedAndDefaultsToMacDefault() throws {
        let defaults = try makeDefaults()
        let store = KeybindingPreferenceStore(defaults: defaults)

        #expect(KeybindingMode.preferenceKey == "oppi.keybinding.mode")
        #expect(defaults.object(forKey: KeybindingMode.preferenceKey) == nil)
        #expect(store.mode == .macDefault)
        #expect(KeybindingMode.resolved(nil) == .macDefault)
    }

    @Test func unknownStoredValuesFallBackToMacDefault() throws {
        let defaults = try makeDefaults()
        let store = KeybindingPreferenceStore(defaults: defaults)

        defaults.set("helix", forKey: KeybindingMode.preferenceKey)
        #expect(store.mode == .macDefault)
        #expect(KeybindingMode.resolved("helix") == .macDefault)
        #expect(KeybindingMode.resolved("") == .macDefault)
        #expect(KeybindingMode.resolved("macDefault") == .macDefault)
        #expect(KeybindingMode.resolved("vim") == .vim)
        #expect(KeybindingMode.resolved("emacs") == .emacs)
    }

    @Test func persistsChosenMode() throws {
        let defaults = try makeDefaults()
        let store = KeybindingPreferenceStore(defaults: defaults)

        store.mode = .vim
        #expect(defaults.string(forKey: KeybindingMode.preferenceKey) == "vim")
        #expect(store.mode == .vim)

        let reloaded = KeybindingPreferenceStore(defaults: defaults)
        #expect(reloaded.mode == .vim)

        store.mode = .macDefault
        #expect(defaults.string(forKey: KeybindingMode.preferenceKey) == "macDefault")
        #expect(reloaded.mode == .macDefault)
    }
}

extension KeybindingCatalogTests.CatalogRow: CustomTestStringConvertible {
    var testDescription: String { name }
}

extension KeybindingCatalogTests {
    fileprivate static var composerVimLetterRows: [CatalogRow] {
        KeybindingMode.allCases.flatMap { mode in
            vimLetters.map { letter in
                CatalogRow(
                    name: "\(mode.rawValue) composer \(letter)",
                    mode: mode,
                    focus: .composer,
                    chord: .letter(letter),
                    expected: nil
                )
            }
        }
    }

    fileprivate static var composerCommandReturnRows: [CatalogRow] {
        KeybindingMode.allCases.map { mode in
            CatalogRow(
                name: "\(mode.rawValue) composer Cmd-Return",
                mode: mode,
                focus: .composer,
                chord: .commandReturn,
                expected: .send
            )
        }
    }

    fileprivate static var timelineCatalogRows: [CatalogRow] {
        macDefaultTimelineRows + vimTimelineRows + emacsTimelineRows + timelineOpenViewerRows
    }

    fileprivate static var macDefaultTimelineRows: [CatalogRow] {
        [
            CatalogRow(
                name: "macDefault timeline up",
                mode: .macDefault,
                focus: .timeline,
                chord: .upArrow,
                expected: .previousToolRow
            ),
            CatalogRow(
                name: "macDefault timeline down",
                mode: .macDefault,
                focus: .timeline,
                chord: .downArrow,
                expected: .nextToolRow
            ),
            CatalogRow(
                name: "macDefault timeline left",
                mode: .macDefault,
                focus: .timeline,
                chord: .leftArrow,
                expected: .collapse
            ),
            CatalogRow(
                name: "macDefault timeline right",
                mode: .macDefault,
                focus: .timeline,
                chord: .rightArrow,
                expected: .expand
            ),
            CatalogRow(
                name: "macDefault timeline Return",
                mode: .macDefault,
                focus: .timeline,
                chord: .return,
                expected: .openViewer
            ),
            CatalogRow(
                name: "macDefault timeline Esc",
                mode: .macDefault,
                focus: .timeline,
                chord: .escape,
                expected: .closeViewer
            ),
            CatalogRow(
                name: "macDefault timeline Cmd-Up",
                mode: .macDefault,
                focus: .timeline,
                chord: KeybindingChord(key: .upArrow, command: true),
                expected: .moveToTop
            ),
            CatalogRow(
                name: "macDefault timeline Cmd-Down",
                mode: .macDefault,
                focus: .timeline,
                chord: KeybindingChord(key: .downArrow, command: true),
                expected: .moveToBottom
            ),
            CatalogRow(
                name: "macDefault timeline Control-N is not bound",
                mode: .macDefault,
                focus: .timeline,
                chord: .control("n"),
                expected: nil
            ),
        ]
    }

    fileprivate static var emacsTimelineRows: [CatalogRow] {
        let rows: [(String, KeybindingChord, KeybindingAction?)] = [
            ("C-n", .control("n"), .nextToolRow),
            ("C-p", .control("p"), .previousToolRow),
            ("C-f", .control("f"), .expand),
            ("C-b", .control("b"), .collapse),
            ("Tab folds", .tab, .toggleExpanded),
            ("M-<", KeybindingChord(key: .character("<"), shift: true, option: true), .moveToTop),
            ("M->", KeybindingChord(key: .character(">"), shift: true, option: true), .moveToBottom),
            ("C-g", .control("g"), .closeViewer),
            ("C-o", .control("o"), .focusComposer),
            ("arrows still navigate", .downArrow, .nextToolRow),
            ("bare n types nothing", .letter("n"), nil),
            ("bare j is not vim", .letter("j"), nil),
        ]
        return rows.map { name, chord, expected in
            CatalogRow(name: "emacs timeline \(name)", mode: .emacs, focus: .timeline, chord: chord, expected: expected)
        }
    }

    fileprivate static var vimTimelineRows: [CatalogRow] {
        [
            CatalogRow(
                name: "vim timeline j",
                mode: .vim,
                focus: .timeline,
                chord: .letter("j"),
                expected: .nextToolRow
            ),
            CatalogRow(
                name: "vim timeline k",
                mode: .vim,
                focus: .timeline,
                chord: .letter("k"),
                expected: .previousToolRow
            ),
            CatalogRow(
                name: "vim timeline h",
                mode: .vim,
                focus: .timeline,
                chord: .letter("h"),
                expected: .collapse
            ),
            CatalogRow(
                name: "vim timeline l",
                mode: .vim,
                focus: .timeline,
                chord: .letter("l"),
                expected: .expand
            ),
            CatalogRow(
                name: "vim timeline e",
                mode: .vim,
                focus: .timeline,
                chord: .letter("e"),
                expected: .toggleExpanded
            ),
            CatalogRow(
                name: "vim timeline Enter",
                mode: .vim,
                focus: .timeline,
                chord: .return,
                expected: .openViewer
            ),
            CatalogRow(
                name: "vim timeline g",
                mode: .vim,
                focus: .timeline,
                chord: .letter("g"),
                expected: .moveToTop
            ),
            CatalogRow(
                name: "vim timeline G",
                mode: .vim,
                focus: .timeline,
                chord: .letter("G"),
                expected: .moveToBottom
            ),
            CatalogRow(
                name: "vim timeline Tab",
                mode: .vim,
                focus: .timeline,
                chord: .tab,
                expected: .focusComposer
            ),
            CatalogRow(
                name: "vim timeline i",
                mode: .vim,
                focus: .timeline,
                chord: .letter("i"),
                expected: .focusComposer
            ),
            CatalogRow(
                name: "vim timeline up still navigates",
                mode: .vim,
                focus: .timeline,
                chord: .upArrow,
                expected: .previousToolRow
            ),
            CatalogRow(
                name: "vim timeline Esc",
                mode: .vim,
                focus: .timeline,
                chord: .escape,
                expected: .closeViewer
            ),
        ]
    }

    fileprivate static var timelineOpenViewerRows: [CatalogRow] {
        KeybindingMode.allCases.flatMap { mode in
            [
                CatalogRow(
                    name: "\(mode.rawValue) timeline Cmd-Return opens viewer",
                    mode: mode,
                    focus: .timeline,
                    chord: .commandReturn,
                    expected: .openViewer
                ),
                CatalogRow(
                    name: "\(mode.rawValue) timeline Return opens viewer",
                    mode: mode,
                    focus: .timeline,
                    chord: .return,
                    expected: .openViewer
                ),
            ]
        }
    }

    fileprivate static var macDefaultUnmodifiedLetterRows: [CatalogRow] {
        KeybindingFocus.allCases.flatMap { focus in
            (vimLetters + extraMacDefaultLetters).map { letter in
                CatalogRow(
                    name: "macDefault \(focus.rawValue) letter \(letter)",
                    mode: .macDefault,
                    focus: focus,
                    chord: .letter(letter),
                    expected: nil
                )
            }
        }
    }

    fileprivate static var viewerCatalogRows: [CatalogRow] {
        KeybindingMode.allCases.map { mode in
            CatalogRow(
                name: "\(mode.rawValue) viewer Esc",
                mode: mode,
                focus: .viewer,
                chord: .escape,
                expected: .closeViewer
            )
        } + [
            CatalogRow(name: "emacs viewer C-g", mode: .emacs, focus: .viewer, chord: .control("g"), expected: .closeViewer),
            CatalogRow(name: "vim viewer C-g", mode: .vim, focus: .viewer, chord: .control("g"), expected: nil),
        ]
    }

    fileprivate static let vimLetters: [Character] = ["j", "k", "h", "l", "e", "g", "i"]
    fileprivate static let extraMacDefaultLetters: [Character] = ["a", "x", "G"]
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

private func makeDefaults() throws -> UserDefaults {
    let suiteName = "KeybindingPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

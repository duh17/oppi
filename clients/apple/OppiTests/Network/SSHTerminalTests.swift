import Foundation
import GhosttyVt
import Synchronization
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

@Suite("Interactive SSH terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalTests {
    @Test func remoteCopyIsWriteOnlyStandardClipboardText() throws {
        var sent = [Data]()
        var copies = [String]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.copied = { copies.append($0) }
        // Reads, the X11 selection/primary buffers, clearing, and non-UTF-8 bytes.
        engine.receive(Data(("\u{1b}]52;c;?\u{7}\u{1b}]52;p;cmVtb3Rl\u{7}\u{1b}]52;s;cmVtb3Rl\u{7}"
            + "\u{1b}]52;c;\u{7}\u{1b}]52;c;/w==\u{7}\u{1b}]5522;type=read\u{7}").utf8))
        #expect(copies.isEmpty)
        #expect(sent.isEmpty)
        // Herdr forwards a pane's copy as `ESC ] 52 ; c ; base64 BEL`. Only the
        // newest copy of one write is delivered.
        engine.receive(Data("\u{1b}]52;c;b25l\u{7}\u{1b}]52;c;aMOpbGxv\u{1b}\\".utf8))
        #expect(copies == ["héllo"])
        #expect(sent.isEmpty)
        engine.close()
        engine.receive(Data("\u{1b}]52;c;b25l\u{7}".utf8))
        #expect(copies == ["héllo"])
    }

    @Test func remoteCopyLandsOnTheDeviceClipboardOnlyWhileConnectedAndViewed() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        // Off screen, or Oppi not in front: the write is dropped.
        UIPasteboard.general.string = "local-only"
        channel.event(.data(Data("\u{1b}]52;c;aMOpbGxv\u{7}".utf8)))
        #expect(UIPasteboard.general.string == "local-only")
        #expect(channel.copies == 0)
        channel.isViewed = true
        UIPasteboard.general.string = "local-only"
        channel.event(.data(Data("\u{1b}]52;c;aMOpbGxv\u{7}".utf8)))
        #expect(UIPasteboard.general.string == "héllo")
        #expect(channel.copies == 1)
        #expect(channel.lastCopyLength == 5)
        channel.close(reason: "done")
        UIPasteboard.general.string = "local-only"
        channel.event(.data(Data("\u{1b}]52;c;b25l\u{7}".utf8)))
        #expect(UIPasteboard.general.string == "local-only")
        #expect(channel.copies == 1)
    }

    /// The path stream does not end when its consumer is cancelled; the watch
    /// must finish it, or a closed terminal's watcher (and its monitor) lives on.
    @Test func cancellingTheNetworkWatchEndsIt() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let watch = Task { await channel.watchNetwork() }
        try await Task.sleep(for: .milliseconds(100))
        watch.cancel()
        await watch.value
        channel.close(reason: "done")
    }

    @Test func statusAndDeviceRepliesReachTheSamePTYSinkInOrder() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(Data("\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[=c\u{1b}[>q".utf8))
        #expect(String(decoding: sent, as: UTF8.self) == "\u{1b}[1;1R\u{1b}[?62;22c\u{1b}[>1;0;0c\u{1b}P!|00000000\u{1b}\\\u{1b}P>|Oppi\u{1b}\\")
    }

    @Test func titleIsDisplayOnlySanitizedAndCapped() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data(("\u{1b}]2;hello\t\u{202e}" + String(repeating: "x", count: 150) + "\u{7}").utf8))
        #expect(engine.title == "hello" + String(repeating: "x", count: 115))
    }

    @Test func closedEngineDropsLateRepliesAndInput() throws {
        var sent = [Data]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.close()
        engine.receive(Data("\u{1b}[6n\u{1b}[c".utf8))
        #expect(sent.isEmpty)
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)).isEmpty)
        #expect(throws: SSHTerminalError.self) { try engine.paste("late", confirmed: true) }
    }

    @Test func controlAndNavigationKeysUseTerminalModes() throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)) == Data([3]))
        #expect(engine.key(GHOSTTY_KEY_ESCAPE) == Data([27]))
        #expect(engine.key(GHOSTTY_KEY_TAB) == Data([9]))
        #expect(engine.key(GHOSTTY_KEY_ENTER) == Data([13]))
        #expect(engine.key(GHOSTTY_KEY_BACKSPACE) == Data([127]))
        for (key, letter) in [(GHOSTTY_KEY_ARROW_UP, "A"), (GHOSTTY_KEY_ARROW_DOWN, "B"),
                              (GHOSTTY_KEY_ARROW_RIGHT, "C"), (GHOSTTY_KEY_ARROW_LEFT, "D")] {
            #expect(engine.key(key) == Data("\u{1b}[\(letter)".utf8))
        }
        engine.receive(Data("\u{1b}[?1h".utf8))
        for (key, letter) in [(GHOSTTY_KEY_ARROW_UP, "A"), (GHOSTTY_KEY_ARROW_DOWN, "B"),
                              (GHOSTTY_KEY_ARROW_RIGHT, "C"), (GHOSTTY_KEY_ARROW_LEFT, "D")] {
            #expect(engine.key(key) == Data("\u{1b}O\(letter)".utf8))
        }
    }

    @Test func pasteRequiresConsentAndStripsControlInjection() throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(SSHTerminalEngine.pasteIsSafe("plain"))
        #expect(!SSHTerminalEngine.pasteIsSafe("echo a\necho b"))
        #expect(!SSHTerminalEngine.pasteIsSafe("\u{1b}[201~bad"))
        #expect(throws: SSHTerminalError.self) { try engine.paste("echo a\necho b", confirmed: false) }
        #expect(try engine.paste("a\nb\u{1b}c", confirmed: true) == Data("a\rb c".utf8))
    }

    @Test func pasteHonorsBracketedModeAndSizeLimit() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}[?2004h".utf8))
        #expect(try engine.paste("a\nb", confirmed: true) == Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        #expect(try engine.paste("\u{1b}[201~bad", confirmed: true) == Data("\u{1b}[200~ [201~bad\u{1b}[201~".utf8))
        #expect(throws: SSHTerminalError.self) {
            try engine.paste(String(repeating: "x", count: SSHTerminalEngine.maximumPasteBytes + 1), confirmed: true)
        }
    }

    @Test func renderCopiesUnicodeColorsAndAlternateScreen() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        engine.receive(Data("\u{1b}[31m中e\u{301}".utf8))
        let original = engine.frame()
        #expect(original.rows[0][0].text == "中")
        #expect(original.rows[0][0].width == 2)
        #expect(original.rows[0][1].width == 0)
        #expect(original.rows[0][2].text == "e\u{301}")
        #expect(original.rows[0][0].foreground.r > original.rows[0][0].foreground.g)
        engine.receive(Data("\u{1b}[?1049h\u{1b}[Halt".utf8))
        #expect(engine.frame().rows[0][0].text == "a")
        #expect(original.rows[0][0].text == "中") // copied frame remains valid after mutation
        engine.receive(Data("\u{1b}[?1049l".utf8))
        #expect(engine.frame().rows[0][0].text == "中")
    }

    @Test func draggingHistoryDetachesUntilExplicitLive() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 2)) { _ in }
        engine.receive(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        engine.scroll(rows: -2)
        let reading = engine.frame().rows[0].map(\.text).joined()
        engine.receive(Data("\r\nfive\r\nsix".utf8))
        #expect(!engine.following)
        #expect(engine.frame().rows[0].map(\.text).joined() == reading)
        engine.backToLive()
        #expect(engine.following)
        #expect(engine.frame().rows[1].map(\.text).joined() == "six")
    }

    @Test func synchronizedOutputHoldsOnlyPaintNotReplies() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(Data("old\u{1b}[?2026h\rnew\u{1b}[6n".utf8))
        #expect(engine.frame().rows[0].prefix(3).map(\.text).joined() == "old")
        #expect(sent == Data("\u{1b}[1;4R".utf8))
        engine.receive(Data("\u{1b}[?2026l".utf8))
        #expect(engine.frame().rows[0].prefix(3).map(\.text).joined() == "new")
    }

    @Test func resizeUpdatesGridAndRemotePTYTogether() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let target = SSHTerminalGeometry(columns: 42, rows: 13, cellWidth: 18, cellHeight: 34)
        channel.resize(.init(columns: 20, rows: 8))
        channel.resize(target)
        var resizes = fixture.resizes.makeAsyncIterator()
        #expect(await resizes.next() == target)
        let frame = channel.engine.frame()
        #expect(frame.rows.count == 13)
        #expect(frame.rows[0].count == 42)
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.resize(target)
        engine.receive(Data("\u{1b}[18t\u{1b}[16t".utf8))
        #expect(sent == Data("\u{1b}[8;13;42t\u{1b}[6;34;18t".utf8))
        channel.close(reason: "done")
    }

    @Test func aSizeTheRemoteShellAlreadyHasIsNotSentAgain() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let first = SSHTerminalGeometry(columns: 44, rows: 45, cellWidth: 18, cellHeight: 34)
        let second = SSHTerminalGeometry(columns: 44, rows: 28, cellWidth: 18, cellHeight: 34)
        var resizes = fixture.resizes.makeAsyncIterator()
        channel.resize(first)
        #expect(await resizes.next() == first)
        channel.resize(first)
        try await Task.sleep(for: .milliseconds(200))
        channel.resize(second)
        #expect(await resizes.next() == second, "the repeat of \(first) must not reach the shell")
        channel.close(reason: "done")
    }

    /// A keyboard transition holds layout resizes and reports the settled size again
    /// when it releases. A repeat is not a change: resizing the engine on one forces a
    /// full rebuild and bumps `changeCount`, so the grid repaints and every reader of
    /// a picture moves on a frame where nothing changed.
    @Test func aRepeatedSizeDoesNotResizeTheEngineAgain() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let size = SSHTerminalGeometry(columns: 44, rows: 28, cellWidth: 18, cellHeight: 34)
        var resizes = fixture.resizes.makeAsyncIterator()
        channel.resize(size)
        #expect(await resizes.next() == size)
        let settled = channel.engine.changeCount
        channel.resize(size)
        try await Task.sleep(for: .milliseconds(200))
        #expect(channel.engine.changeCount == settled, "a repeated size must not repaint the grid")
        channel.close(reason: "done")
    }

    @Test func backpressurePreservesInputOrderWithinOneSession() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL))
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        #expect(await fixture.sentBytes.isEmpty)
        channel.event(.writabilityChanged(true))
        var bytes = fixture.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data([3]))
        #expect(await bytes.next() == Data("\u{1b}[1;1R".utf8))
        channel.close(reason: "done")
    }

    @Test func newerWritableEventWinsOverAnOlderSendRejection() async throws {
        let fixture = TerminalConnectionFixture(suspendFirstSend: true)
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.send(Data("a".utf8))
        var attempts = fixture.attempts.makeAsyncIterator()
        #expect(await attempts.next() == Data("a".utf8))
        // The transport rejected the first attempt while not writable, but
        // resumes before its async rejection reaches the main-actor consumer.
        channel.event(.writabilityChanged(false))
        channel.event(.writabilityChanged(true))
        await fixture.rejectSuspendedSend()
        let received = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var bytes = fixture.bytes.makeAsyncIterator()
                return await bytes.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2)) // bounded failure oracle, not synchronization
                return nil
            }
            // TaskGroup<Data?>.next() is Data??; ?? nil keeps the Data? race result.
            // swiftlint:disable:next redundant_nil_coalescing
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(received == Data("a".utf8))
        #expect(await fixture.sentBytes == Data("a".utf8))
        channel.close(reason: "done")
    }

    @Test func disconnectClearsBufferedInputAndLateOutputCannotReplay() async throws {
        let first = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(first)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_A, text: "a")
        channel.event(.closed)
        channel.key(GHOSTTY_KEY_C, text: "c")
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        channel.event(.writabilityChanged(true))
        #expect(channel.inputNotice.contains("Not sent"))
        #expect(!channel.connected)
        #expect(await first.sentBytes.isEmpty)
        let second = TerminalConnectionFixture()
        let fresh = try SSHTerminalChannel()
        fresh.opened(second)
        fresh.key(GHOSTTY_KEY_B, text: "b")
        var bytes = second.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data("b".utf8))
        #expect(await second.sentBytes == Data("b".utf8))
        fresh.close(reason: "done")
    }

    @Test func carriageReturnAndOtherControlPastesNeedConsentAndWriteNothing() async throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(!SSHTerminalEngine.pasteNeedsConfirmation("plain\ttabbed text"))
        for text in ["echo hi\r", "cd /tmp\rrm important-file\r", "a\u{3}b", "a\u{7f}b", "a\u{1b}[31mb"] {
            #expect(SSHTerminalEngine.pasteNeedsConfirmation(text))
            #expect(throws: SSHTerminalError.unsafePaste) { try engine.paste(text, confirmed: false) }
        }
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        #expect(throws: SSHTerminalError.unsafePaste) { try channel.paste("echo hi\r") }
        #expect(await fixture.sentBytes.isEmpty)
        try channel.paste("echo hi\r", confirmed: true)
        var bytes = fixture.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data("echo hi\r".utf8))
        channel.close(reason: "done")
    }

    @Test func modifierLatchAppliesToTheNextKeyOnly() throws {
        let engine = try SSHTerminalEngine { _ in }
        for (modifier, expected) in [(GhosttyMods(GHOSTTY_MODS_CTRL), Data([3])),
                                     (GhosttyMods(GHOSTTY_MODS_ALT), Data("\u{1b}c".utf8))] {
            var latch = SSHTerminalModifierLatch()
            #expect(latch.take() == 0)
            latch.toggle(modifier)
            #expect(latch.isArmed(modifier))
            #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: latch.take()) == expected)
            #expect(!latch.isArmed(modifier))
            #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: latch.take()) == Data("c".utf8))
            latch.toggle(modifier)
            latch.toggle(modifier)
            #expect(latch.take() == 0) // a second tap turns it off again
        }
        var combined = SSHTerminalModifierLatch()
        combined.toggle(GhosttyMods(GHOSTTY_MODS_CTRL))
        combined.toggle(GhosttyMods(GHOSTTY_MODS_ALT))
        #expect(combined.take() == GhosttyMods(GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT))
        #expect(combined.take() == 0)
    }

    @Test func fixedKeysOfferBaseModifiersNotAnInterruptChord() throws {
        let fixed = SSHTerminalKeymap.fixed
        #expect(Array(fixed.prefix(3).map(\.label)) == ["Esc", "Ctrl", "Alt"])
        #expect(!fixed.contains { $0.label == "^C" })
        #expect(!fixed.contains { $0.stroke?.key == GHOSTTY_KEY_C })
        #expect(fixed.first?.stroke?.key == GHOSTTY_KEY_ESCAPE)
        #expect(fixed.first { $0.label == "Ctrl" }?.modifier == GhosttyMods(GHOSTTY_MODS_CTRL))
        #expect(fixed.first { $0.label == "Alt" }?.modifier == GhosttyMods(GHOSTTY_MODS_ALT))
        #expect(fixed.compactMap(\.stroke).filter { SSHTerminalArrowRepeat.isArrow($0.key) }.count == 4)
        // A program may bind Ctrl-C, but its action remains named, not a base chord.
        let pi = try #require(SSHTerminalKeymap.profile(for: "pi"))
        let actions = SSHTerminalKeymap.actions(for: pi, userFile: #"{"app.interrupt":"ctrl+c"}"#)
        #expect(actions.first?.title == "Stop")
        #expect(SSHTerminalKeymap.fixed.map(\.label).prefix(3) == ["Esc", "Ctrl", "Alt"])
    }

    @Test func composerPagesKeepExitChordsOffTheFirstPage() throws {
        func pages(_ program: String, file: String? = nil) throws -> [SSHTerminalKeymap.ComposerPage] {
            let profile = try #require(SSHTerminalKeymap.profile(for: program))
            return SSHTerminalKeymap.composerPages(for: profile, userFile: file)
        }
        let pi = try pages("pi")
        #expect(pi.map(\.title) == ["Agent", "Move", "Exit"])
        #expect(pi[0].items.map(\.label) == ["Thinking", "Cycle", "Model", "Tools"])
        #expect(pi[0].items.map(\.hint) == ["\u{21E7}Tab", "\u{21E7}Tab", "^L", "^O"])
        #expect(pi[1].items.map(\.label) == ["←", "↓", "↑", "→"])
        #expect(pi[1].items.allSatisfy { $0.kind == .arrow })
        #expect(pi[2].items.map(\.label) == ["Esc", "Tab", "^C", "^D"])
        #expect(pi[2].items.allSatisfy { $0.kind == .send && $0.strokes.count == 1 })
        #expect(pi[0].items.contains { $0.label == "^C" || $0.label == "Esc" } == false)
        #expect(pi[1].items.contains { $0.label == "^C" } == false)

        let interrupt = try #require(pi[2].items.first { $0.id == "ctrl-c" }?.strokes.first)
        #expect(interrupt.key == GHOSTTY_KEY_C)
        #expect(interrupt.modifiers == GhosttyMods(GHOSTTY_MODS_CTRL))
        #expect(pi[2].items.first { $0.id == "ctrl-c" }?.accessibilityLabel == "Control C")

        // A program interrupt bound to Ctrl+C stays off the agent page.
        let rebound = try pages("pi", file: #"{"app.interrupt":"ctrl+c"}"#)
        #expect(rebound[0].items.contains { $0.label == "Stop" || $0.hint == "^C" } == false)
        #expect(rebound[2].items.map(\.id) == ["escape", "tab", "ctrl-c", "ctrl-d"])

        // A safe label must not hide an exit chord. Those slots are omitted, not retargeted.
        let modelInterrupt = try pages("pi", file: #"{"app.model.select":"ctrl+c"}"#)
        #expect(modelInterrupt[0].items.contains { $0.id == "model" || $0.hint == "^C" } == false)
        let thinkingEof = try pages("pi", file: #"{"app.thinking.cycle":"ctrl+d"}"#)
        #expect(thinkingEof[0].items.contains { $0.id == "thinking" || $0.hint == "^D" } == false)
        let cycleInterrupt = """
        {"bindings":[{"context":"Chat","bindings":{"shift+tab":null,"ctrl+c":"chat:cycleMode"}}]}
        """
        let claudeCycle = try pages("claude", file: cycleInterrupt)
        #expect(claudeCycle[0].items.contains { $0.id == "cycle" || $0.hint == "^C" } == false)

        let claude = try pages("claude")
        #expect(claude[0].items.map(\.label).prefix(3) == ["Thinking", "Cycle", "Model"])
        #expect(claude[0].items.first { $0.id == "cycle" }?.hint == "\u{21E7}Tab")
        #expect(claude[0].items.first { $0.id == "model" }?.hint == "\u{2325}P")
        #expect(claude[0].items.map(\.label).contains("Transcript"))

        let unknown = SSHTerminalKeymap.composerPages(for: nil, userFile: nil)
        #expect(unknown[0].items.map(\.label) == ["Thinking", "Cycle", "Model"])
        #expect(unknown[2].items.map(\.label) == ["Esc", "Tab", "^C", "^D"])

        // Esc or Tab must omit the slot. It must not become Ctrl+L under the Model label.
        let modelEsc = try pages("pi", file: #"{"app.model.select":"escape"}"#)
        #expect(modelEsc[0].items.contains { $0.id == "model" || $0.hint == "^L" } == false)
        let modelTab = try pages("pi", file: #"{"app.model.select":"tab"}"#)
        #expect(modelTab[0].items.contains { $0.id == "model" || $0.hint == "^L" } == false)
    }

    @Test func arrowHoldDragSelectsDominantAxisAndBoundedSpeed() {
        let held = GHOSTTY_KEY_ARROW_UP
        let idle = SSHTerminalArrowRepeat.plan(heldKey: held, translation: .zero)
        #expect(idle.key == held)
        #expect(idle.interval == 0.12)
        #expect(SSHTerminalArrowRepeat.plan(heldKey: held, translation: .init(width: 12, height: -8)) == idle)
        for (drag, expected) in [(CGSize(width: -40, height: 20), GHOSTTY_KEY_ARROW_LEFT),
                                 (CGSize(width: 40, height: -20), GHOSTTY_KEY_ARROW_RIGHT),
                                 (CGSize(width: 20, height: -40), GHOSTTY_KEY_ARROW_UP),
                                 (CGSize(width: -20, height: 40), GHOSTTY_KEY_ARROW_DOWN)] {
            let plan = SSHTerminalArrowRepeat.plan(heldKey: held, translation: drag)
            #expect(plan.key == expected)
            #expect(plan.interval < idle.interval)
        }
        let near = SSHTerminalArrowRepeat.plan(heldKey: held, translation: .init(width: 24, height: 0))
        let far = SSHTerminalArrowRepeat.plan(heldKey: held, translation: .init(width: 120, height: 0))
        #expect(far.interval < near.interval)
        #expect(SSHTerminalArrowRepeat.plan(heldKey: held, translation: .init(width: 10_000, height: 0)).interval == 0.035)
        #expect(SSHTerminalArrowRepeat.plan(heldKey: held, translation: .zero) == idle) // return to held direction
    }

    @Test func armedModifiersNeverRouteComposerDraftChangesToTheTerminal() async throws {
        // Mount the real UIKit composer so a draft write runs its text-view
        // delegate. Programmatic writes model transcript updates at the draft
        // boundary; this does not exercise microphone capture or ASR.
        let rewrites = [
            ("typing", ["c", "cd", "cdx"]),
            ("paste", ["pasted text\nsecond line"]),
            ("dictation partials", ["c", "ca", "cat"]),
            ("unchanged-text stop then typing", ["cat", "cat", "catx"]),
            ("first write on stop", ["final transcript"]),
        ]
        for modifier in [GhosttyMods(GHOSTTY_MODS_CTRL), GhosttyMods(GHOSTTY_MODS_ALT)] {
            for (scenario, drafts) in rewrites {
                let fixture = TerminalConnectionFixture()
                let channel = try SSHTerminalChannel()
                channel.opened(fixture)
                channel.event(.writabilityChanged(false))
                let mounted = try MountedTerminalComposer(channel: channel)
                defer { mounted.dismiss(); channel.close(reason: "done") }
                let textView = try #require(mounted.find { $0 is PastableUITextView } as? PastableUITextView)
                let delegate = try #require(textView.delegate)
                #expect(
                    delegate is ComposerBarController,
                    "Terminal chat bar must use the UIKit composer"
                )
                channel.modifierLatch.toggle(modifier)
                for draft in drafts {
                    textView.text = draft
                    delegate.textViewDidChange?(textView)
                    await mounted.update()
                    #expect(textView.text == draft, "\(scenario): draft must stay intact")
                    #expect(channel.modifierLatch.isArmed(modifier), "\(scenario): draft must not spend the latch")
                }
                // Queue a real key, then drain: comparing the complete sink
                // catches hidden input even while SSH was backpressured.
                #expect(channel.key(GHOSTTY_KEY_X, text: "x"))
                #expect(channel.modifierLatch.modifiers == 0)
                channel.event(.writabilityChanged(true))
                var bytes = fixture.bytes.makeAsyncIterator()
                let expected = modifier == GhosttyMods(GHOSTTY_MODS_CTRL)
                    ? Data([0x18]) : Data("\u{1b}x".utf8)
                #expect(await bytes.next() == expected)
                #expect(await fixture.sentBytes == expected)
            }
        }
    }

    /// A rotation runs chat-bar chrome updates inside its animation. A hide
    /// written over an already hidden action row must not leave the stack view
    /// a pending hide that undoes the next focus.
    @Test func chatBarActionRowShowsOnFocusAfterAnimatedChromeUpdates() async throws {
        let channel = try SSHTerminalChannel()
        let mounted = try MountedTerminalComposer(channel: channel)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let textView = try #require(mounted.find { $0 is PastableUITextView } as? PastableUITextView)
        let row = try #require(mounted.bar.keyStripContainer.superview as? UIStackView)
        #expect(row.isHidden, "the action row waits for focus")
        for _ in 0..<2 {
            UIView.animate(withDuration: 0.3) { mounted.bar.apply() }
            try await Task.sleep(for: .milliseconds(600))
        }
        textView.delegate?.textViewDidBeginEditing?(textView)
        try await Task.sleep(for: .milliseconds(600))
        await mounted.update()
        #expect(!row.isHidden, "focus shows the action row")
        #expect(!mounted.bar.keyStripContainer.isHidden, "focus shows the key strip")
    }

    @Test func rawKeyboardAndAccessoryConsumeOnlyAcceptedKeys() async throws {
        for modifier in [GhosttyMods(GHOSTTY_MODS_CTRL), GhosttyMods(GHOSTTY_MODS_ALT)] {
            let fixture = TerminalConnectionFixture()
            let channel = try SSHTerminalChannel()
            channel.opened(fixture)
            let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
            let mounted = try MountedTerminalTestGrid(grid)
            defer { mounted.dismiss(); channel.close(reason: "done") }
            let keyboard = grid as UIKeyInput
            let accessory = try #require(grid.inputAccessoryView)
            let modifierButton = try #require(mounted.find(in: accessory) {
                $0.accessibilityIdentifier == (modifier == GhosttyMods(GHOSTTY_MODS_CTRL) ? "sshTerminal.control" : "sshTerminal.alt")
            } as? UIButton)
            var bytes = fixture.bytes.makeAsyncIterator()
            // A latch armed elsewhere (the composer strip) is spent by raw typing.
            channel.modifierLatch.toggle(modifier)
            keyboard.insertText("c")
            keyboard.insertText("c")
            let expected = modifier == GhosttyMods(GHOSTTY_MODS_CTRL) ? Data([3]) : Data("\u{1b}c".utf8)
            #expect(await bytes.next() == expected)
            #expect(await bytes.next() == Data("c".utf8))
            #expect(channel.modifierLatch.modifiers == 0)
            #expect(modifierButton.accessibilityValue == "Off")
            // Conversely, the raw accessory arms the same latch used by key().
            modifierButton.sendActions(for: .touchUpInside)
            #expect(channel.modifierLatch.isArmed(modifier))
            #expect(channel.key(GHOSTTY_KEY_X, text: "x"))
            #expect(await bytes.next() == (modifier == GhosttyMods(GHOSTTY_MODS_CTRL) ? Data([0x18]) : Data("\u{1b}x".utf8)))
            #expect(channel.modifierLatch.modifiers == 0)

            for refusal in ["full", "eof", "disconnected"] {
                if refusal == "full" {
                    channel.event(.writabilityChanged(false))
                    #expect(channel.send(Data(repeating: 1, count: SSHTerminalChannel.maximumQueuedBytes)))
                } else if refusal == "eof" {
                    channel.event(.eof)
                } else {
                    channel.close(reason: "disconnected")
                }
                modifierButton.sendActions(for: .touchUpInside)
                keyboard.insertText("c")
                #expect(channel.modifierLatch.isArmed(modifier), "\(refusal): refusal must preserve the latch")
                #expect(modifierButton.accessibilityValue == "On")
                keyboard.deleteBackward()
                #expect(channel.modifierLatch.isArmed(modifier))
                #expect(modifierButton.accessibilityValue == "On")
                // Disarm before the next refusal case.
                if channel.modifierLatch.isArmed(modifier) { channel.modifierLatch.toggle(modifier) }
            }
        }
    }

    @Test func softwareTextInputMapsKeysAndCommitsMarkedTextOnce() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let input = grid as UITextInput
        #expect(grid is UITextInput)
        #expect(input.spellCheckingType == .no)
        #expect(input.autocorrectionType == .no)
        #expect(input.hasText)
        var bytes = fixture.bytes.makeAsyncIterator()
        input.insertText("ab")
        #expect(await bytes.next() == Data("ab".utf8))
        #expect(input.hasText)
        input.deleteBackward()
        #expect(await bytes.next() == Data([127]))
        #expect(input.hasText)
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        input.insertText("に")
        input.unmarkText()
        #expect(await bytes.next() == Data("に".utf8))
        input.insertText("に")
        #expect(await bytes.next() == Data("に".utf8))
        // Unmark first: the keyboard's echo in the same turn is dropped, and
        // the same character typed on a later turn sends again.
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        input.unmarkText()
        input.insertText("に")
        input.insertText("z")
        #expect(await bytes.next() == Data("に".utf8))
        #expect(await bytes.next() == Data("z".utf8))
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        input.unmarkText()
        #expect(await bytes.next() == Data("に".utf8))
        await Task.yield()
        input.insertText("に")
        #expect(await bytes.next() == Data("に".utf8))
        channel.close(reason: "done")
    }

    @Test func softwareTextThatCouldRunACommandGoesThroughPasteConfirmation() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var pasted = [String?]()
        let grid = SSHTerminalGridView(channel: channel, paste: { pasted.append($0) }, followChanged: { _ in })
        let input = grid as UITextInput
        var bytes = fixture.bytes.makeAsyncIterator()
        // Writing Tools and similar system edits replace a range.
        let caret = try #require(input.textRange(from: input.endOfDocument, to: input.endOfDocument))
        input.replace(caret, withText: "ls\n")
        // Dictation can insert a phrase in one call.
        input.insertText("echo hi\nrm -rf build")
        input.insertText("\u{1b}[A")
        #expect(pasted == ["ls\n", "echo hi\nrm -rf build", "\u{1b}[A"])
        // A lone Return from the keyboard is still Enter, and nothing else was sent.
        input.insertText("\n")
        #expect(await bytes.next() == Data("\r".utf8))
        // A word the keyboard inserts at once is one write, sent at once.
        input.insertText("a\tb")
        #expect(await bytes.next() == Data("a\tb".utf8))
        #expect(pasted.count == 3)
        channel.close(reason: "done")
    }

    /// Dictation revises its guess while you speak. Each revision reaches the
    /// shell at once as one write: backspaces back to the first changed
    /// character, then the rest of the new guess.
    @Test func dictationRevisionsReachTheShellAtOnce() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var pasted = [String?]()
        let grid = SSHTerminalGridView(channel: channel, paste: { pasted.append($0) }, followChanged: { _ in })
        let input = grid as UITextInput
        var bytes = fixture.bytes.makeAsyncIterator()
        func revise(_ last: String, _ next: String) throws {
            let start = try #require(input.position(from: input.endOfDocument, offset: -last.utf16.count))
            let range = try #require(input.textRange(from: start, to: input.endOfDocument))
            #expect(input.text(in: range) == last)
            input.replace(range, withText: next)
        }
        input.insertText("hello")
        #expect(await bytes.next() == Data("hello".utf8))
        try revise("hello", "hello there")
        #expect(await bytes.next() == Data(" there".utf8))
        try revise("hello there", "Hello there")
        #expect(await bytes.next() == Data(repeating: 127, count: 11) + Data("Hello there".utf8))
        // A revision that adds a new line asks first, after the backspaces.
        try revise("Hello there", "Hello\nrm -rf build")
        #expect(await bytes.next() == Data(repeating: 127, count: 6))
        #expect(pasted == ["\nrm -rf build"])
        // The document started over, so the next guess goes after it.
        let whole = try #require(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        #expect(input.text(in: whole) == SSHTerminalTextInputStorage.filler)
        channel.close(reason: "done")
    }

    @Test func wordsLeaveTheOneShotModifierForTheNextKey() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        var bytes = fixture.bytes.makeAsyncIterator()
        let ctrl = GhosttyMods(GHOSTTY_MODS_CTRL)
        channel.modifierLatch.toggle(ctrl)
        grid.insertText("clear")
        #expect(await bytes.next() == Data("clear".utf8))
        #expect(channel.modifierLatch.isArmed(ctrl))
        let end = grid.textInputStorage.utf16Count
        grid.applyTextInput(grid.textInputStorage.replace(
            utf16Range: (end - 5)..<end, with: "clear screen", hardwareKeysDown: false
        ))
        #expect(await bytes.next() == Data(" screen".utf8))
        #expect(channel.modifierLatch.isArmed(ctrl))
        // The key the modifier was armed for still gets it.
        grid.insertText("c")
        #expect(await bytes.next() == Data([3]))
        #expect(channel.modifierLatch.modifiers == 0)
        // Ctrl-C is not the "c" the document holds; it starts over.
        #expect(grid.textInputStorage.text == SSHTerminalTextInputStorage.filler)
        // Alt-⌫ deletes a word in readline, not the character the
        // document would drop, so it starts over too.
        grid.insertText("ls")
        #expect(await bytes.next() == Data("ls".utf8))
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_ALT))
        grid.deleteBackward()
        #expect(await bytes.next() == Data("\u{1b}\u{7f}".utf8))
        #expect(grid.textInputStorage.text == SSHTerminalTextInputStorage.filler)
        channel.close(reason: "done")
    }

    @Test func softwareDeleteKeepsRepeatingAfterTheCaretIsMoved() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let input = grid as UITextInput
        var bytes = fixture.bytes.makeAsyncIterator()
        // The space-bar trackpad and hit tests try to park the caret at the start.
        input.beginFloatingCursor?(at: .zero)
        input.updateFloatingCursor?(at: .zero)
        input.endFloatingCursor?()
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.beginningOfDocument)
        if let start = input.closestPosition(to: .zero) {
            input.selectedTextRange = input.textRange(from: start, to: start)
        }
        for _ in 0..<3 {
            // UIKit repeats ⌫ only while a character precedes the caret.
            let caret = try #require(input.selectedTextRange?.start)
            #expect(input.position(from: caret, offset: -1) != nil)
            input.deleteBackward()
            #expect(await bytes.next() == Data([127]))
        }
        channel.close(reason: "done")
    }

    @Test func optionIsMetaAndReturnVariantsFollowTheAppsKeyboardProtocol() throws {
        let engine = try SSHTerminalEngine { _ in }
        let alt = GhosttyMods(GHOSTTY_MODS_ALT)
        let shift = GhosttyMods(GHOSTTY_MODS_SHIFT)
        #expect(engine.key(GHOSTTY_KEY_B, text: "b", modifiers: alt) == Data("\u{1b}b".utf8))
        #expect(engine.key(GHOSTTY_KEY_ENTER, modifiers: alt) == Data("\u{1b}\r".utf8))
        #expect(engine.key(GHOSTTY_KEY_ENTER, modifiers: shift) == Data("\u{1b}[27;2;13~".utf8))
        // modifyOtherKeys 2 (Codex asks for it when Kitty is not there).
        engine.receive(Data("\u{1b}[>4;2m".utf8))
        #expect(engine.key(GHOSTTY_KEY_B, text: "b", modifiers: alt) == Data("\u{1b}[27;3;98~".utf8))
        engine.receive(Data("\u{1b}[>4;0m".utf8))
        // Kitty keyboard protocol, as pi, Claude Code, and Codex request it.
        engine.receive(Data("\u{1b}[>1u".utf8))
        #expect(engine.key(GHOSTTY_KEY_ENTER, modifiers: shift) == Data("\u{1b}[13;2u".utf8))
        #expect(engine.key(GHOSTTY_KEY_ENTER, modifiers: alt) == Data("\u{1b}[13;3u".utf8))
        #expect(engine.key(GHOSTTY_KEY_B, text: "b", modifiers: alt) == Data("\u{1b}[98;3u".utf8))
        #expect(engine.key(GHOSTTY_KEY_W, text: "w", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)) == Data("\u{1b}[119;5u".utf8))
        #expect(engine.key(GHOSTTY_KEY_ENTER) == Data("\r".utf8))
    }

    @Test func commandKClearsLikeGhosttyAndSendsAFormFeedOnlyAtAPrompt() throws {
        func rows(_ engine: SSHTerminalEngine) -> [String] {
            engine.frame().rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        }
        // A command's output: history and the rows above the cursor go,
        // the cursor row moves to the top, and nothing is sent.
        let output = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        output.receive(Data("one\r\ntwo\r\nthree\r\nfour\r\nrun".utf8))
        #expect(output.scrollbar.total > output.scrollbar.len)
        #expect(output.clearScreen().isEmpty)
        #expect(rows(output) == ["run", "", ""])
        #expect(output.scrollbar.total == output.scrollbar.len)
        #expect(output.cursorCell.column == 3 && output.cursorCell.row == 0)
        output.receive(Data("!".utf8))
        #expect(rows(output)[0] == "run!")

        // At a shell prompt (OSC 133): the whole screen, then a form feed.
        let prompt = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        prompt.receive(Data("old\r\nout\r\n\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls".utf8))
        #expect(prompt.clearScreen() == Data([0x0C]))
        #expect(rows(prompt) == ["", "", ""])
        #expect(prompt.scrollbar.total == prompt.scrollbar.len)

        // A full-screen app keeps its screen, and so does a stream stopped
        // inside an escape sequence.
        let app = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        app.receive(Data("\u{1b}[?1049hvim\r\nbuf".utf8))
        #expect(app.clearScreen().isEmpty)
        #expect(rows(app)[0] == "vim")
        let split = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        split.receive(Data("a\r\nb\u{1b}[".utf8))
        #expect(split.clearScreen().isEmpty)
        split.receive(Data("1m".utf8))
        #expect(rows(split) == ["a", "b", ""])
    }

    @Test func trackpadTravelSendsArrowsInTheAppsCursorKeyModeOncePerFrame() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let input = grid as UITextInput
        var bytes = fixture.bytes.makeAsyncIterator()
        let cell = grid.cellSize
        input.beginFloatingCursor?(at: CGPoint(x: 100, y: 100))
        input.updateFloatingCursor?(at: CGPoint(x: 100 + cell.width * 1.5, y: 100))
        input.updateFloatingCursor?(at: CGPoint(x: 100 + cell.width * 2.5, y: 100 - cell.height * 1.2))
        grid.flushTrackpadArrows()
        #expect(await bytes.next() == Data("\u{1b}[C\u{1b}[C\u{1b}[A".utf8))
        // vim and less turn on application cursor keys (DECCKM).
        channel.engine.receive(Data("\u{1b}[?1h".utf8))
        input.updateFloatingCursor?(at: CGPoint(x: 100 - cell.width, y: 100 - cell.height * 1.2))
        // Lifting the finger sends the last frame's travel at once.
        input.endFloatingCursor?()
        #expect(await bytes.next() == Data("\u{1b}OD\u{1b}OD\u{1b}OD".utf8))
        // While an IME composes, the trackpad is the IME's.
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        input.beginFloatingCursor?(at: CGPoint(x: 100, y: 100))
        input.updateFloatingCursor?(at: CGPoint(x: 200, y: 100))
        input.endFloatingCursor?()
        input.unmarkText()
        #expect(await bytes.next() == Data("に".utf8))
        channel.close(reason: "done")
    }

    @Test func commandShortcutsCopyTheShownSelectionAndClear() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        var bytes = fixture.bytes.makeAsyncIterator()
        let commands = try #require(grid.keyCommands)
        #expect(commands.map(\.input) == ["c", "k"])
        #expect(commands.allSatisfy { $0.modifierFlags == .command && !$0.title.isEmpty })
        func run(_ input: String) throws {
            let command = try #require(commands.first { $0.input == input })
            _ = grid.perform(command.action, with: command)
        }
        UIPasteboard.general.string = "before"
        let copies = channel.copies
        try run("c") // nothing selected: no copy and nothing sent
        #expect(channel.copies == copies)
        #expect(UIPasteboard.general.string == "before")
        // A double-tapped word stays the selection while it is highlighted.
        channel.engine.receive(Data("hello world".utf8))
        let word = CGPoint(x: grid.cellSize.width * 1.5, y: grid.cellSize.height * 0.5)
        grid.handleTap(at: word, now: 100)
        grid.handleTap(at: word, now: 100.1)
        #expect(channel.copies == copies + 1)
        UIPasteboard.general.string = "before"
        try run("c")
        #expect(channel.copies == copies + 2)
        #expect(UIPasteboard.general.string == "hello")
        channel.engine.receive(Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}".utf8))
        try run("k")
        // The first bytes sent: neither "⌘C" sent anything.
        #expect(await bytes.next() == Data([0x0C]))
        channel.close(reason: "done")
    }

    @Test func namedActionsPreserveBindingsAndLeaveTheModifierForExplicitKeys() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var bytes = fixture.bytes.makeAsyncIterator()
        let shell = try #require(SSHTerminalKeymap.profile(for: "shell"))
        let history = try #require(SSHTerminalKeymap.actions(for: shell, userFile: nil).first { $0.title == "History" })
        for (strokes, expected) in [(history.strokes, Data([0x12])),
                                    (try #require(SSHTerminalKeymap.parse("ctrl+x ctrl+b", syntax: .plus)), Data([0x18, 0x02]))] {
            channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_ALT))
            channel.keys(strokes)
            #expect(await bytes.next() == expected)
            #expect(channel.modifierLatch.isArmed(GhosttyMods(GHOSTTY_MODS_ALT)))
            channel.key(GHOSTTY_KEY_X, text: "x")
            #expect(await bytes.next() == Data("\u{1b}x".utf8))
            #expect(channel.modifierLatch.modifiers == 0)
        }
        channel.close(reason: "done")
    }

    @Test func chatBarAndAccessoryShareOneKeyStripAndStableIdentifiers() {
        let composer = SSHTerminalKeyStripView(role: .composer, handlers: .init())
        composer.apply(
            profile: SSHTerminalKeymap.profile(for: "pi"),
            userFile: nil,
            colors: .placeholder,
            foreground: .label,
            background: .black
        )
        composer.layoutIfNeeded()
        func find(_ root: UIView, _ id: String) -> UIView? {
            if root.accessibilityIdentifier == id { return root }
            for child in root.subviews {
                if let match = find(child, id) { return match }
            }
            return nil
        }
        func findType(_ root: UIView, _ match: (UIView) -> Bool) -> UIView? {
            if match(root) { return root }
            for child in root.subviews {
                if let found = findType(child, match) { return found }
            }
            return nil
        }
        func collectArrows(_ root: UIView) -> [SSHTerminalArrowButton] {
            var found: [SSHTerminalArrowButton] = []
            if let arrow = root as? SSHTerminalArrowButton { found.append(arrow) }
            for child in root.subviews { found.append(contentsOf: collectArrows(child)) }
            return found
        }
        // One scrolling row: agent keys, arrows, and exit chords together.
        #expect(find(composer, "sshTerminal.composer.page") == nil)
        #expect(find(composer, "sshTerminal.composer.rawKeyboard") != nil)
        #expect(findType(composer) { $0 is SSHTerminalArrowButton } != nil)
        let composerArrows = collectArrows(composer)
        #expect(Set(composerArrows.compactMap { $0.configuration?.title }) == ["\u{2190}", "\u{2193}", "\u{2191}", "\u{2192}"])
        #expect(find(composer, "sshTerminal.composer.escape") != nil)
        #expect(find(composer, "sshTerminal.composer.tab") != nil)
        #expect(find(composer, "sshTerminal.composer.ctrl-c") != nil)

        let accessory = SSHTerminalKeyStripView(role: .accessory, handlers: .init())
        accessory.apply(
            profile: nil,
            userFile: nil,
            colors: .placeholder,
            foreground: .label,
            background: .black
        )
        accessory.layoutIfNeeded()
        #expect(find(accessory, "sshTerminal.escape") != nil)
        #expect(find(accessory, "sshTerminal.control") != nil)
        #expect(find(accessory, "sshTerminal.tab") != nil)
        #expect(find(accessory, "sshTerminal.paste") != nil)
        #expect(find(accessory, "sshTerminal.useChatBar") != nil)
        #expect(find(accessory, "sshTerminal.hideKeyboard") != nil)
        #expect(findType(accessory) { $0 is SSHTerminalArrowButton } != nil)
        let accessoryArrows = collectArrows(accessory)
        #expect(Set(accessoryArrows.compactMap { $0.configuration?.title }) == ["\u{2190}", "\u{2193}", "\u{2191}", "\u{2192}"])
    }

    @Test func pastedImagesKeepTheirTypeForTheHostFile() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { done in
            done(Data([0xFF, 0xD8]), nil)
            return nil
        }
        #expect(SSHTerminalPastedImage.imageType(in: provider) == .jpeg)
        #expect(SSHTerminalPastedImage.imageType(in: NSItemProvider(object: "text" as NSString)) == nil)
        #expect(SSHTerminalPastedImage(data: Data(), type: .jpeg).fileExtension == "jpeg")
        #expect(SSHTerminalPastedImage(data: Data(), type: .heic).fileExtension == "heic")
        #expect(SSHTerminalPastedImage(data: Data(), type: .image).fileExtension == "png")
    }

    @Test func phoneWidthStripsScrollTheKeysAndKeepTheDockInReach() {
        func find(_ root: UIView, _ id: String) -> UIView? {
            if root.accessibilityIdentifier == id { return root }
            for child in root.subviews {
                if let match = find(child, id) { return match }
            }
            return nil
        }
        let claude = SSHTerminalKeymap.profile(for: "claude")!
        let accessory = SSHTerminalKeyStripView(role: .accessory, handlers: .init())
        accessory.apply(
            profile: claude,
            userFile: nil,
            actions: SSHTerminalKeymap.actions(for: claude, userFile: nil),
            colors: .placeholder,
            foreground: .label,
            background: .black
        )
        accessory.frame = CGRect(x: 0, y: 0, width: 390, height: accessory.intrinsicContentSize.height)
        let composer = SSHTerminalKeyStripView(role: .composer, handlers: .init())
        composer.apply(profile: claude, userFile: nil, colors: .placeholder, foreground: .label, background: .black)
        composer.frame = CGRect(x: 0, y: 0, width: 320, height: 44)

        // The accessory is two rows: fixed keys over Paste and program actions.
        accessory.layoutIfNeeded()
        if let escape = find(accessory, "sshTerminal.escape"), let paste = find(accessory, "sshTerminal.paste") {
            #expect(paste.convert(paste.bounds, to: accessory).minY >= escape.convert(escape.bounds, to: accessory).maxY)
        } else {
            Issue.record("missing Esc or Paste")
        }
        if let chat = find(accessory, "sshTerminal.useChatBar"), let hide = find(accessory, "sshTerminal.hideKeyboard") {
            #expect(hide.convert(hide.bounds, to: accessory).minY >= chat.convert(chat.bounds, to: accessory).maxY)
        }

        let strips: [(SSHTerminalKeyStripView, first: String, pinned: [String])] = [
            (accessory, "sshTerminal.escape", ["sshTerminal.useChatBar", "sshTerminal.hideKeyboard"]),
            (composer, "sshTerminal.composer.escape", ["sshTerminal.composer.rawKeyboard"]),
        ]
        for (strip, first, pinned) in strips {
            strip.layoutIfNeeded()
            #expect(find(strip, "sshTerminal.page") == nil)
            #expect(find(strip, "sshTerminal.composer.page") == nil)
            var ancestor = find(strip, first)?.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else {
                Issue.record("missing key row for \(first)")
                continue
            }
            #expect(scroll.contentSize.width > scroll.bounds.width, "\(first) row should overflow and scroll")
            // A swipe that starts on a key scrolls instead of pressing it.
            if let key = find(strip, first) {
                #expect(scroll.touchesShouldCancel(in: key))
            }
            // Swiping to the end moves the keys, never the dock.
            scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
            strip.layoutIfNeeded()
            for id in pinned {
                guard let control = find(strip, id) else {
                    Issue.record("missing \(id)")
                    continue
                }
                #expect(!scroll.isDescendant(of: control) && !control.isDescendant(of: scroll), "\(id) scrolls")
                let frame = control.convert(control.bounds, to: strip)
                #expect(strip.bounds.contains(frame), "\(id) at \(frame)")
            }
        }
    }

    @Test func terminalDictationWritesTheLiveDraftAndKeepsItAfterLeavingTheBar() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        defer { channel.close(reason: "done") }
        let host = SSHTerminalComposerHost(
            channel: channel, connection: nil, draftStore: nil,
            themeID: ThemeRuntimeState.currentThemeID(), showRawKeyboard: {}
        )
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        _ = manager.beginStandaloneComposer(serverId: "preview", credentials: nil, connection: nil)
        try await manager.startRecording(keyboardLanguage: "en-US", source: ComposerShared.VoiceInputOwner.inlineComposer.rawValue)
        host.installVoiceManager(manager)
        host.setTextBeforeRecording("")
        session.yieldEvent(.replaceFinalTranscript("hello", committedText: "", activeText: "hello"))
        #expect(await waitForMainActorCondition { manager.currentTranscript == "hello" })
        host.applyOwnedVoiceObservation()
        #expect(host.content.text == "hello")
        host.releaseVoice()
        #expect(host.content.text == "hello", "Leaving the chat bar must keep the dictated words")
        await manager.cancelRecording()
    }

    @Test func theTerminalComposersMicDiscUsesTheColorsItIsGiven() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        defer { channel.close(reason: "done") }
        let host = SSHTerminalComposerHost(
            channel: channel, connection: nil, draftStore: nil,
            themeID: .dark, showRawKeyboard: {}
        )
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        host.installVoiceManager(manager)
        let bar = ComposerBarController()
        host.attach(bar)
        _ = bar.view
        func disc() throws -> UIColor {
            let fill = try #require(bar.micButton.subviews.first {
                !($0 is OrbMetalView) && !($0 is UIImageView) && !($0 is UILabel) && !($0 is UIActivityIndicatorView)
            })
            return try #require(fill.backgroundColor)
        }
        func components(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a]
        }

        var given = ComposerThemeColors(palette: ThemeID.dark.palette)
        given.bgHighlight = UIColor(red: 0.10, green: 0.25, blue: 0.75, alpha: 1)
        bar.micColors = given
        bar.apply()
        #expect(components(try disc()) == components(given.bgHighlight), "a terminal over a Ghostty theme paints the disc with the composer's colors")

        bar.micColors = nil
        bar.apply()
        #expect(components(try disc()) == components(UIColor(ThemeRuntimeState.currentPalette().bgHighlight)), "everywhere else it keeps the app theme's")
    }

    @Test func terminalDictationFailureRestoresThePrefixAndShowsTheRetryBanner() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        defer { channel.close(reason: "done") }
        let host = SSHTerminalComposerHost(
            channel: channel, connection: nil, draftStore: nil,
            themeID: ThemeRuntimeState.currentThemeID(), showRawKeyboard: {}
        )
        var banner: String?
        host.onFailureChange = { banner = $0 }
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        manager.setEngineMode(.onDevice)
        _ = manager.beginStandaloneComposer(serverId: "preview", credentials: nil, connection: nil)
        try await manager.startRecording(
            keyboardLanguage: "en-US",
            source: ComposerShared.VoiceInputOwner.inlineComposer.rawValue,
            onCaptureFailure: {}
        )
        host.installVoiceManager(manager)
        host.setText("kept ")
        host.setTextBeforeRecording("kept ")
        host.setText("kept extra")
        session.finishEvents(throwing: VoiceInputError.audioCaptureUnavailable)
        #expect(await waitForMainActorCondition { manager.currentComposerCaptureFailure != nil })
        host.applyOwnedVoiceObservation()
        #expect(host.content.text == "kept ")
        #expect(ComposerShared.captureFailure(manager, owner: .inlineComposer) != nil)
        await manager.cancelRecording()
        _ = banner
    }

    @Test func floatingNoticesDoNotResizeTheGrid() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        mounted.host.view.layoutIfNeeded()
        let grid = try #require(mounted.controller.gridView)
        let before = grid.bounds.size
        #expect(before.width > 0 && before.height > 0)

        channel.event(.eof)
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_CTRL))
        #expect(!channel.key(GHOSTTY_KEY_C, text: "c"))
        #expect(channel.inputNotice.contains("Not sent"))
        mounted.host.view.setNeedsLayout()
        mounted.host.view.layoutIfNeeded()
        #expect(grid.bounds.size == before)

        UIPasteboard.general.string = nil
        grid.requestPaste(nil)
        mounted.host.view.setNeedsLayout()
        mounted.host.view.layoutIfNeeded()
        #expect(grid.bounds.size == before)
    }

    @Test func cursorShiftKeepsTheCursorRowAboveAGrownChatBar() {
        // 40 rows of 20 pt; the bar covers the bottom 100 pt.
        let shift = { (row: Int) in
            SSHTerminalComposerOverlap.shift(gridHeight: 800, covered: 100, cursorRow: row, cellHeight: 20)
        }
        #expect(shift(39) == 100, "cursor on the last row: the whole cover")
        #expect(shift(36) == 40, "just far enough: row 36 ends at 740, 40 below the bar's top")
        #expect(shift(34) == 0, "a cursor already above the bar moves nothing")
        #expect(shift(0) == 0)
        #expect(
            shift(43) == 0,
            "a cursor past the last row belongs to the size before the keyboard; no jump while the terminal catches up"
        )
        #expect(SSHTerminalComposerOverlap.shift(gridHeight: 800, covered: 0, cursorRow: 39, cellHeight: 20) == 0)
        #expect(
            SSHTerminalComposerOverlap.shift(gridHeight: 810, covered: 30, cursorRow: 39, cellHeight: 20) == 20,
            "a partial row below the grid's last row counts as space"
        )
        #expect(
            SSHTerminalComposerOverlap.shift(gridHeight: 800, covered: 50, cursorRow: 49, cellHeight: 16) == 64,
            "whole rows: 50 pt of cover moves four 16 pt rows, so no row is cut at the top"
        )
    }

    @Test func chatBarGrowsOverTheGridWithoutResizingTheTerminal() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let resizes = SSHTerminalResizeLog()
        let collector = Task { @MainActor in
            for await geometry in fixture.resizes { resizes.sizes.append(geometry) }
        }
        defer { collector.cancel() }
        func settle() async throws {
            for _ in 0..<4 {
                await Task.yield()
                mounted.host.view.setNeedsLayout()
                mounted.host.view.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(250))
            mounted.host.view.layoutIfNeeded()
        }

        // A coding agent reports itself, and Chat Bar is asked for by hand.
        channel.event(.data(Data("\u{1b}]7501;state=idle:app=pi\u{1b}\\".utf8)))
        try mounted.tapChatBar()
        try await settle()
        let textView = try #require(mounted.find { $0 is PastableUITextView } as? PastableUITextView)
        let grid = try #require(mounted.controller.gridView)
        // Fill the screen so the cursor sits on the bottom row, like an agent's prompt.
        channel.event(.data(Data(String(repeating: "output\r\n", count: 120).utf8)))
        channel.event(.data(Data("pi> ".utf8)))
        try await settle()
        let gridSize = grid.bounds.size
        let sentBefore = resizes.sizes.count
        #expect(sentBefore > 0, "the first layout sized the remote terminal")
        #expect(grid.transform == .identity, "a resting chat bar covers nothing")

        let container = try #require(sequence(first: textView as UIView, next: \.superview)
            .first { $0.superview === mounted.controller.view })
        let delegate = try #require(textView.delegate)
        for draft in ["one", "one\ntwo\nthree", "one\ntwo\nthree\nfour\nfive\nsix"] {
            textView.text = draft
            delegate.textViewDidChange?(textView)
            try await settle()
            #expect(grid.bounds.size == gridSize, "\(draft.count) characters: the grid keeps its size")
            #expect(resizes.sizes.count == sentBefore, "\(draft.count) characters: no remote resize")
        }
        let barTop = container.convert(CGPoint.zero, to: mounted.controller.view).y
        let gridBottom = grid.convert(CGPoint(x: 0, y: grid.bounds.maxY), to: mounted.controller.view).y
            + -grid.transform.ty
        #expect(barTop < gridBottom - grid.cellSize.height, "six lines grow over the grid's bottom rows")
        let cursorRow = channel.engine.cursorCell.row
        let cursorBottom = grid.convert(
            CGPoint(x: 0, y: CGFloat(cursorRow + 1) * grid.cellSize.height), to: mounted.controller.view
        ).y
        #expect(cursorBottom <= barTop + 0.5, "the cursor row stays above the chat bar")
        #expect(grid.transform.ty < 0)

        textView.text = ""
        delegate.textViewDidChange?(textView)
        try await settle()
        #expect(grid.transform == .identity, "the picture returns when the bar shrinks")
        #expect(grid.bounds.size == gridSize)
        #expect(resizes.sizes.count == sentBefore)

        // Focused, the bar rests with its key strip; a draft still grows over the grid.
        #expect(textView.becomeFirstResponder())
        try await settle()
        try await Task.sleep(for: .milliseconds(600))
        try await settle()
        let focusedSize = grid.bounds.size
        let focusedSent = resizes.sizes.count
        for draft in ["one\ntwo\nthree\nfour\nfive\nsix", ""] {
            textView.text = draft
            delegate.textViewDidChange?(textView)
            try await settle()
            #expect(grid.bounds.size == focusedSize, "focused, \(draft.count) characters: the grid keeps its size")
            #expect(resizes.sizes.count == focusedSent, "focused, \(draft.count) characters: no remote resize")
        }

        // Leaving and coming back with a long draft brings the key strip back.
        textView.text = "one\ntwo\nthree\nfour\nfive\nsix"
        delegate.textViewDidChange?(textView)
        try await settle()
        func keyStripShows() throws -> Bool {
            let key = try #require(mounted.find { $0.accessibilityIdentifier == "sshTerminal.composer.rawKeyboard" })
            return !sequence(first: key, next: \.superview).contains { $0.isHidden || $0.alpha < 0.01 }
        }
        #expect(try keyStripShows())
        textView.resignFirstResponder()
        try await settle()
        try await Task.sleep(for: .milliseconds(600))
        try await settle()
        #expect(try !keyStripShows())
        #expect(textView.becomeFirstResponder())
        try await settle()
        try await Task.sleep(for: .milliseconds(600))
        try await settle()
        #expect(try keyStripShows(), "refocusing with a draft shows the key strip again")
        textView.resignFirstResponder()
    }

    @Test func outputWalkingTheCursorUnderAGrownChatBarKeepsItsRowAboveTheBar() async throws {
        let terminal = try await GrownChatBarTerminal()
        defer { terminal.close() }
        let grid = terminal.grid
        // A half-empty screen, like after `clear`: the cursor starts at the top.
        try await terminal.output("\u{1b}[H\u{1b}[2J")
        #expect(grid.transform == .identity, "a cursor well above the bar moves nothing")
        let rows = Int(grid.bounds.height / grid.cellSize.height)
        var walked = 0
        while terminal.channel.engine.cursorCell.row < rows - 1 {
            // Each chunk lands in one frame; no layout pass runs in between.
            try await terminal.output(String(repeating: "line \(walked)\r\n", count: 3))
            walked += 3
            let row = terminal.channel.engine.cursorCell.row
            #expect(
                terminal.cursorBottom() <= terminal.barTop() + 0.5,
                "cursor row \(row) of \(rows): its bottom \(terminal.cursorBottom()) is under the bar at \(terminal.barTop())"
            )
            if walked > rows + 6 { break }
        }
        #expect(grid.transform.ty < 0, "the walk reached the rows the bar covers")
    }

    @Test func readingHistoryWhileTheChatBarCoversTheCursorKeepsThePictureStill() async throws {
        let terminal = try await GrownChatBarTerminal()
        defer { terminal.close() }
        let grid = terminal.grid
        let engine = terminal.channel.engine
        let shifted = terminal.gridTop()
        #expect(grid.transform.ty < 0, "the cursor on the last row lifts the picture")

        // A drag into history detaches from live; the grid must not jump by the shift.
        engine.scroll(rows: -3)
        try await terminal.nextFrame()
        #expect(!engine.following)
        #expect(terminal.gridTop() == shifted, "starting to read history")
        // Output while you read history moves nothing either.
        try await terminal.output("more\r\nmore\r\n")
        #expect(terminal.gridTop() == shifted)

        // Dragging back to the bottom follows live again from the same place.
        engine.scrollToRow(Int(engine.scrollbar.total) - Int(engine.scrollbar.len))
        try await terminal.nextFrame()
        #expect(engine.following)
        #expect(terminal.gridTop() == shifted, "back at live")
    }

    @Test func terminalBarsShareOneShotModifiersAndEncodeAllBaseKeys() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var bytes = fixture.bytes.makeAsyncIterator()
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_CTRL))
        channel.key(GHOSTTY_KEY_C, text: "c")
        #expect(await bytes.next() == Data([3]))
        channel.key(GHOSTTY_KEY_C, text: "c")
        #expect(await bytes.next() == Data("c".utf8))
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_ALT))
        channel.keys(try #require(SSHTerminalKeymap.parse("x c", syntax: .plus)))
        #expect(await bytes.next() == Data("xc".utf8)) // named strokes do not spend the key latch
        #expect(channel.modifierLatch.isArmed(GhosttyMods(GHOSTTY_MODS_ALT)))
        #expect(channel.key(GHOSTTY_KEY_X, text: "x"))
        #expect(await bytes.next() == Data("\u{1b}x".utf8))
        for (id, expected) in [
            ("escape", "\u{1b}"),
            ("tab", "\t"),
            ("left", "\u{1b}[D"),
            ("down", "\u{1b}[B"),
            ("up", "\u{1b}[A"),
            ("right", "\u{1b}[C"),
        ] {
            let stroke = try #require(SSHTerminalKeymap.fixed.first { $0.id == id }?.stroke)
            #expect(channel.key(stroke.key, text: stroke.text, modifiers: stroke.modifiers))
            #expect(await bytes.next() == Data(expected.utf8))
        }
        #expect(channel.modifierLatch.modifiers == 0)
        channel.close(reason: "done")
    }

    @Test func eofStopsInputThenExitStatusBecomesTheReason() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_A, text: "a")
        channel.event(.eof)
        #expect(channel.connected) // still reading: a status may follow
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_CTRL))
        #expect(!channel.key(GHOSTTY_KEY_C, text: "c"))
        #expect(!channel.key(GHOSTTY_KEY_A, text: "a")) // later explicit keys are refused too
        #expect(channel.modifierLatch.isArmed(GhosttyMods(GHOSTTY_MODS_CTRL)))
        #expect(channel.inputNotice.contains("Not sent"))
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        channel.event(.writabilityChanged(true))
        channel.event(.exitStatus(3))
        channel.event(.closed)
        #expect(!channel.connected)
        #expect(channel.reason == "Shell exited with status 3.")
        #expect(await fixture.sentBytes.isEmpty)
    }

    @Test func eofThenCloseWithoutStatusIsAConnectionLoss() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        channel.event(.eof)
        channel.event(.closed)
        #expect(channel.reason == "The SSH connection closed.")
    }

    @Test func consumerAppliesStatusThatFollowsEOFInTheSameStream() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let queue = SSHTerminalEventQueue()
        for event in [SSHPTYEvent.data(Data("bye".utf8)), .eof, .exitStatus(3), .closed] { queue.push(event) }
        await channel.consume(queue)
        #expect(channel.reason == "Shell exited with status 3.")
        #expect(channel.engine.frame().rows[0].prefix(3).map(\.text).joined() == "bye")
    }

    @Test func outputBurstBeyondTheCapFailsTheSessionAfterInterpretingAcceptedBytesInOrder() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let queue = SSHTerminalEventQueue(limit: 8)
        // The consumer has not run yet, as when the main actor is saturated.
        queue.push(.data(Data("one".utf8)))
        queue.push(.data(Data("two".utf8)))
        queue.push(.data(Data("three".utf8))) // 11 queued bytes would exceed 8
        queue.push(.data(Data("late".utf8)))
        queue.push(.closed)
        await channel.consume(queue)
        #expect(!channel.connected)
        #expect(channel.reason.contains("stopped consuming"))
        #expect(channel.engine.frame().rows[0].prefix(6).map(\.text).joined() == "onetwo")
    }

    /// A burst is parsed in slices with the main actor free between them, and a
    /// close that runs in such a gap ends the burst: nothing after it is
    /// interpreted. The title queued after the burst is the proof: if the
    /// consumer ran the whole burst in one go, it would already be set.
    @Test func outputBurstYieldsBetweenSlicesAndACloseInAGapEndsIt() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let queue = SSHTerminalEventQueue(limit: 64 * 1024 * 1024)
        // About 8 MiB of styled lines: far beyond one slice budget of parsing.
        let chunk = Data(String(repeating: "\u{1b}[1;31mx\u{1b}[m\u{1b}[2K\r\n", count: 1024).utf8)
        for _ in 0..<(8 * 1024 * 1024 / chunk.count) { queue.push(.data(chunk)) }
        queue.push(.data(Data("\u{1b}]2;late\u{7}".utf8)))
        queue.push(.exitStatus(0))
        let before = channel.engine.changeCount
        let consumer = Task { await channel.consume(queue) }
        // This main-actor code runs mid-burst only if the consumer yields.
        while channel.engine.changeCount == before { await Task.yield() }
        channel.close(reason: "Closed by the user.")
        await consumer.value
        #expect(channel.title.isEmpty)
    }

    @Test func aTapClicksForAMouseAppAndOtherwiseOnlySendsInputAway() {
        // A tap never starts typing; the bar's buttons do.
        #expect(SSHTerminalTapAction.resolve(
            keyboardUp: false, otherInputFocused: false, appWantsClicks: false
        ) == .nothing)
        // Herdr's switch is a click, and with the keyboard up it stays; its
        // bar hides it.
        #expect(SSHTerminalTapAction.resolve(
            keyboardUp: true, otherInputFocused: false, appWantsClicks: true
        ) == .mouseClick)
        #expect(SSHTerminalTapAction.resolve(
            keyboardUp: false, otherInputFocused: false, appWantsClicks: true
        ) == .mouseClick)
        #expect(SSHTerminalTapAction.resolve(
            keyboardUp: true, otherInputFocused: false, appWantsClicks: false
        ) == .hideKeyboard)
        // The chat bar focused (a hardware keyboard) gives way before a click.
        #expect(SSHTerminalTapAction.resolve(
            keyboardUp: false, otherInputFocused: true, appWantsClicks: true
        ) == .dismissOtherInput)
    }

    @Test func touchesBecomeMouseReportsOnlyWhileTheAppAsksForThem() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 20, rows: 10)) { _ in }
        #expect(!engine.mouseTracking)
        #expect(engine.mouse(.click, column: 3, row: 2).isEmpty)
        // Herdr's own request: normal + button + any-event tracking, SGR format.
        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h".utf8))
        #expect(engine.mouseTracking)
        #expect(engine.mouse(.click, column: 3, row: 2) == Data("\u{1b}[<0;4;3M\u{1b}[<0;4;3m".utf8))
        #expect(engine.mouse(.wheelUp, column: 0, row: 0) == Data("\u{1b}[<64;1;1M".utf8))
        #expect(engine.mouse(.wheelDown, column: 99, row: 99) == Data("\u{1b}[<65;20;10M".utf8)) // clamped
        engine.receive(Data("\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l".utf8))
        #expect(engine.mouse(.click, column: 3, row: 2).isEmpty)
    }

    @Test func networkChangeKeepsALiveShellAndClosesADeadOne() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        await channel.recheckAfterNetworkChange()
        #expect(channel.connected)
        #expect(!channel.networkChanged)
        await fixture.setAlive(false)
        await channel.recheckAfterNetworkChange()
        #expect(!channel.connected)
        #expect(channel.reason.contains("network change"))
    }

    @Test func composerSendIsOnePasteThenEnterInBothPasteModes() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var bytes = fixture.bytes.makeAsyncIterator()
        try channel.submit("fix the build\nthen run tests")
        #expect(await bytes.next() == Data("fix the build\rthen run tests\r".utf8))
        channel.event(.data(Data("\u{1b}[?2004h".utf8))) // an agent TUI turns on bracketed paste
        try channel.submit("line one\nline two")
        #expect(await bytes.next() == Data("\u{1b}[200~line one\nline two\u{1b}[201~\r".utf8))
        try channel.submit("")
        #expect(await bytes.next() == Data("\r".utf8))
        channel.close(reason: "done")
        #expect(throws: SSHTerminalError.disconnected) { try channel.submit("late") }
    }

    @Test func startupCommandExitIsReportedAsTheCommandNotTheShell() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture(), command: "herdr")
        channel.event(.exitStatus(0))
        #expect(channel.reason == "`herdr` exited with status 0.")
    }

    @Test func herdrSnapshotStatusAndFailuresAreRead() throws {
        let json = #"{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"blocked","focused":false,"pane_id":"w1:p2","revision":3,"tab_id":"w1:t1","terminal_id":"t","workspace_id":"w1","terminal_title_stripped":"pi - dotfiles"},{"name":"rev","agent_status":"compacting","focused":true,"pane_id":"w2:p1","revision":1,"tab_id":"w2:t1","terminal_id":"u","workspace_id":"w2"}],"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"}],"workspaces":[{"active_tab_id":"w1:t1","agent_status":"blocked","focused":true,"label":"dotfiles","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w1"}]},"type":"session_snapshot"}}"#
        let snapshot = try HerdrRemote.snapshot(from: .init(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0))
        #expect(snapshot.needsAttention == 1)
        #expect(snapshot.agents(in: snapshot.workspaces[0]).map(\.displayName) == ["pi"])
        #expect(snapshot.agents[1].status == .unknown) // a newer state does not break decoding
        #expect(snapshot.tabLabel("w1:t1") == "1")

        #expect(throws: HerdrRemoteError.notInstalled) {
            try HerdrRemote.snapshot(from: .init(output: Data(), errorOutput: Data("fish: Unknown command: herdr".utf8), exitStatus: 127))
        }
        let refused = #"{"id":"x","error":{"code":"server_not_running","message":"no herdr server is running"}}"#
        #expect(throws: HerdrRemoteError.rejected("no herdr server is running")) {
            try HerdrRemote.snapshot(from: .init(output: Data(refused.utf8), errorOutput: Data(), exitStatus: 1))
        }
        // The focus call is one quoted word with the ID escaped, not the ID in
        // the clear; an ID that is not Herdr's own is never sent back.
        let focus = try #require(HerdrRemote.focusCommand(.agent("w1:p2"), machine: nil))
        #expect(focus.hasPrefix("sh -c '"))
        #expect(focus.contains("exec herdr agent focus \"$i\""))
        #expect(focus.contains(SSHTerminalRemoteShell.octalEncoded("w1:p2")))
        #expect(HerdrRemote.focusCommand(.workspace("w1; rm -rf ~"), machine: nil) == nil)
    }

    /// Every machine saved in the host's Herdr shows beside Local with its own
    /// state: one that is down reports its failure without hiding the others,
    /// a disabled one is listed but never asked, and waiting agents add up. A
    /// repeated or empty profile ID is dropped, since the sheet keys rows by it.
    @Test func herdrReadsLocalAndEverySavedMachine() async throws {
        func ok(_ json: String) -> SSHExecResult { .init(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0) }
        func snapshot(_ workspace: String, status: String) -> SSHExecResult {
            ok(#"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"\#(workspace)","focused":true}],"tabs":[],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"\#(status)","focused":true}]}}}"#)
        }
        let fixture = TerminalConnectionFixture()
        await fixture.setRunResult(ok(#"""
        [{"id":"aa11","label":"mac-mini","target":"mac-mini","session":"default","enabled":true,"selected":true},
         {"id":"bb22","label":"build box","target":"build","session":"default","enabled":true,"selected":false},
         {"id":"cc33","label":"old","target":"old","session":"default","enabled":false,"selected":false},
         {"id":"aa11","label":"copy","target":"mac-mini","session":"other","enabled":true,"selected":false},
         {"id":"","label":"blank","target":"x","session":"default","enabled":true,"selected":false}]
        """#), for: HerdrRemote.machinesCommand)
        await fixture.setRunResult(snapshot("oppi", status: "blocked"), for: "herdr api snapshot")
        await fixture.setRunResult(snapshot("tools", status: "blocked"), for: try #require(HerdrRemote.snapshotCommand(machine: "aa11")))
        await fixture.setRunResult(
            .init(output: Data(), errorOutput: Data("ssh: connect to host build port 22: Operation timed out".utf8), exitStatus: 255),
            for: try #require(HerdrRemote.snapshotCommand(machine: "bb22"))
        )
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        defer { channel.close(reason: "done") }
        let monitor = HerdrMonitor()

        await monitor.refresh(on: channel)
        #expect(await waitForMainActorCondition { monitor.machines.count == 4 && monitor.machines[2].failure != nil }, "every machine answered")

        #expect(monitor.machines.map(\.label) == ["Local", "mac-mini", "build box", "old"])
        #expect(monitor.machines.map { $0.snapshot?.workspaces.first?.label } == ["oppi", "tools", nil, nil])
        #expect(monitor.machines[2].failure == "ssh: connect to host build port 22: Operation timed out")
        #expect(monitor.machines[3].enabled == false && monitor.machines[3].failure == nil)
        #expect(monitor.needsAttention == 2)
        #expect(monitor.available)
        let asked = await fixture.runs.map(\.command)
        #expect(!asked.contains(try #require(HerdrRemote.snapshotCommand(machine: "cc33"))), "a disabled machine is not read")

        // mac-mini stops answering: its last report stays under the error,
        // but its waiting agent no longer counts.
        await fixture.setRunResult(
            .init(output: Data(), errorOutput: Data("ssh: connect to host mac-mini port 22: Connection refused".utf8), exitStatus: 255),
            for: try #require(HerdrRemote.snapshotCommand(machine: "aa11"))
        )
        await monitor.refresh(on: channel)
        #expect(await waitForMainActorCondition { monitor.machines[1].failure != nil })
        #expect(monitor.machines[1].snapshot?.workspaces.first?.label == "tools")
        #expect(monitor.machines[1].failure == "ssh: connect to host mac-mini port 22: Connection refused")
        #expect(monitor.needsAttention == 1)

        // A Herdr without saved machines answers the list with its usage: Local alone.
        let older = TerminalConnectionFixture()
        await older.setRunResult(snapshot("oppi", status: "idle"), for: "herdr api snapshot")
        await older.setRunResult(.init(output: Data(), errorOutput: Data("error: unrecognized subcommand 'machine'".utf8), exitStatus: 2),
                                 for: HerdrRemote.machinesCommand)
        let olderChannel = try SSHTerminalChannel()
        olderChannel.opened(older)
        defer { olderChannel.close(reason: "done") }
        let olderMonitor = HerdrMonitor()
        await olderMonitor.refresh(on: olderChannel)
        await olderMonitor.refresh(on: olderChannel)
        #expect(olderMonitor.machines.map(\.label) == ["Local"])
        #expect(olderMonitor.machines[0].failure == nil && olderMonitor.available)
        let listed = await older.runs.filter { $0.command == HerdrRemote.machinesCommand }.count
        #expect(listed == 1, "a Herdr without saved machines is asked once")
    }

    // MARK: - Rex overview

    nonisolated private static let rexSession = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
    nonisolated private static let rexEmpty = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"
    nonisolated private static let rexWindow1 = "window:01a18a26-6645-713c-97f1-2f1058c8c82f"
    nonisolated private static let rexWindow2 = "window:01a18a26-6645-713c-97f1-2f1058c8c830"
    nonisolated private static let rexPi = "block:01a18a26-6620-78ba-80d4-4e8caa018b37"
    nonisolated private static let rexPlain = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cb"
    nonisolated private static let rexBlocked = "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"
    nonisolated private static let rexNew = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cd"

    /// What Rex answers, shaped like a real host: a session with two windows
    /// (the second not active) holding a reporting pi, a plain shell, and a
    /// Claude whose tool waits on a permission, beside a session with no
    /// windows (Rex writes its `windows` as null). The tests change it between
    /// requests, as a Rex that moves on.
    private final class RexWorld: Sendable {
        struct State {
            var revision = 5
            var label = "shy-cedar"
            var extraBlock = false
            /// The nth `session.view` of the main session gets no answer until the test gives it.
            var holdViews: Set<Int> = []
            var views = 0
            var omitRevision = false
        }

        let state = Mutex(State())

        func view(revision: Int? = nil, label: String? = nil) -> String {
            let state = state.withLock { $0 }
            func block(_ id: String, creator: String = "com.superlogical.terminal") -> String {
                #"{"block_id":"\#(id)","label":"shell","creator_name":"\#(creator)"}"#
            }
            let first = [block(SSHTerminalTests.rexPi), block(SSHTerminalTests.rexPlain)] + (state.extraBlock ? [block(SSHTerminalTests.rexNew)] : [])
            let revisionField = state.omitRevision ? "" : #""revision":\#(revision ?? state.revision),"#
            return #"{\#(revisionField)"session_id":"\#(SSHTerminalTests.rexSession)","label":"\#(label ?? state.label)","active_window_id":"\#(SSHTerminalTests.rexWindow1)","windows":[{"window_id":"\#(SSHTerminalTests.rexWindow1)","label":"Window 1","focused_block_id":"\#(SSHTerminalTests.rexPi)","layers":[{"blocks":[\#(first.joined(separator: ","))]}]},{"window_id":"\#(SSHTerminalTests.rexWindow2)","label":"Window 2","focused_block_id":"\#(SSHTerminalTests.rexBlocked)","layers":[{"blocks":[\#(block(SSHTerminalTests.rexBlocked))]}]}]}"#
        }

        func answer(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
            let block = request.string("block_id") ?? ""
            switch request.method {
            case "session.attach_all":
                return .result(#"{"sessions":[{"session_id":"\#(SSHTerminalTests.rexSession)","label":"\#(state.withLock { $0.label })"},{"session_id":"\#(SSHTerminalTests.rexEmpty)","label":"empty"}]}"#)
            case "session.view":
                if request.string("session_id") == SSHTerminalTests.rexEmpty {
                    return .result(#"{"revision":1,"session_id":"\#(SSHTerminalTests.rexEmpty)","label":"empty","windows":null}"#)
                }
                guard request.string("session_id") == SSHTerminalTests.rexSession else {
                    return .refuse(code: "session_not_found", message: "no such session")
                }
                let held = state.withLock { state -> Bool in
                    state.views += 1
                    return state.holdViews.contains(state.views)
                }
                return held ? .hold : .result(view())
            case "com.superlogical.terminal.title":
                let titles = [
                    SSHTerminalTests.rexPi: "\u{03C0} - dotfiles", SSHTerminalTests.rexPlain: "~/.c/dotfiles",
                    SSHTerminalTests.rexBlocked: "claude", SSHTerminalTests.rexNew: "htop",
                ]
                return titles[block].map { .result(#"{"title":"\#($0)"}"#) } ?? .refuse(code: "not_found", message: "no block")
            case "com.superlogical.terminal.pwd":
                return block == SSHTerminalTests.rexPi
                    ? .result(#"{"pwd":"file://Mac-Studio.local/Users/duh/.config/dotfiles"}"#) : .result("{}")
            case "com.superlogical.terminal.program_status":
                switch block {
                case SSHTerminalTests.rexPi:
                    return .result(#"{"records":[{"app":"pi","effective_app":"pi","state":"idle","updated_at":"2026-10-29T18:48:48-07:00"}]}"#)
                case SSHTerminalTests.rexBlocked:
                    return .result(#"{"records":[{"app":"claude","effective_app":"claude","state":"working"},{"id":"bash","effective_app":"claude","state":"blocked","kind":"permission","msg":"Run rm -rf build?"}]}"#)
                default:
                    return .result(#"{"records":[]}"#)
                }
            default:
                return .refuse(code: "bad_request", message: "unexpected \(request.method)")
            }
        }

        func host() -> RexFakeHost { RexFakeHost { [self] in answer($0) } }
    }

    @MainActor private struct RexRig {
        let channel: SSHTerminalChannel
        let fixture: TerminalConnectionFixture
        let monitor: RexMonitor
        let task: Task<Void, Never>

        func stop() async {
            task.cancel()
            await task.value
            channel.close(reason: "done")
        }
    }

    /// Runs a Rex monitor on a connection whose Rex streams are `hosts`, one
    /// per subscription, and waits for the first one to be read.
    private func startRex(
        _ hosts: [RexFakeHost],
        waitForFirstRead: Bool = true,
        retryDelay: @escaping @MainActor (RexMonitor.Retry, Int) -> Duration = { _, _ in .milliseconds(10) }
    ) async throws -> RexRig {
        let fixture = TerminalConnectionFixture()
        for host in hosts { await fixture.queue(host) }
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let monitor = RexMonitor(publishDelay: .milliseconds(20), retryDelay: retryDelay)
        let task = Task { await monitor.run(on: channel) }
        let rig = RexRig(channel: channel, fixture: fixture, monitor: monitor, task: task)
        if waitForFirstRead {
            guard await waitForMainActorCondition(timeout: .seconds(5), { monitor.available }) else {
                await rig.stop()
                Issue.record("the overview never read Rex")
                throw CancellationError()
            }
        }
        return rig
    }

    private func views(_ host: RexFakeHost) -> [RexFakeHost.Request] {
        host.requests.filter { $0.method == "session.view" && $0.string("session_id") == Self.rexSession }
    }

    /// The sheet shows each session with its panes in window order: the
    /// program that reported names a pane, a blocked child record wins over a
    /// working root (Rex passes OSC 7501 through, so the kind survives), a pane
    /// that never reported has no status, and only the active window's focused
    /// pane reads as focused. First paint reads the whole server once over one
    /// stream: `session.attach_all` (never `session.attach`, which would put
    /// this client in every session's client list), a view per session, and
    /// three block calls per terminal. Cancelling the run closes the stream.
    @Test func rexOverviewReadsTheServerOnceOverOneStream() async throws {
        let host = RexWorld().host()
        let rig = try await startRex([host])
        let monitor = rig.monitor

        #expect(monitor.needsAttention == 1)
        #expect(await rig.fixture.streamCommands == [RexBridge.command])
        let requests = host.requests
        #expect(requests.map(\.method).sorted() == (
            ["session.attach_all"] + Array(repeating: "session.view", count: 2)
                + Array(repeating: "com.superlogical.terminal.title", count: 3)
                + Array(repeating: "com.superlogical.terminal.pwd", count: 3)
                + Array(repeating: "com.superlogical.terminal.program_status", count: 3)
        ).sorted())
        #expect(requests.first?.string("event_scope") == "all")

        let sessions = monitor.sections
        #expect(sessions.map(\.rows.first?.title) == ["shy-cedar", "empty"])
        #expect(sessions[1].rows.count == 1, "a session without windows lists no panes")
        let panes = sessions[0].rows.dropFirst().map { row -> (String, SSHTerminalOverviewRow.Kind) in (row.title, row.kind) }
        #expect(panes.map(\.0) == ["pi", "~/.c/dotfiles", "claude"])
        #expect(panes.map(\.1) == [
            .item(subtitle: "\u{03C0} - dotfiles \u{00B7} Window 1", focused: true, status: .known(.idle)),
            .item(subtitle: "Window 1", focused: false, status: .none),
            .item(subtitle: "Window 2", focused: false, status: .known(.needsApproval)),
        ])
        #expect(sessions[0].rows.first?.focus == nil, "a session row has nothing to focus")
        #expect(sessions[0].rows.last?.focus == .init(scope: Self.rexSession, id: Self.rexBlocked, isGroup: false))
        #expect(monitor.snapshot?.pane(session: Self.rexSession, block: Self.rexPi)?.pwd == "file://Mac-Studio.local/Users/duh/.config/dotfiles")

        await rig.stop()
        #expect(host.isClosed)
    }

    /// Events change the picture without another read: titles, folders, and
    /// status records patch their pane (a burst lands as its last value), a
    /// program that exits takes its status with it, a new block costs the
    /// view and its own three calls, and a closed block, a destroyed session,
    /// and a created one come and go. The only requests after first paint are
    /// those the new block and the re-created session need.
    @Test func rexEventsPatchTheOverviewInPlace() async throws {
        let world = RexWorld()
        let host = world.host()
        let rig = try await startRex([host])
        let monitor = rig.monitor
        let painted = host.requests.count
        func pane(_ block: String) -> RexSnapshot.Pane? { monitor.snapshot?.pane(session: Self.rexSession, block: block) }

        for index in 0..<40 {
            host.blockEvent(Self.rexSession, Self.rexPlain, "title_changed", #"{"title":"vim \#(index)"}"#)
        }
        host.blockEvent(Self.rexSession, Self.rexPlain, "pwd_changed", #"{"pwd":"file://h/tmp"}"#)
        host.blockEvent(Self.rexSession, Self.rexPlain, "program_status_changed",
                        #"{"id":"","record":{"state":"blocked","kind":"question","app":"vim"}}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.needsAttention == 2 })
        #expect(pane(Self.rexPlain)?.title == "vim 39")
        #expect(pane(Self.rexPlain)?.pwd == "file://h/tmp")
        #expect(pane(Self.rexPlain)?.displayName == "vim")

        host.blockEvent(Self.rexSession, Self.rexPlain, "program_status_removed", #"{"ids":[""],"reason":"prompt"}"#)
        host.blockEvent(Self.rexSession, Self.rexBlocked, "child_exited", #"{"exit_code":0}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.needsAttention == 0 })
        #expect(pane(Self.rexBlocked)?.records.isEmpty == true)
        #expect(host.requests.count == painted, "patching reads nothing")

        // A block appears: the event names only its id, so the view says what it is.
        world.state.withLock { $0.extraBlock = true; $0.revision = 6 }
        host.sessionEvent(Self.rexSession, "block_created", #"{"block_id":"\#(Self.rexNew)"}"#)
        host.viewChanged(Self.rexSession, revision: 6)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { pane(Self.rexNew)?.title == "htop" })
        #expect(host.requests.dropFirst(painted).map(\.method).sorted() == [
            "com.superlogical.terminal.program_status", "com.superlogical.terminal.pwd",
            "com.superlogical.terminal.title", "session.view",
        ])

        host.sessionEvent(Self.rexSession, "block_closed", #"{"block_id":"\#(Self.rexNew)"}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { pane(Self.rexNew) == nil })

        host.emit("session_destroyed", #"{"session_id":"\#(Self.rexSession)"}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.snapshot?.sessions.map(\.sessionID) == [Self.rexEmpty] })

        let beforeCreate = host.requests.count
        world.state.withLock { $0.extraBlock = false }
        host.emit("session_created", #"{"session":{"session_id":"\#(Self.rexSession)","label":"shy-cedar"}}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { pane(Self.rexBlocked)?.title == "claude" })
        #expect(monitor.snapshot?.sessions.map(\.sessionID) == [Self.rexEmpty, Self.rexSession])
        #expect(host.requests.dropFirst(beforeCreate).count == 1 + 3 * 3)

        await rig.stop()
    }

    /// Announcements of a newer view while one is being read cost one more
    /// read, not one each (and none until the one in flight answers); a reply
    /// older than the view already applied is dropped, and the read that
    /// follows brings the current one.
    @Test func rexReadsAtMostOneViewAtATimeAndDropsStaleOnes() async throws {
        let world = RexWorld()
        world.state.withLock { $0.holdViews = [2, 3, 4] }
        let host = world.host()
        let rig = try await startRex([host])
        let monitor = rig.monitor
        func label() -> String? { monitor.snapshot?.sessions.first?.label }

        host.viewChanged(Self.rexSession, revision: 6)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { views(host).count == 2 })
        host.viewChanged(Self.rexSession, revision: 7)
        host.viewChanged(Self.rexSession, revision: 8)
        host.viewChanged(Self.rexSession, revision: 5) // not newer than what is applied
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.requests.count == 12 + 1 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { views(host).count == 2 }, "one view in flight")

        host.respond(to: views(host)[1], world.view(revision: 6, label: "six"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { label() == "six" })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { views(host).count == 3 }, "dirtied again: read once more")

        host.respond(to: views(host)[2], world.view(revision: 4, label: "stale"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { views(host).count == 4 }, "still behind revision 8")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { label() == "six" }, "a reply older than the applied view is dropped")

        host.respond(to: views(host)[3], world.view(revision: 8, label: "eight"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { label() == "eight" })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { views(host).count == 4 })

        await rig.stop()
    }

    /// A subscription cancelled mid-read (the sheet's resync, then a push that
    /// stops the polls) is still waiting on calls when the next one starts: SSH
    /// reports the close only once the host answers it. Its leftover reads must
    /// not hold the new subscription up, and the old one ending later must not
    /// disturb the new one.
    @Test func rexACancelledSubscriptionStillWindingDownDoesNotStallTheNext() async throws {
        let slow = RexWorld()
        slow.state.withLock { $0.holdViews = [1] }
        let slowHost = RexFakeHost(reportsClose: false) { slow.answer($0) }
        let rig = try await startRex([slowHost], waitForFirstRead: false)
        let monitor = rig.monitor
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { views(slowHost).count == 1 })

        rig.task.cancel() // closes its stream; its held view and its run stay out
        #expect(slowHost.isClosed)
        let freshHost = RexWorld().host()
        await rig.fixture.queue(freshHost)
        let second = Task { await monitor.run(on: rig.channel) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.available }, "the next subscription reads Rex")
        #expect(monitor.needsAttention == 1)

        slowHost.end(status: 255) // the old stream's close finally comes back
        await rig.task.value
        #expect(monitor.failure == nil && monitor.available)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) { monitor.failure == nil })

        second.cancel()
        await second.value
        rig.channel.close(reason: "done")
    }

    /// A view that carries no revision is not asked for again and again.
    @Test func rexDoesNotRepeatAViewWithoutARevision() async throws {
        let world = RexWorld()
        let host = world.host()
        let rig = try await startRex([host])
        world.state.withLock { $0.omitRevision = true }

        host.viewChanged(Self.rexSession, revision: 7)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { views(host).count == 2 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { views(host).count == 2 })
        await rig.stop()
    }

    /// Rex replays nothing, so a stream that drops is caught up by reading
    /// everything again on a new one, after a short pause (the connection
    /// closed: 1 s, doubling; Rex not running, exit 4: 15 s, doubling). The
    /// last picture stays under the failure without lighting the badge. A host
    /// without `nc` (exit 127) is asked once.
    @Test func rexResyncsAfterADroppedStreamAndGivesUpOnAHostWithoutNc() async throws {
        let first = RexWorld()
        let second = RexWorld()
        second.state.withLock { $0.label = "renamed" }
        let firstHost = first.host(), secondHost = second.host()
        var retries: [(RexMonitor.Retry, Int)] = []
        let rig = try await startRex([firstHost, secondHost]) { retry, failures in
            retries.append((retry, failures))
            return retry == .notRunning ? .seconds(30) : .milliseconds(10)
        }
        let monitor = rig.monitor
        #expect(monitor.needsAttention == 1)

        firstHost.end(status: 255)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.snapshot?.sessions.first?.label == "renamed" && monitor.failure == nil })
        #expect(retries.map(\.0) == [.dropped] && retries.map(\.1) == [1])
        #expect(secondHost.requests.first?.method == "session.attach_all", "a new stream starts over")
        #expect(monitor.needsAttention == 1)
        #expect(await rig.fixture.streamCommands == [RexBridge.command, RexBridge.command])

        // Rex stops: the failure shows, the last list stays, the badge goes dark.
        secondHost.end(status: 4)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.failure == "Rex is not running on this host." })
        #expect(monitor.sections.first?.rows.first?.kind == .failure)
        #expect(monitor.sections.count == 3, "the last list stays under the failure")
        #expect(monitor.needsAttention == 0)
        #expect(retries.last?.0 == .notRunning && retries.last?.1 == 1)
        #expect(monitor.absence == .notRunning && !monitor.gaveUp)
        await rig.stop()
    }

    /// The sessions screen exists only to show Rex, so a host that cannot be
    /// read says why, in the bridge's exit status: no usable `nc` (126) and no Rex
    /// (5) are not asked again until `retry()` (a pull to refresh); a Rex
    /// that is installed but not running (4) keeps being asked, with backoff.
    @Test func rexTellsNoNcNoRexAndRexNotRunningApart() async throws {
        let cases: [(status: Int, absence: RexAbsence, gaveUp: Bool)] = [
            (126, .noNc, true), (5, .notInstalled, true), (4, .notRunning, false),
        ]
        for expected in cases {
            let host = RexFakeHost { _ in .hold }
            let rig = try await startRex([host], waitForFirstRead: false) { _, _ in .seconds(30) }
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) { host.isOpen })
            host.end(status: expected.status)
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.monitor.absence == expected.absence })
            #expect(rig.monitor.gaveUp == expected.gaveUp)
            #expect(!rig.monitor.available)
            #expect(rig.monitor.sections.first?.rows.first?.title == expected.absence.advice)
            if expected.gaveUp {
                await rig.task.value // `run` has returned: nothing is asked again
                #expect(await rig.fixture.streamCommands.count == 1)
                rig.monitor.retry()
                #expect(rig.monitor.absence == nil && !rig.monitor.gaveUp)
            } else {
                #expect(rig.monitor.failure == "Rex is not running on this host.")
                await rig.stop()
                continue
            }
            rig.channel.close(reason: "done")
        }
        let advice = [RexAbsence.noNc, .notInstalled, .notRunning].map(\.advice)
        #expect(Set(advice).count == 3, "each state has advice of its own")
    }

    /// The sessions screen follows Rex over its own `SSHConnection`, not a
    /// terminal channel: anything that opens a stream will do, and the run
    /// ends when that connection goes.
    @Test func rexIsFollowedOverAnyStreamHost() async throws {
        let host = RexWorld().host()
        let stream = FakeStreamHost(host)
        let monitor = RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .milliseconds(10) })
        let task = Task { await monitor.run(over: stream) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.available })
        #expect(monitor.needsAttention == 1)

        stream.isConnected = false
        host.end(status: 255)
        await task.value
        #expect(monitor.available, "the last list stays")
    }

    @MainActor private final class FakeStreamHost: RexStreamHost {
        var isConnected = true
        private let host: RexFakeHost
        init(_ host: RexFakeHost) { self.host = host }
        func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
            host.open(sink: sink)
        }

        func run(_ command: String, input: Data) async throws -> SSHExecResult {
            throw SSHConnectionError.commandRequestRejected
        }
    }

    @Test func rexRetriesBackOffFromOneSecondOrFifteenAndStopAtTheirCaps() {
        #expect((1...8).map { RexMonitor.Retry.delay(.dropped, failures: $0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { .seconds($0) })
        #expect((1...5).map { RexMonitor.Retry.delay(.notRunning, failures: $0) } == [15, 30, 60, 60, 60].map { .seconds($0) })
    }

    /// Opening the sheet reads Rex once more over the open stream (a safety
    /// net for what events missed), and so does a pull to refresh, which
    /// waits for it. Setting the flag again changes nothing.
    @Test func rexOpeningTheSheetReadsTheServerOnceMore() async throws {
        let world = RexWorld()
        let host = world.host()
        let rig = try await startRex([host])
        let monitor = rig.monitor
        func attaches() -> Int { host.requests.filter { $0.method == "session.attach_all" }.count }
        #expect(attaches() == 1)

        world.state.withLock { $0.label = "missed"; $0.revision = 9 } // no event told us
        monitor.watching = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.snapshot?.sessions.first?.label == "missed" })
        #expect(attaches() == 2)
        #expect(await rig.fixture.streamCommands.count == 1, "the same stream")

        monitor.watching = true
        world.state.withLock { $0.label = "pulled" }
        await monitor.refresh(on: rig.channel)
        #expect(monitor.snapshot?.sessions.first?.label == "pulled")
        #expect(attaches() == 3)

        await rig.stop()
    }

    /// A tapped pane opens on this device as the pane the list names, with
    /// nothing sent to Rex. A pane the list no longer has is refused.
    @Test func rexOpensATappedPane() async throws {
        let host = RexWorld().host()
        let rig = try await startRex([host])
        let monitor = rig.monitor
        var opened: [RexPaneTarget] = []
        monitor.openPane = { opened.append($0) }
        let reads = host.requests.count

        #expect(await monitor.activate(.init(scope: Self.rexSession, id: Self.rexBlocked, isGroup: false), on: rig.channel))
        #expect(opened == [RexPaneTarget(sessionID: Self.rexSession, blockID: Self.rexBlocked, label: "claude")])
        #expect(host.requests.count == reads, "opening a pane asks Rex nothing")

        #expect(!(await monitor.activate(.init(scope: Self.rexSession, id: "block:gone", isGroup: false), on: rig.channel)))
        #expect(!(await monitor.activate(.init(scope: nil, id: Self.rexSession, isGroup: true), on: rig.channel)))
        #expect(monitor.focusFailure == "This pane is no longer in Rex.")
        #expect(opened.count == 1)
        await rig.stop()
    }

    /// A Rex terminal draws its session on the screen: the bar's pane switcher
    /// (the shown pane's name and "N of M"), the minimap of the shown pane's
    /// window at the grid's top right, and a swipe on the grid with VoiceOver's
    /// Next and Previous Pane as its twins. A minimap cell and a VoiceOver
    /// action show a pane the same way; each slides the grid, and the grid shows
    /// the new pane's own screen once its snapshot is on it.
    @Test func aRexTerminalDrawsItsSwitcherAndMinimapAndTwinsTheSwipeForVoiceOver() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b", "c"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        func control(_ id: String) -> UIView? {
            mounted.find { $0.accessibilityIdentifier == id }
        }
        func shown(_ id: String) -> Bool {
            guard var view = control(id) else { return false }
            while true {
                if view.isHidden || view.alpha == 0 { return false }
                guard let parent = view.superview else { return true }
                view = parent
            }
        }
        func selected(_ id: String) -> Bool { control(id)?.accessibilityTraits.contains(.selected) == true }
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            mounted.host.view.layoutIfNeeded()
            return shown("sshTerminal.bar.rexPanes")
        }

        let switcher = try #require(control("sshTerminal.bar.rexPanes") as? UIButton)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            mounted.host.view.layoutIfNeeded()
            return switcher.accessibilityValue == "title a, 1 of 3"
        })
        #expect(switcher.accessibilityLabel == "Pane", "the label is the purpose; the value is the pane")
        // A tap opens the Rex panel; touch and hold shows the panes menu.
        #expect(!switcher.showsMenuAsPrimaryAction && switcher.menu != nil)
        // The minimap is part of the screen but not on it: hidden at rest.
        let minimap = try #require(mounted.find { $0 is SSHTerminalRexMinimapView } as? SSHTerminalRexMinimapView)
        minimap.hideDelay = .milliseconds(150)
        #expect(!(0...2).contains { shown("sshTerminal.rexMinimap.\($0)") })
        // The minimap sits at the grid's top right, the switcher in a pill of its
        // own at the bottom trailing corner, past the bar's pill that ends with ….
        let grid = try #require(mounted.controller.gridView)
        let corner = minimap.convert(CGPoint(x: minimap.bounds.maxX, y: minimap.bounds.minY), to: grid)
        #expect(corner.x > grid.bounds.width - 24 && corner.y < 24)
        let more = try #require(control("sshTerminal.more"))
        #expect(switcher.superview !== more.superview)
        #expect(switcher.convert(CGPoint.zero, to: mounted.controller.view).x > more.convert(CGPoint.zero, to: mounted.controller.view).x)
        #expect(grid.paneTransition.phase == .idle)

        // A swipe shows it, with the first pane's cell selected and the cells
        // labelled with their panes; letting go short hides it again.
        #expect(grid.paneTransition.beginDrag())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { (0...2).allSatisfy { shown("sshTerminal.rexMinimap.\($0)") } })
        #expect(selected("sshTerminal.rexMinimap.0") && control("sshTerminal.rexMinimap.2")?.accessibilityLabel == "title c")
        grid.paneTransition.endDrag(committing: nil, velocityX: 0)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { minimap.isHidden })

        // A minimap cell shows its pane: the switcher and the highlight follow,
        // and the grid is covered until that pane's own screen is on it.
        _ = grid.paneTransition.beginDrag()
        let cell = try #require(control("sshTerminal.rexMinimap.2") as? UIControl)
        #expect(minimap.hitTest(minimap.convert(cell.center, from: cell.superview), with: nil) === cell, "a visible map takes taps")
        grid.paneTransition.endDrag(committing: nil, velocityX: 0)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        cell.sendActions(for: .touchUpInside)
        #expect(grid.paneTransition.phase != .idle && grid.paneTransition.isPlaceholderShown)
        #expect(grid.paneTransition.placeholderTitle == "title c")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            switcher.accessibilityValue == "title c, 3 of 3" && selected("sshTerminal.rexMinimap.2")
        })
        let target = try #require(control("sshTerminal.rexMinimap.2")).frame
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { minimap.highlightFrame == target }, "the highlight moves to the new cell")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle }, "the cover lifts")
        #expect(!grid.paneTransition.isPlaceholderShown)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { minimap.isHidden }, "and the map goes again")

        // VoiceOver's actions are the swipe's owner: the grid says so, and they move one pane.
        let actions = try #require(grid.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Next Pane", "Previous Pane", "New Pane"])
        #expect(grid.stepPane(-1) == true && grid.stepPane(1) == true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        #expect(grid.stepPane(1) == false, "the last pane has none after it")
        #expect(grid.paneTransition.phase == .idle, "nothing slid for a step that did not happen")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        #expect(grid.stepPane(-1) == true && grid.stepPane(-1) == true && grid.stepPane(-1) == false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of a") && grid.paneTransition.phase == .idle })
        #expect(switcher.accessibilityValue == "title a, 1 of 3")
        await rig.stop()
    }

    /// The layout minimap is for the moment of a switch: hidden at rest (no
    /// touches, nothing for VoiceOver), on screen while a swipe is down and
    /// after it commits while the highlight moves, and gone `hideDelay` after
    /// the switch settles, whether it committed, sprang back, or was a
    /// VoiceOver step. A switch with no finger flashes it the same way.
    @Test func theRexMinimapShowsOnlyWhileSwitchingPanes() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b", "c"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        func findSwitcher() -> UIButton? {
            mounted.host.view.layoutIfNeeded()
            return mounted.find { $0.accessibilityIdentifier == "sshTerminal.bar.rexPanes" } as? UIButton
        }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { findSwitcher()?.accessibilityValue == "title a, 1 of 3" })
        let switcher = try #require(findSwitcher())
        let minimap = try #require(mounted.find { $0 is SSHTerminalRexMinimapView } as? SSHTerminalRexMinimapView)
        let grid = try #require(mounted.controller.gridView)
        minimap.hideDelay = .milliseconds(120)
        func onScreen() -> Bool { !minimap.isHidden && minimap.alpha > 0 }
        func inert() -> Bool { minimap.isHidden && !minimap.isUserInteractionEnabled && minimap.accessibilityElementsHidden }
        func cell(_ index: Int) -> UIView? { mounted.find { $0.accessibilityIdentifier == "sshTerminal.rexMinimap.\(index)" } }

        // At rest, and after opening: hidden, with no touches and no accessibility.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) { inert() })
        #expect(minimap.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)

        // A swipe down shows it and keeps it, however long the finger stays.
        #expect(grid.paneTransition.beginDrag())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { onScreen() && minimap.alpha == 1 })
        #expect(minimap.isUserInteractionEnabled && !minimap.accessibilityElementsHidden)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) { onScreen() }, "it stays while dragging")
        grid.paneTransition.drag(translationX: -150, neighbour: "title b", offersNewPane: true)
        #expect(onScreen())

        // Letting go past the threshold commits: still there, the highlight moves, then it fades away.
        #expect(grid.paneStepping?.step(1) == true)
        grid.paneTransition.endDrag(committing: 1, velocityX: -800)
        #expect(onScreen())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { switcher.accessibilityValue == "title b, 2 of 3" })
        let second = try #require(cell(1)).frame
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { minimap.highlightFrame == second }, "the highlight moves to the new cell")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") && grid.paneTransition.phase == .idle })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() }, "gone after the switch settles")

        // A short swipe springs back: shown while down, gone after, the pane unchanged.
        #expect(grid.paneTransition.beginDrag())
        #expect(onScreen())
        grid.paneTransition.drag(translationX: 20, neighbour: "title a", offersNewPane: true)
        grid.paneTransition.endDrag(committing: nil, velocityX: 0)
        #expect(onScreen(), "still there while the screen springs back")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() })
        #expect(switcher.accessibilityValue == "title b, 2 of 3")

        // VoiceOver's Next Pane has no finger and flashes it the same way.
        #expect(grid.stepPane(1) == true)
        #expect(onScreen())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { switcher.accessibilityValue == "title c, 3 of 3" })
        let third = try #require(cell(2)).frame
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { minimap.highlightFrame == third })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() })

        // A step that does not happen shows nothing.
        #expect(grid.stepPane(1) == false)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { inert() })
        await rig.stop()
    }

    /// A new switch during the fade-out keeps the map (and its touches). A
    /// switch that starts where there is no map to draw shows it once the map
    /// is available, and a map that becomes unavailable fades out.
    @Test func aNewSwitchDuringTheMinimapsFadeOutKeepsItAndAvailabilityFollowsTheSwitch() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        let minimap = SSHTerminalRexMinimapView()
        host.view.addSubview(minimap)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        minimap.hideDelay = .milliseconds(50)
        host.view.layoutIfNeeded()
        func inert() -> Bool { minimap.isHidden && !minimap.isUserInteractionEnabled && minimap.accessibilityElementsHidden }
        func shown() -> Bool { minimap.alpha == 1 && !minimap.isHidden && minimap.isUserInteractionEnabled && !minimap.accessibilityElementsHidden }

        // A switch from a window of one pane: nothing to draw yet.
        minimap.setSwitching(true)
        #expect(inert())
        // Into a window of several panes: the map arrives with the new window, mid-switch.
        minimap.isAvailable = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { shown() })
        minimap.setSwitching(false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !minimap.isUserInteractionEnabled }, "the fade-out began")
        #expect(!minimap.isHidden && minimap.accessibilityElementsHidden, "a fading map takes no touches and is not read")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() })

        // A new switch during the fade-out keeps it.
        minimap.setSwitching(true)
        minimap.setSwitching(false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !minimap.isUserInteractionEnabled })
        minimap.setSwitching(true)
        #expect(minimap.isUserInteractionEnabled && !minimap.accessibilityElementsHidden)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { shown() })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) { shown() }, "the hide was cancelled")

        // A switch before the delay is up cancels the pending hide.
        minimap.setSwitching(false)
        minimap.setSwitching(true)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { shown() })

        // Out of a multi-pane window mid-switch: the map fades out instead of vanishing.
        minimap.isAvailable = false
        #expect(!minimap.isUserInteractionEnabled && minimap.accessibilityElementsHidden)
        #expect(!minimap.isHidden, "fading, not cut")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() })

        // Reset (another terminal) is gone at once, and a later switch shows nothing.
        minimap.isAvailable = true
        minimap.setSwitching(true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { shown() })
        minimap.reset()
        #expect(inert())
        minimap.isAvailable = true
        #expect(inert(), "the switch that was running belonged to the terminal left")
    }

    /// A swipe from a window of one pane into a window of several: the map
    /// arrives with the new window while the switch is still under way, then
    /// goes after it settles.
    @Test func theRexMinimapAppearsWhenASwipeEntersAWindowOfSeveralPanes() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b", "c"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        let (a, b, c) = (RexSessionTerminalTests.block("a"), RexSessionTerminalTests.block("b"), RexSessionTerminalTests.block("c"))
        func leaf(_ id: String, _ x: Double, _ width: Double) -> String { #"{"rect":[\#(x),0,\#(width),1],"block_id":"\#(id)"}"# }
        func block(_ id: String) -> String { #"{"block_id":"\#(id)","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell"}"# }
        func window(_ id: String, layout: String, blocks: [String]) -> String {
            #"{"window_id":"window:\#(id)","label":"Window \#(id)","focused_block_id":"\#(blocks[0])","layers":[{"layer_id":"layer:\#(id)","kind":"tiled","bounds":[0,0,1,1],"layout":\#(layout),"blocks":[\#(blocks.map(block).joined(separator: ","))]}]}"#
        }
        let split = #"{"rect":[0,0,1,1],"split":{"split_id":"split:b","direction":"horizontal","ratio":0.5,"before":\#(leaf(b, 0, 0.5)),"after":\#(leaf(c, 0.5, 0.5))}}"#
        let view = #"{"revision":9,"session_id":"\#(RexSessionTerminalTests.session)","label":"preview","active_window_id":"window:1","windows":[\#(window("1", layout: leaf(a, 0, 1), blocks: [a])),\#(window("2", layout: split, blocks: [b, c]))]}"#
        rig.fake.setView(view, revision: 9)
        rig.fake.viewChanged(revision: 9)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.model.state.panes.count == 3 && rig.model.state.panes.first?.windowID != rig.model.state.panes.last?.windowID
        })
        #expect(!rig.model.state.showsMinimap, "the first pane's window is one pane")

        let minimap = try #require(mounted.find { $0 is SSHTerminalRexMinimapView } as? SSHTerminalRexMinimapView)
        let grid = try #require(mounted.controller.gridView)
        minimap.hideDelay = .milliseconds(120)
        func shown() -> Bool { minimap.alpha == 1 && !minimap.isHidden && minimap.isUserInteractionEnabled && !minimap.accessibilityElementsHidden }
        func inert() -> Bool { minimap.isHidden && !minimap.isUserInteractionEnabled && minimap.accessibilityElementsHidden }
        #expect(inert())

        // The finger is down and the session already took the switch: the new window's map is there.
        #expect(grid.paneTransition.beginDrag())
        #expect(inert(), "no map for a window of one pane")
        grid.paneTransition.drag(translationX: -150, neighbour: "title b", offersNewPane: true)
        #expect(grid.paneStepping?.step(1) == true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.showsMinimap && shown() }, "the map arrives with the new window")
        grid.paneTransition.endDrag(committing: 1, velocityX: -800)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") && grid.paneTransition.phase == .idle })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { inert() }, "and goes after the switch settles")
        await rig.stop()
    }

    /// The switcher draws the shown pane's own icon: a monogram for a pane
    /// whose program reports, the terminal glyph for a plain shell. Moving to
    /// another pane rolls to its icon; the accessibility label stays the pane's name.
    @Test func theSwitcherDrawsTheShownPanesIconAndRollsToTheNext() async throws {
        let button = SSHTerminalRexPanesButton()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        host.view.addSubview(button)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let panes: [RexSessionState.Pane] = [
            .init(blockID: "a", name: "shell"),
            .init(blockID: "b", name: "\u{03C0} - oppi", program: "\u{03C0} - oppi"),
            .init(blockID: "c", name: "\u{2733} Fixing the build", program: "\u{2733} Fixing the build"),
        ]
        func state(shown: String) -> RexSessionState { RexSessionState(panes: panes, shown: shown, minimap: []) }
        func iconViews() -> Int { button.subviews.first { $0 is SSHTerminalRexPaneGlyphView }?.subviews.count ?? 0 }

        button.apply(state: state(shown: "a"), tint: .white)
        #expect(button.icon == .terminal && !button.isHidden)
        #expect(button.accessibilityLabel == "Pane" && button.accessibilityValue == "shell, 1 of 3")
        #expect(iconViews() == 1, "the first draw does not roll")

        button.apply(state: state(shown: "b"), tint: .white)
        #expect(button.icon == .monogram("\u{03C0}"))
        #expect(button.accessibilityLabel == "Pane" && button.accessibilityValue == "\u{03C0} - oppi, 2 of 3")
        #expect(iconViews() == 2, "the old icon leaves while the new one arrives")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { iconViews() == 1 })

        button.apply(state: state(shown: "c"), tint: .white)
        #expect(button.icon == .monogram("\u{2733}") && button.accessibilityValue == "\u{2733} Fixing the build, 3 of 3")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { iconViews() == 1 })

        // A program that starts reporting in the pane on screen changes its icon in place.
        var reporting = state(shown: "c")
        reporting.panes[2].program = nil
        button.apply(state: reporting, tint: .white)
        #expect(button.icon == .terminal && iconViews() == 1)

        // One pane still has the control: the panel holds the status and the other sessions.
        button.apply(state: RexSessionState(panes: [panes[0]], shown: "a", minimap: []), tint: .white)
        #expect(!button.isHidden)
        // Not a Rex session: no control.
        button.apply(state: nil, tint: .white)
        #expect(button.isHidden)
    }

    /// The switcher's menu lists the panes in strip order with the shown one
    /// checked, in one section per window when the session has several, and a
    /// choice is the pane's block id handed to the owner. New Pane ends it, in a
    /// group of its own, and asks the owner for a pane.
    @Test func theSwitcherMenuListsPanesInStripOrderAndSectionsWindows() throws {
        func state(windows: Bool) -> RexSessionState {
            RexSessionState(
                panes: [
                    .init(blockID: "a", name: "pi", windowID: "w1", windowName: "Main"),
                    .init(blockID: "b", name: "logs", windowID: "w1", windowName: "Main"),
                    .init(blockID: "c", name: "shell", windowID: windows ? "w2" : "w1", windowName: windows ? "Scratch" : "Main"),
                ],
                shown: "b", minimap: []
            )
        }
        var chosen: [String] = []
        var created = 0
        let flat = SSHTerminalRexPaneMenu.elements(state: state(windows: false), select: { chosen.append($0) }, newPane: { created += 1 })
        let actions = flat.compactMap { $0 as? UIAction }
        #expect(actions.map(\.title) == ["pi", "logs", "shell"])
        #expect(actions.map(\.state) == [.off, .on, .off], "the shown pane is checked")
        #expect(actions.map(\.accessibilityIdentifier) == (0...2).map { "sshTerminal.rexPanes.\($0)" })
        actions[2].performWithSender(nil, target: nil)
        #expect(chosen == ["c"])
        let newPane = try #require((flat.last as? UIMenu)?.children.first as? UIAction)
        #expect(flat.last is UIMenu && (flat.last as? UIMenu)?.options.contains(.displayInline) == true, "its own group, last")
        #expect(newPane.title == "New Pane" && newPane.accessibilityIdentifier == "sshTerminal.rexPanes.new")
        newPane.performWithSender(nil, target: nil)
        #expect(created == 1 && chosen == ["c"], "New Pane is not a pane choice")

        let sectioned = SSHTerminalRexPaneMenu.elements(state: state(windows: true), select: { chosen.append($0) }, newPane: { created += 1 })
        let menus = sectioned.compactMap { $0 as? UIMenu }
        #expect(menus.map(\.title) == ["Main", "Scratch", ""])
        #expect(menus.map { $0.children.compactMap { ($0 as? UIAction)?.title } } == [["pi", "logs"], ["shell"], ["New Pane"]])
        #expect(menus.allSatisfy { $0.options.contains(.displayInline) })
        (menus[1].children[0] as? UIAction)?.performWithSender(nil, target: nil)
        #expect(chosen == ["c", "c"])
        (menus[2].children[0] as? UIAction)?.performWithSender(nil, target: nil)
        #expect(created == 2)
    }

    /// One pane has the Rex control but no minimap, and no pane to step to; it can
    /// still grow: a swipe past it and VoiceOver's New Pane open another.
    @Test func aRexTerminalOfOnePaneHasTheRexControlButNoMinimapAndNothingToStepTo() async throws {
        let rig = try await RexSessionTerminalTests().open(["a"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        for _ in 0..<4 {
            await Task.yield()
            mounted.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        func visible(_ prefix: String) -> Bool {
            mounted.find {
                $0.accessibilityIdentifier?.hasPrefix(prefix) == true && !$0.isHidden
                    && sequence(first: $0, next: \.superview).allSatisfy { !$0.isHidden }
            } != nil
        }
        #expect(visible("sshTerminal.bar.rexPanes"), "the one Rex control is there for any Rex pane")
        #expect(!visible("sshTerminal.rexMinimap."))
        #expect(mounted.controller.gridView?.paneStepping != nil, "a session of one pane can still open a new one")
        #expect(mounted.controller.gridView?.stepPane(1) == false && mounted.controller.gridView?.stepPane(-1) == false)
        #expect(mounted.controller.gridView?.accessibilityCustomActions?.map(\.name) == ["Next Pane", "Previous Pane", "New Pane"])
        await rig.stop()
    }

    /// A pan recognizer that reports what a test says, so the grid's own swipe
    /// handler (and its release decision) runs as it does under a finger.
    private final class ScriptedPan: UIPanGestureRecognizer {
        var scriptedState = UIGestureRecognizer.State.possible
        var scriptedTravel = CGPoint.zero
        var scriptedVelocity = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { scriptedState }
            set { scriptedState = newValue }
        }

        override func translation(in view: UIView?) -> CGPoint { scriptedTravel }
        override func velocity(in view: UIView?) -> CGPoint { scriptedVelocity }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) { scriptedTravel = translation }
    }

    @MainActor private func swipe(
        _ grid: SSHTerminalGridView, _ state: UIGestureRecognizer.State, travel: CGFloat, velocity: CGFloat = 0, with pan: ScriptedPan
    ) {
        pan.scriptedState = state
        pan.scriptedTravel = CGPoint(x: travel, y: 0)
        pan.scriptedVelocity = CGPoint(x: velocity, y: 0)
        _ = grid.perform(NSSelectorFromString("paneSwiped:"), with: pan)
    }

    /// What a `session.new_split` request asked of Rex.
    private struct NewSplitRequest {
        let anchor: String?
        let direction: String?
        let side: String?
        let focus: Bool?
        let flavor: String?
        let folder: String?
        let blocks: Int

        init(_ request: RexFakeHost.Request) throws {
            let body = try #require(JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any])
            let layout = body["layout"] as? [String: Any]
            let block = layout?["block"] as? [String: Any]
            anchor = body["anchor_id"] as? String
            direction = body["direction"] as? String
            side = body["side"] as? String
            focus = body["focus"] as? Bool
            flavor = block?["flavor"] as? String
            folder = (block?["options"] as? [String: Any])?["cwd"] as? String
            blocks = layout?.keys.filter { $0 == "block" }.count ?? 0
        }
    }

    /// Swiping left past the last pane opens a new one: the release decides by
    /// the same distance rule as a switch (short springs back and asks Rex
    /// nothing; the first pane's edge keeps its rubber band), and a release past
    /// it asks Rex for one shell, after the shown pane, horizontal, in that
    /// pane's folder, without moving the host's focus. The terminal then shows
    /// the pane Rex made, through the normal switch: its snapshot reveals, the
    /// switcher counts it, and typing goes to it.
    @Test func swipingPastTheLastRexPaneOpensANewPaneAfterTheShownOne() async throws {
        let rig = try await RexSessionTerminalTests().open(
            ["a", "b"], folders: ["b": "file://mac-studio.local/Users/chen/my%20proj"]
        )
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        func switcher() -> UIButton? {
            mounted.host.view.layoutIfNeeded()
            return mounted.find { $0.accessibilityIdentifier == "sshTerminal.bar.rexPanes" } as? UIButton
        }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { switcher()?.accessibilityValue == "title a, 1 of 2" })
        let grid = try #require(mounted.controller.gridView)
        let pan = ScriptedPan()

        // The first pane's edge: still a rubber band, no card, nothing asked.
        swipe(grid, .began, travel: 0, with: pan)
        swipe(grid, .changed, travel: 120, with: pan)
        #expect(grid.paneTransition.phase == .dragging && !grid.paneTransition.isShowingNewPaneCard)
        swipe(grid, .ended, travel: 120, velocity: 400, with: pan)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        #expect(rig.fake.requests("session.new_split").isEmpty)

        #expect(grid.stepPane(1))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") && grid.paneTransition.phase == .idle })
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { switcher()?.accessibilityValue == "title b, 2 of 2" })

        // Short and slow: the card dims, the screen springs back, Rex is asked nothing.
        swipe(grid, .began, travel: 0, with: pan)
        swipe(grid, .changed, travel: -30, with: pan)
        #expect(grid.paneTransition.isShowingNewPaneCard && !grid.paneTransition.isNewPaneArmed)
        swipe(grid, .ended, travel: -30, velocity: -100, with: pan)
        #expect(!grid.paneTransition.isAwaitingCreation)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle && !grid.paneTransition.isPlaceholderShown })
        #expect(rig.fake.requests("session.new_split").isEmpty && rig.model.state.panes.count == 2)

        // Far enough: the card is lit, and letting go opens the pane.
        swipe(grid, .began, travel: 0, with: pan)
        swipe(grid, .changed, travel: -80, with: pan)
        #expect(grid.paneTransition.isNewPaneArmed)
        swipe(grid, .ended, travel: -80, velocity: -300, with: pan)
        #expect(grid.paneTransition.isAwaitingCreation, "the cover stays while Rex answers")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of new pane") }, "the new pane's snapshot is on the grid")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle && !grid.paneTransition.isPlaceholderShown })

        let splits = rig.fake.requests("session.new_split")
        #expect(splits.count == 1)
        let split = try NewSplitRequest(try #require(splits.first))
        #expect(split.anchor == "block:b" && split.direction == "horizontal" && split.side == "after" && split.focus == false)
        #expect(split.flavor == "com.superlogical.terminal.shell" && split.blocks == 1)
        #expect(split.folder == "/Users/chen/my proj", "the shown pane's folder, from its OSC 7 report")
        #expect(rig.fake.requests("com.superlogical.terminal.pwd").first?.string("block_id") == "block:b")

        // The new pane went through the switch path, and the host's focus never moved.
        let created = "block:created-1"
        #expect(rig.model.state.shown == created && rig.model.state.panes.map(\.blockID) == ["block:a", "block:b", created])
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { switcher()?.accessibilityValue == "new shell, 3 of 3" })
        let methods = rig.fake.requests.filter { $0.string("block_id") == created || $0.method == "session.own_block" }
        let own = try #require(methods.firstIndex { $0.method == "session.own_block" && $0.payload.contains(created) })
        let connect = try #require(methods.firstIndex { $0.method == "data.connect" && $0.string("block_id") == created })
        #expect(own < connect)
        #expect(!rig.fake.requests.contains { $0.method.contains("focus") })
        rig.channel.send(Data("ls\r".utf8))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("com.superlogical.terminal.write").last?.string("block_id") == created
        })
        await rig.stop()
    }

    /// A pane Rex refuses springs back to the pane the terminal was on, with a
    /// notice that says so: no crash, nothing stuck over the grid, and the next
    /// try works. Only one pane is opened at a time.
    @Test func aNewPaneRexRefusesSpringsBackWithAnError() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b"], first: "b")
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        let grid = try #require(mounted.controller.gridView)
        func notice() -> UIView? {
            mounted.find { $0.accessibilityIdentifier == "sshTerminal.openNotice" && !$0.isHidden }
        }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            mounted.host.view.layoutIfNeeded()
            return rig.model.state.panes.count == 2 && grid.paneStepping != nil
        })

        rig.fake.refuse(["session.new_split"])
        #expect(grid.paneStepping?.canCreatePane() == true)
        #expect(grid.createPane())
        #expect(!grid.createPane(), "one pane at a time")
        #expect(grid.paneStepping?.canCreatePane() == false, "while one opens, a swipe past the last pane offers no card")
        #expect(grid.paneTransition.isAwaitingCreation)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { notice() != nil })
        #expect(notice()?.accessibilityLabel?.hasPrefix("Could not open a new pane.") == true)
        #expect(grid.paneStepping?.canCreatePane() == true, "and offers it again once the failure is settled")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle && !grid.paneTransition.isPlaceholderShown })
        #expect(rig.model.state.shown == "block:b" && rig.model.state.panes.count == 2, "back on the pane it was on")
        #expect(rig.shows("screen of b"))
        rig.channel.send(Data("ls\r".utf8))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("com.superlogical.terminal.write").last?.string("block_id") == "block:b"
        })
        #expect(!rig.fake.requests.contains { $0.method == "data.connect" && $0.string("block_id")?.hasPrefix("block:created") == true })

        // The next try is not blocked by the failure.
        rig.fake.refuse([])
        #expect(grid.createPane())
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of new pane") })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        #expect(rig.model.state.shown == "block:created-1")
        await rig.stop()
    }

    /// VoiceOver's New Pane action and the switcher menu's New Pane item open a
    /// pane the way the swipe does, and a session of one pane can grow: it has
    /// no switcher until the second pane is there.
    @Test func theNewPaneActionAndMenuItemOpenAPaneToo() async throws {
        let rig = try await RexSessionTerminalTests().open(["a"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss() }
        func switcher() -> SSHTerminalRexPanesButton? {
            mounted.host.view.layoutIfNeeded()
            return mounted.find { $0.accessibilityIdentifier == "sshTerminal.bar.rexPanes" } as? SSHTerminalRexPanesButton
        }
        let grid = try #require(mounted.controller.gridView)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneStepping != nil })
        let action = try #require(grid.accessibilityCustomActions?.first { $0.name == "New Pane" })
        let pan = ScriptedPan()

        // The only pane's first edge is a rubber band; its far edge offers a pane.
        swipe(grid, .began, travel: 0, with: pan)
        swipe(grid, .changed, travel: 100, with: pan)
        #expect(!grid.paneTransition.isShowingNewPaneCard)
        swipe(grid, .ended, travel: 100, velocity: 0, with: pan)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        #expect(rig.fake.requests("session.new_split").isEmpty)

        #expect(action.actionHandler?(action) == true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of new pane") })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        let first = try NewSplitRequest(try #require(rig.fake.requests("session.new_split").first))
        #expect(first.anchor == "block:a" && first.folder == nil, "no folder reported: Rex's default")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { switcher()?.accessibilityValue == "new shell, 2 of 2" })

        // The menu's item is the last element and does the same from the new pane.
        let button = try #require(switcher())
        let item = try #require((button.menuElements().last as? UIMenu)?.children.first as? UIAction)
        #expect(item.title == "New Pane" && item.accessibilityIdentifier == "sshTerminal.rexPanes.new")
        item.performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { switcher()?.accessibilityValue == "new shell, 3 of 3" })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { grid.paneTransition.phase == .idle })
        let second = try NewSplitRequest(try #require(rig.fake.requests("session.new_split").last))
        #expect(second.anchor == "block:created-1", "after the pane that was shown")
        #expect(rig.model.state.panes.map(\.blockID) == ["block:a", "block:created-1", "block:created-2"])
        await rig.stop()
    }

    /// A saved machine that stops answering (a laptop asleep) must not slow
    /// Local: the poll waits for Local only, and the hung machine is not asked
    /// again while its read is still out.
    @Test func aHungMachineDoesNotHoldUpLocal() async throws {
        let ok = { (label: String) in
            SSHExecResult(output: Data(#"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"\#(label)","focused":true}],"tabs":[],"agents":[]}}}"#.utf8), errorOutput: Data(), exitStatus: 0)
        }
        let fixture = TerminalConnectionFixture()
        let laptop = try #require(HerdrRemote.snapshotCommand(machine: "aa11"))
        await fixture.setRunResult(.init(output: Data(#"[{"id":"aa11","label":"laptop","enabled":true}]"#.utf8), errorOutput: Data(), exitStatus: 0),
                                   for: HerdrRemote.machinesCommand)
        await fixture.setRunResult(ok("oppi"), for: "herdr api snapshot")
        await fixture.hang(laptop)
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        defer { channel.close(reason: "done") }
        let monitor = HerdrMonitor()

        await monitor.refresh(on: channel)
        await fixture.setRunResult(ok("renamed"), for: "herdr api snapshot")
        await monitor.refresh(on: channel)

        #expect(monitor.machines.map { $0.snapshot?.workspaces.first?.label } == ["renamed", nil], "Local refreshed twice while the laptop hangs")
        #expect(await fixture.runs.filter { $0.command == laptop }.count == 1, "the hung machine is asked once")
        await fixture.releaseHangs()
        #expect(await waitForMainActorCondition { monitor.machines[1].failure != nil }, "its timeout shows once it gives up")
    }

    // MARK: Herdr's focused pane as the shell's folder
    //
    // Herdr does not pass its panes' OSC 7 through. In a terminal Oppi started
    // in Herdr (Run on Connect `herdr`), with Herdr's screen up, the shell's
    // folder is Herdr's focused pane's, and nothing else is: not the report made
    // before Herdr started, and not a guess for a `herdr`, tmux, or vim the
    // person typed.

    private static let enterHerdr = Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8)
    private static func osc7(_ path: String, host: String = "mac-studio") -> Data {
        Data("\u{1b}]7;file://\(host)\(path)\u{1b}\\".utf8)
    }
    private static func herdrOK(_ json: String) -> SSHExecResult { .init(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0) }
    private static func herdrSnapshot(focused: String, panes: String, agents: String = "[]") -> SSHExecResult {
        herdrOK(#"{"result":{"snapshot":{"workspaces":[],"tabs":[],"agents":\#(agents),"focused_pane_id":"\#(focused)","panes":\#(panes)}}}"#)
    }
    private static let herdrTwoPanes = #"""
    [{"pane_id":"w1:p1","cwd":"/Users/duh/workspace/oppi","foreground_cwd":"/Users/duh/workspace/oppi/server","focused":false},
     {"pane_id":"w1:p2","cwd":"/Users/duh/notes","focused":true}]
    """#
    private static let herdrDown = SSHExecResult(output: Data(), errorOutput: Data("herdr: server not running".utf8), exitStatus: 1)

    private func herdrFolderFixture(
        snapshot: SSHExecResult?, machines: String = "[]", grace: Duration = .seconds(25)
    ) async throws -> (TerminalConnectionFixture, SSHTerminalChannel) {
        let fixture = TerminalConnectionFixture()
        await fixture.setRunResult(Self.herdrOK(machines), for: HerdrRemote.machinesCommand)
        if let snapshot { await fixture.setRunResult(snapshot, for: "herdr api snapshot") }
        let channel = try SSHTerminalChannel(herdrFolderGrace: grace)
        channel.opened(fixture, command: "herdr")
        return (fixture, channel)
    }

    @Test func herdrStartedByOppiShowsItsFocusedPaneAndFollowsFocus() async throws {
        let (fixture, channel) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { channel.close(reason: "done") }
        let monitor = HerdrMonitor()

        // Herdr's screen is up but no snapshot has answered: unknown.
        channel.event(.data(Self.enterHerdr))
        #expect(channel.workingDirectory.isEmpty)

        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server", "foreground_cwd leads")

        await fixture.setRunResult(Self.herdrSnapshot(focused: "w1:p2", panes: Self.herdrTwoPanes), for: "herdr api snapshot")
        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/notes", "cwd when there is no foreground folder; focus moved")

        // A report made before or inside Herdr is not the focused pane's folder.
        channel.event(.data(Self.osc7("/Users/duh/stale")))
        #expect(channel.workingDirectory == "/Users/duh/notes")
    }

    @Test func herdrFolderNeedsTheAlternateScreenAndOppisOwnLaunch() async throws {
        for command in [nil, "", "tmux", "herdr --session work", "herdr session attach work", "herdr --remote box", "/bin/sh -c herdr"] as [String?] {
            let fixture = TerminalConnectionFixture()
            await fixture.setRunResult(Self.herdrOK("[]"), for: HerdrRemote.machinesCommand)
            await fixture.setRunResult(Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes), for: "herdr api snapshot")
            let channel = try SSHTerminalChannel()
            channel.opened(fixture, command: command)
            defer { channel.close(reason: "done") }
            channel.event(.data(Self.osc7("/Users/duh/outer")))
            channel.event(.data(Self.enterHerdr))
            await HerdrMonitor().refresh(on: channel)
            #expect(channel.workingDirectory == "/Users/duh/outer", "\(command ?? "nil"): typed or other launches keep the shell's folder")
        }
        // Started by Oppi, but Herdr's screen is not up.
        let (_, channel) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { channel.close(reason: "done") }
        channel.event(.data(Self.osc7("/Users/duh/outer")))
        await HerdrMonitor().refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/outer")
        channel.event(.data(Self.enterHerdr))
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server")
        channel.event(.data(Data("\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?1049l".utf8)))
        #expect(channel.workingDirectory == "/Users/duh/outer", "the shell's report is back when the screen goes")
    }

    @Test func aReportFromAnotherHostLeavesTheHerdrFolderUnknown() async throws {
        let (_, channel) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { channel.close(reason: "done") }
        channel.event(.data(Self.enterHerdr))
        channel.event(.data(Self.osc7("/home/duh", host: "mac-studio")))
        await HerdrMonitor().refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server")
        // A pane that ssh'd elsewhere: the outer host's Herdr says nothing about it.
        channel.event(.data(Self.osc7("/srv/app", host: "other-box")))
        #expect(channel.workingDirectory.isEmpty)
        channel.event(.data(Self.osc7("/home/duh", host: "mac-studio")))
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server")
    }

    @Test func aFailedReadKeepsTheHerdrFolderOnlyForTheGracePeriod() async throws {
        let (fixture, channel) = try await herdrFolderFixture(snapshot: Self.herdrDown, grace: .milliseconds(300))
        defer { channel.close(reason: "done") }
        let monitor = HerdrMonitor()
        channel.event(.data(Self.enterHerdr))

        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory.isEmpty, "no good snapshot yet")

        await fixture.setRunResult(Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes), for: "herdr api snapshot")
        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server")

        await fixture.setRunResult(Self.herdrDown, for: "herdr api snapshot")
        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server", "one failed read keeps it")
        #expect(await waitForMainActorCondition { channel.workingDirectory.isEmpty }, "then it is unknown")

        // A good read within the grace period restarts it.
        let (again, longer) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { longer.close(reason: "done") }
        longer.event(.data(Self.enterHerdr))
        let second = HerdrMonitor()
        await second.refresh(on: longer)
        await again.setRunResult(Self.herdrDown, for: "herdr api snapshot")
        await second.refresh(on: longer)
        await again.setRunResult(Self.herdrSnapshot(focused: "w1:p2", panes: Self.herdrTwoPanes), for: "herdr api snapshot")
        await second.refresh(on: longer)
        #expect(longer.workingDirectory == "/Users/duh/notes")
    }

    @Test func stoppingThePollClearsTheHerdrFolder() async throws {
        let (_, channel) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { channel.close(reason: "done") }
        channel.event(.data(Self.enterHerdr))
        let monitor = HerdrMonitor()
        let poll = Task { await monitor.run(on: channel) }
        #expect(await waitForMainActorCondition { channel.workingDirectory == "/Users/duh/workspace/oppi/server" })

        // Switched away, reconnecting, or disconnected: the poll's task ends.
        poll.cancel()
        await poll.value
        #expect(channel.workingDirectory.isEmpty, "a folder nothing keeps current is not used")

        // A read that was still out when the poll stopped does not bring it back.
        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory.isEmpty)
        let again = Task { await monitor.run(on: channel) }
        #expect(await waitForMainActorCondition { channel.workingDirectory == "/Users/duh/workspace/oppi/server" }, "polling again sets it again")
        again.cancel()
        await again.value
    }

    /// Leave the screen and return while a read is still out: the old run ends
    /// after the new one started, and must neither clear the folder nor leave the
    /// new run's reads ignored.
    @Test func anOldPollEndingAfterTheNewOneStartedDoesNotStopIt() async throws {
        let (fixture, channel) = try await herdrFolderFixture(snapshot: Self.herdrSnapshot(focused: "w1:p1", panes: Self.herdrTwoPanes))
        defer { channel.close(reason: "done") }
        channel.event(.data(Self.enterHerdr))
        func asked(_ command: String) async -> Int { await fixture.runs.filter { $0.command == command }.count }
        func waitUntil(_ condition: () async -> Bool) async throws {
            for _ in 0..<300 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        }
        await fixture.hang("herdr api snapshot")
        let monitor = HerdrMonitor()

        let old = Task { await monitor.run(on: channel) }
        try await waitUntil { await asked("herdr api snapshot") == 1 }
        old.cancel() // switched away with the read still out
        let new = Task { await monitor.run(on: channel) }
        try await waitUntil { await asked(HerdrRemote.machinesCommand) == 2 } // returned
        #expect(await asked("herdr api snapshot") == 1, "the new poll joins the read in flight")

        await fixture.releaseHangs() // the old read ends late
        await old.value
        #expect(channel.workingDirectory.isEmpty)

        // The new poll's next read is still applied.
        await monitor.refresh(on: channel)
        #expect(channel.workingDirectory == "/Users/duh/workspace/oppi/server")

        // Only the current poll's end clears it.
        new.cancel()
        await new.value
        #expect(channel.workingDirectory.isEmpty)
    }

    @Test func herdrFolderTakesWhatTheSnapshotOffersAndNothingElse() async throws {
        func folder(snapshot: String, machines: String = "[]", machineSnapshot: String? = nil) async throws -> String {
            let (fixture, channel) = try await herdrFolderFixture(snapshot: Self.herdrOK(snapshot), machines: machines)
            if let machineSnapshot {
                await fixture.setRunResult(Self.herdrOK(machineSnapshot), for: try #require(HerdrRemote.snapshotCommand(machine: "aa11")))
            }
            defer { channel.close(reason: "done") }
            channel.event(.data(Self.enterHerdr))
            let monitor = HerdrMonitor()
            await monitor.refresh(on: channel)
            await monitor.refresh(on: channel)
            return channel.workingDirectory
        }
        let head = #"{"result":{"snapshot":{"workspaces":[],"tabs":[],"#

        // An agent pane the pane list lacks still names its folder; an empty
        // foreground folder falls back to the pane's own.
        #expect(try await folder(snapshot: head + #"""
        "focused_pane_id":"w1:p1","panes":[],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent_status":"idle","focused":true,"cwd":"/srv/app"}]}}}
        """#) == "/srv/app")
        #expect(try await folder(snapshot: head + #"""
        "focused_pane_id":"w1:p1","agents":[],"panes":[{"pane_id":"w1:p1","cwd":"/srv/own","foreground_cwd":""}]}}}
        """#) == "/srv/own")

        // A Herdr without these fields (older), a focused pane it does not list,
        // and a folder that is not absolute leave the folder unknown.
        #expect(try await folder(snapshot: head + #"""
        "agents":[],"panes":[{"pane_id":"w1:p1","workspace_id":"w1"}]}}}
        """#) == "")
        #expect(try await folder(snapshot: head + #"""
        "focused_pane_id":"w9:p9","agents":[],"panes":[{"pane_id":"w1:p1","cwd":"/srv/other"}]}}}
        """#) == "")
        #expect(try await folder(snapshot: head + #"""
        "focused_pane_id":"w1:p1","agents":[],"panes":[{"pane_id":"w1:p1","cwd":"relative/dir"}]}}}
        """#) == "")

        // A saved machine's panes are another host's: never this terminal's folder.
        #expect(try await folder(
            snapshot: head + #"""
            "agents":[],"panes":[]}}}
            """#,
            machines: #"[{"id":"aa11","label":"mac-mini","enabled":true}]"#,
            machineSnapshot: head + #"""
            "focused_pane_id":"w1:p1","agents":[],"panes":[{"pane_id":"w1:p1","cwd":"/Users/duh/elsewhere"}]}}}
            """#
        ) == "")
    }

    @Test func keymapSpecsInEachSyntaxEncodeAsTerminalKeys() async throws {
        func parse(_ spec: String, _ syntax: SSHTerminalKeymap.Syntax = .plus) throws -> [SSHTerminalKeyStroke] {
            try #require(SSHTerminalKeymap.parse(spec, syntax: syntax), "\(spec) did not parse")
        }
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var bytes = fixture.bytes.makeAsyncIterator()
        for (spec, syntax, expected, label) in [
            ("shift+tab", SSHTerminalKeymap.Syntax.plus, "\u{1b}[Z", "\u{21E7}Tab"),
            ("Ctrl+L", .plus, "\u{0c}", "^L"),
            ("meta+p", .plus, "\u{1b}p", "\u{2325}P"),
            ("ctrl+x ctrl+b", .plus, "\u{18}\u{02}", "^X ^B"), // a Claude Code chord, one write
            ("alt-.", .dash, "\u{1b}.", "\u{2325}."),
            ("page-down", .dash, "\u{1b}[6~", "PgDn"),
        ] {
            let strokes = try parse(spec, syntax)
            #expect(strokes.map(\.label).joined(separator: " ") == label)
            channel.keys(strokes)
            #expect(await bytes.next() == Data(expected.utf8), "\(spec)")
        }
        #expect(try parse("ctrl--", .dash).map(\.label) == ["^-"]) // the separator as the key
        // Keys a phone terminal cannot send reliably are not offered at all.
        #expect(SSHTerminalKeymap.parse("super+k", syntax: .plus) == nil)
        #expect(SSHTerminalKeymap.parse("ctrl+x wheelup", syntax: .plus) == nil)
        channel.close(reason: "done")
    }

    @Test func keymapAppliesEachProgramsOwnOverrideRules() throws {
        func strip(_ program: String, _ file: String?) throws -> [String] {
            let profile = try #require(SSHTerminalKeymap.profile(for: program))
            return SSHTerminalKeymap.actions(for: profile, userFile: file).map { "\($0.title) \($0.keyLabel)" }
        }
        // Defaults; an action bound to a fixed key (pi's Esc) is not repeated.
        #expect(try strip("pi", nil) == ["Thinking \u{21E7}Tab", "Model ^L", "Tools ^O"])
        #expect(try strip("shell", nil) == ["History ^R", "Clear ^L"])
        #expect(SSHTerminalKeymap.profile(for: "vim") == nil)

        // pi: a value replaces the defaults, [] unbinds, a broken file is ignored like pi does.
        let pi = #"{"app.interrupt": "ctrl+g", "app.model.select": ["ctrl+k", "ctrl+l"], "app.tools.expand": []}"#
        #expect(try strip("pi", pi) == ["Stop ^G", "Thinking \u{21E7}Tab", "Model ^K"])
        #expect(try strip("pi", "{ not json") == (try strip("pi", nil)))

        // Claude Code: keys add to defaults; a default key unbound (any alias
        // or case) or taken by another action drops out; other contexts don't apply.
        let claude = #"{"bindings": [{"context": "Chat", "bindings": {"Meta+P": null, "ctrl+e": "chat:modelPicker", "ctrl+t": "chat:externalEditor"}}, {"context": "Settings", "bindings": {"ctrl+o": null}}]}"#
        #expect(try strip("claude", claude) == ["Mode \u{21E7}Tab", "Model ^E", "Transcript ^O", "Background ^B"])

        // Codex: table headers, dotted keys, multi-line arrays, comments, [] unbinds.
        let codex = """
        [tui]
        keymap.global.open_transcript = "f2" # dotted under [tui]
        [tui.keymap.chat]
        interrupt_turn = "f12"
        increase_reasoning_effort = [
          "alt-=",
        ]
        decrease_reasoning_effort = []
        """
        #expect(try strip("codex", codex) == ["Stop F12", "Transcript F2", "Effort + \u{2325}="])
    }

    @Test func attachmentUploadSendsTheBytesAndReturnsOnlyTheGeneratedPath() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let name = SSHTerminalUpload.fileName(extension: "JPEG", id: (try #require(UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000"))))
        #expect(name == "oppi-a1b2c3d4.jpeg")
        #expect(SSHTerminalUpload.fileName(extension: "x;rm -rf").hasSuffix(".xrmrf"))

        #expect(try SSHTerminalUpload.path(from: .init(output: Data("/var/folders/xy/T/oppi-ssh/oppi-0.png".utf8), errorOutput: Data(), exitStatus: 0),
                                           fileName: "oppi-0.png") == "/var/folders/xy/T/oppi-ssh/oppi-0.png")
        #expect(throws: SSHTerminalUpload.Failure.self) { // a path that is not the one asked for
            _ = try SSHTerminalUpload.path(from: .init(output: Data("/tmp/other.png".utf8), errorOutput: Data(), exitStatus: 0), fileName: "oppi-0.png")
        }
        await #expect(throws: SSHTerminalUpload.Failure.rejected("The host did not save the attachment: disk full")) {
            await fixture.setRunResult(.init(output: Data(), errorOutput: Data("disk full".utf8), exitStatus: 1))
            _ = try await channel.upload(Data([1, 2, 3]), fileExtension: "png")
        }
        await #expect(throws: SSHTerminalUpload.Failure.tooLarge) {
            _ = try await channel.upload(Data(count: SSHTerminalUpload.maximumBytes + 1), fileExtension: "png")
        }
        let runs = await fixture.runs
        #expect(runs.count == 1) // the oversized file never reached the host
        #expect(runs[0].input == Data([1, 2, 3]))
        // One shell word for a fish login shell. What the script does is proven
        // by running it (see docs/ssh-terminal.md), not by pinning its text.
        let command = runs[0].command
        #expect(command.hasPrefix("sh -c 'umask 077; "))
        #expect(command.hasSuffix("'"))
        #expect(command.filter { $0 == "'" }.count == 2)

        #expect(SSHTerminalComposerHost.prompt("  what is this?\n", paths: ["/tmp/a.png", "/tmp/b.png"]) == "what is this?\n\n/tmp/a.png\n/tmp/b.png")
        #expect(SSHTerminalComposerHost.prompt("", paths: ["/tmp/a.png"]) == "/tmp/a.png")
    }

    @Test func pasteLineCountIgnoresATrailingTerminator() {
        #expect(SSHTerminalEngine.pasteLineCount("echo one\recho two\r") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("echo one\necho two\n") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("a\r\nb\r\n") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("a\rb\nc") == 3)
        #expect(SSHTerminalEngine.pasteLineCount("echo hi\r") == 1)
        #expect(SSHTerminalEngine.pasteLineCount("plain") == 1)
    }

    @Test func queuedOutputChunksAreInterpretedAsOneTerminalWriteAndTitlePublishes() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let queue = SSHTerminalEventQueue()
        for chunk in 0..<50 { queue.push(.data(Data("line \(chunk)\r\n".utf8))) }
        queue.push(.data(Data("\u{1b}]2;built\u{7}".utf8)))
        queue.push(.exitStatus(0))
        let before = channel.engine.changeCount
        await channel.consume(queue)
        #expect(channel.engine.changeCount - before == 1) // 51 chunks, one vt write
        #expect(channel.title == "built")
        #expect(channel.reason == "Shell exited with status 0.")
    }

    @Test func keyRepeaterRepeatsUntilStoppedOrTheActionDeclines() async throws {
        let repeater = SSHTerminalKeyRepeater(initialDelay: .milliseconds(30), interval: .milliseconds(5))
        let (ticks, tickSink) = AsyncStream<Int>.makeStream()
        var count = 0
        repeater.start {
            count += 1
            tickSink.yield(count)
            return true
        }
        #expect(count == 0) // nothing before the initial delay
        var iterator = ticks.makeAsyncIterator()
        while let value = await iterator.next(), value < 3 {}
        repeater.stop()
        let stoppedAt = count
        try await Task.sleep(for: .milliseconds(60))
        #expect(count == stoppedAt)

        var declined = 0
        repeater.start { declined += 1; return declined < 2 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(declined == 2) // a false return ends the repeat
        repeater.stop()
    }

    @Test func disconnectedInputAndOversizedQueueAreVisiblyRefused() async throws {
        let channel = try SSHTerminalChannel()
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_ALT))
        #expect(!channel.key(GHOSTTY_KEY_A, text: "a"))
        #expect(channel.modifierLatch.isArmed(GhosttyMods(GHOSTTY_MODS_ALT)))
        #expect(channel.inputNotice.contains("disconnected"))
        let fixture = TerminalConnectionFixture()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        #expect(!channel.send(Data(repeating: 1, count: SSHTerminalChannel.maximumQueuedBytes + 1)))
        #expect(channel.inputNotice.contains("full"))
        #expect(channel.send(Data(repeating: 1, count: SSHTerminalChannel.maximumQueuedBytes)))
        #expect(!channel.key(GHOSTTY_KEY_A, text: "a"))
        #expect(channel.modifierLatch.isArmed(GhosttyMods(GHOSTTY_MODS_ALT)))
        #expect(channel.inputNotice.contains("full"))
        #expect(await fixture.sentBytes.isEmpty)
        channel.close(reason: "done")
    }

    @Test func leavingTheScreenKeepsTheChannelOpenAndItsGrid() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.event(.data(Data("kept-grid".utf8)))
        let first = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        first.host.view.layoutIfNeeded()
        first.dismiss()
        #expect(channel.connected)
        // The same channel and grid come back on the next screen.
        let second = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { second.dismiss(); channel.close(reason: "done") }
        second.host.view.layoutIfNeeded()
        #expect(channel.connected)
        #expect(channel.engine.frame().rows[0].prefix(9).map(\.text).joined() == "kept-grid")
        channel.send(Data("x".utf8))
        var bytes = fixture.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data("x".utf8))
    }

    @Test func leavingWhileAModalIsPresentedClearsIsViewedAndShowsTerminal() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let session = SSHTerminalConnectSession()
        session.showsTerminal = true
        let terminal = SSHTerminalViewController(
            channel: channel, reconnect: {}, editHost: {}, session: session
        )
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.pushViewController(terminal, animated: false)
        nav.view.layoutIfNeeded()
        channel.isViewed = true
        session.showsTerminal = true

        let modal = UIViewController()
        terminal.present(modal, animated: false)
        #expect(terminal.presentedViewController === modal)
        #expect(channel.isViewed)

        nav.popViewController(animated: false)
        nav.view.layoutIfNeeded()
        #expect(!channel.isViewed)
        #expect(!session.showsTerminal)
        #expect(channel.connected)
        window.endEditing(true)  // a hidden window must not leave its keyboard up
        window.isHidden = true
        window.rootViewController = nil
        channel.close(reason: "done")
    }

    @Test func floatingControlsReplaceTheBarAndStepAsideForTheKeyboard() async throws {
        let channel = try SSHTerminalChannel()
        let fixture = TerminalConnectionFixture()
        channel.opened(fixture)
        let terminal = SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        let root = UIViewController()
        // The router's stack gives every incoming screen its bar back.
        let nav = RouterNavigationController(rootViewController: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)  // a hidden window must not leave its keyboard up
            window.isHidden = true
            window.rootViewController = nil
            channel.close(reason: "done")
        }
        nav.pushViewController(terminal, animated: false)
        nav.view.layoutIfNeeded()
        #expect(nav.isNavigationBarHidden, "the terminal never shows the navigation bar")
        let grid = try #require(terminal.gridView)
        let gridBefore = grid.bounds.size
        let resizes = SSHTerminalResizeLog()
        let collector = Task { @MainActor in
            for await geometry in fixture.resizes { resizes.sizes.append(geometry) }
        }
        defer { collector.cancel() }

        func find(_ id: String, in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        func control(_ id: String) throws -> UIView {
            try #require(find(id, in: terminal.view))
        }
        func hiddenFromVoiceOver(_ id: String) throws -> Bool {
            var view: UIView? = try control(id)
            while let current = view {
                if current.accessibilityElementsHidden || current.isHidden { return true }
                view = current.superview
            }
            return false
        }
        /// What a finger at the control's center lands on.
        func touched(_ id: String) throws -> UIView? {
            let target = try control(id)
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: terminal.view)
            return terminal.view.hitTest(point, with: nil)
        }
        #expect(try touched("sshTerminal.back") === control("sshTerminal.back"))
        #expect(try touched("sshTerminal.more") === control("sshTerminal.more"))

        func keyboard(top: CGFloat) {
            let frame = window.convert(
                CGRect(x: 0, y: top, width: window.bounds.width, height: 336),
                to: scene.screen.coordinateSpace
            )
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: scene.screen,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: frame,
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                    UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                ]
            )
            // The bar's height and the grid's reserve change inside the
            // notification; the frames a finger sees are laid out here.
            nav.view.layoutIfNeeded()
        }
        /// Where a control's center is, in the terminal's coordinates.
        func spot(_ id: String) throws -> CGPoint {
            let target = try control(id)
            return target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: terminal.view)
        }
        let backSpot = try spot("sshTerminal.back")
        let moreSpot = try spot("sshTerminal.more")
        keyboard(top: window.bounds.maxY - 336)
        #expect(
            terminal.view.hitTest(backSpot, with: nil)?.isDescendant(of: grid) == true,
            "the rows the bar gave back belong to the grid, not a faded button"
        )
        #expect(terminal.view.hitTest(moreSpot, with: nil)?.isDescendant(of: grid) == true)
        #expect(try hiddenFromVoiceOver("sshTerminal.back"))
        _ = await waitForMainActorCondition {
            nav.view.layoutIfNeeded()
            return grid.bounds.height == gridBefore.height + SSHTerminalBottomBar.reserve
        }
        #expect(
            grid.bounds.height == gridBefore.height + SSHTerminalBottomBar.reserve,
            "the bar's rows go to the grid while the keyboard is up, in the same resize"
        )

        keyboard(top: window.bounds.maxY)
        #expect(try !hiddenFromVoiceOver("sshTerminal.back"), "Back is back with the keyboard down")
        // The grid takes the rows back once the transition's hold ends, and the remote
        // terminal is resized to the grid after that.
        _ = await waitForMainActorCondition(timeout: .seconds(10)) {
            nav.view.layoutIfNeeded()
            return grid.bounds.size == gridBefore
                && resizes.sizes.count > 0
                && channel.engine.geometry.rows == Int(grid.bounds.height / grid.cellSize.height)
        }
        #expect(grid.bounds.size == gridBefore)
        /// The glass pill around a button: stack, effect content, effect view,
        /// glass, then the pill the bar holds.
        func pill(_ button: UIView) throws -> UIView {
            var view: UIView? = button
            for _ in 0..<5 { view = view?.superview }
            return try #require(view)
        }
        let barTop = try pill(control("sshTerminal.back")).convert(CGPoint.zero, to: terminal.view).y
            - SSHTerminalBottomBar.topInset
        let gridBottom = grid.convert(CGPoint(x: 0, y: grid.bounds.maxY), to: terminal.view).y
        #expect(abs((barTop - gridBottom) - SSHTerminalBottomBar.gridGap) < 0.5)
        // 3 pt above the glass is the bar's inset strip, and the container
        // hands it to the pill: the live view must answer it.
        #expect(await waitForMainActorCondition {
            terminal.updatePropertiesIfNeeded()
            nav.view.layoutIfNeeded()
            guard let back = try? control("sshTerminal.back") else { return false }
            let point = back.convert(CGPoint(x: back.bounds.midX, y: -3), to: terminal.view)
            return terminal.view.hitTest(point, with: nil) === back
        }, "3 pt above Back reaches it")
        #expect(
            channel.engine.geometry.rows == Int(grid.bounds.height / grid.cellSize.height),
            "the remote terminal is the grid above the bar"
        )
        let settledResizes = resizes.sizes.count
        #expect(settledResizes > 0, "the first layout sized the remote terminal")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            nav.view.layoutIfNeeded()
            return resizes.sizes.count == settledResizes
        }, "settled: the bar adds no resize of its own")
        #expect(nav.isNavigationBarHidden)

        // Back's dot means a blocked program (or Herdr) wants you; a notification does not.
        let back = try control("sshTerminal.back")
        channel.event(.data(Data("\u{1b}]9;Build finished\u{7}".utf8)))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            terminal.updatePropertiesIfNeeded()
            return back.accessibilityValue == nil
        }, "a notification is not attention")
        channel.event(.data(Data("\u{1b}]7501;state=blocked:kind=permission:app=pi\u{1b}\\".utf8)))
        #expect(await waitForMainActorCondition {
            terminal.updatePropertiesIfNeeded()
            return back.accessibilityValue == "Attention pending"
        })

        // A broken connection keeps Back and Reconnect in reach with the keyboard up.
        keyboard(top: window.bounds.maxY - 336)
        #expect(try hiddenFromVoiceOver("sshTerminal.back"), "the bar is gone with the keyboard up")
        _ = await waitForMainActorCondition {
            nav.view.layoutIfNeeded()
            return grid.bounds.height == gridBefore.height + SSHTerminalBottomBar.reserve
        }
        let keyboardUpSize = grid.bounds.size
        channel.event(.closed)
        #expect(await waitForMainActorCondition {
            terminal.updatePropertiesIfNeeded()
            nav.view.layoutIfNeeded()
            return (try? touched("sshTerminal.back")) === back
        }, "Back stays with the keyboard up once the connection is gone")
        // The bar comes back over the grid's bottom rows rather than taking
        // rows: reconnecting with the keyboard up does not resize the shell.
        let floatingBarTop = try pill(control("sshTerminal.back")).convert(CGPoint.zero, to: terminal.view).y
            - SSHTerminalBottomBar.topInset
        let floatingGridBottom = grid.convert(CGPoint(x: 0, y: grid.bounds.maxY), to: terminal.view).y
        #expect(floatingBarTop < floatingGridBottom, "the bar floats over the grid, so it took no rows")
        #expect(
            grid.bounds.height + SSHTerminalBottomBar.reserve > keyboardUpSize.height,
            "the grid did not give the bar its rows back either"
        )

        keyboard(top: window.bounds.maxY - 336)
        nav.popViewController(animated: false)
        // The keyboard goes down on the way out.
        keyboard(top: window.bounds.maxY)
        _ = await waitForMainActorCondition {
            nav.view.layoutIfNeeded()
            return nav.topViewController === root && !nav.isNavigationBarHidden
        }
        #expect(nav.topViewController === root)
        #expect(!nav.isNavigationBarHidden, "the screen below needs its Back and title")
    }

    /// The bar's rows follow the keyboard even when the connection is already
    /// gone: the bar's own visibility never changes in that path, so the
    /// reserve has to follow the keyboard event itself.
    @Test func theBarTakesItsRowsBackWhenTheKeyboardGoesDownWhileDisconnected() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let grid = try #require(mounted.controller.gridView)
        let terminal = mounted.controller

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func keyboard(top: CGFloat) {
            let frame = mounted.window.convert(
                CGRect(x: 0, y: top, width: mounted.window.bounds.width, height: 336),
                to: scene.screen.coordinateSpace
            )
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: scene.screen,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: frame,
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                    UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                ]
            )
            mounted.host.view.layoutIfNeeded()
        }
        func backPillTop() throws -> CGFloat {
            let button = try #require(mounted.find { $0.accessibilityIdentifier == "sshTerminal.back" })
            var view: UIView? = button
            for _ in 0..<5 { view = view?.superview }
            let pill = try #require(view)
            return pill.convert(CGPoint.zero, to: terminal.view).y - SSHTerminalBottomBar.topInset
        }
        func gridBottom() -> CGFloat {
            grid.convert(CGPoint(x: 0, y: grid.bounds.maxY), to: terminal.view).y
        }

        // The keyboard below is posted by hand, so send any real one an earlier
        // test left up away first. It cannot make this test fail if it survives:
        // the bar and the grid hang off the same keyboard guide, so every
        // comparison here holds with the guide raised or resting.
        await mounted.dismissStrayKeyboards()
        #expect(try backPillTop() >= gridBottom(), "the bar starts below the grid")

        // Typing, then the connection drops: the bar floats above the keyboard
        // without taking rows.
        keyboard(top: mounted.window.bounds.maxY - 336)
        channel.event(.closed)
        #expect(await waitForMainActorCondition {
            terminal.updatePropertiesIfNeeded()
            mounted.host.view.layoutIfNeeded()
            return (try? backPillTop()).map { $0 < gridBottom() } == true
        }, "with the keyboard up the bar floats over the grid")

        // The keyboard goes down: the bar takes its rows back. A disconnected
        // channel sends no resize, so this checks the grid and the engine size.
        keyboard(top: mounted.window.bounds.maxY)
        let settled = await waitForMainActorCondition(timeout: .seconds(3)) {
            mounted.host.view.layoutIfNeeded()
            return channel.engine.geometry.rows == Int(grid.bounds.height / grid.cellSize.height)
        }
        mounted.host.view.layoutIfNeeded()
        #expect(try backPillTop() >= gridBottom(), "the bar is below the grid again")
        #expect(
            settled,
            "the remote terminal ends above the bar again: engine rows \(channel.engine.geometry.rows), grid rows \(Int(grid.bounds.height / grid.cellSize.height)), \(mounted.keyboardDiagnostics())"
        )
    }

    /// The bar's 4 pt inset strip must land on the button under the finger,
    /// not on the pill's first control: with Herdr shown, a touch in front of
    /// … is …, one in front of the grid button is Herdr, and the middle pill's
    /// Type in Terminal and Chat Bar answer for themselves.
    @Test func theStripAboveTheBarReachesTheButtonUnderTheFinger() async throws {
        let fixture = TerminalConnectionFixture()
        let herdr = #"{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[],"tabs":[],"workspaces":[]},"type":"session_snapshot"}}"#
        await fixture.setRunResult(.init(output: Data(herdr.utf8), errorOutput: Data(), exitStatus: 0))
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let terminal = mounted.controller
        func control(_ id: String) throws -> UIView {
            try #require(mounted.find { $0.accessibilityIdentifier == id })
        }
        #expect(await waitForMainActorCondition {
            terminal.updatePropertiesIfNeeded()
            mounted.host.view.layoutIfNeeded()
            return (try? control("sshTerminal.herdr"))?.isHidden == false
        }, "the grid button appears once Herdr answers")
        mounted.host.view.layoutIfNeeded()

        func stripPoint(_ id: String) throws -> CGPoint {
            let button = try control(id)
            return button.convert(CGPoint(x: button.bounds.midX, y: -3), to: terminal.view)
        }
        for (id, expected) in [
            ("sshTerminal.more", "sshTerminal.more"),
            ("sshTerminal.herdr", "sshTerminal.herdr"),
            ("sshTerminal.back", "sshTerminal.back"),
            ("sshTerminal.bar.keyboard", "sshTerminal.bar.keyboard"),
            ("sshTerminal.bar.chatBar", "sshTerminal.bar.chatBar"),
        ] {
            let hit = terminal.view.hitTest(try stripPoint(id), with: nil)
            #expect(
                hit === (try control(expected)),
                "3 pt above \(id) reaches \(expected), not \(String(describing: hit.map { $0.accessibilityIdentifier ?? String(describing: type(of: $0)) }))"
            )
        }
        // Between the pills the strip belongs to no control: the touch falls
        // through to the grid, never to a bar button.
        let back = try control("sshTerminal.back")
        let keyboard = try control("sshTerminal.bar.keyboard")
        let backEdge = back.convert(CGPoint(x: back.bounds.maxX, y: 0), to: terminal.view).x
        let middleEdge = keyboard.convert(CGPoint(x: keyboard.bounds.minX, y: 0), to: terminal.view).x
        #expect(middleEdge - backEdge > 2 * SSHTerminalGlassPill.touchOutset, "room between Back and the middle pill")
        let gapPoint = CGPoint(x: (backEdge + middleEdge) / 2, y: try stripPoint("sshTerminal.more").y)
        let gapHit = terminal.view.hitTest(gapPoint, with: nil)
        #expect(gapHit?.accessibilityIdentifier == nil, "the gap is not a bar control")
    }

    /// The bar's pill is centered on the screen and moves only when its
    /// edges would come within the gap of Back or the Rex pane switcher's pill.
    @Test func theBarPillIsCenteredOnTheScreenAndOnlyMovesWhenCrowded() async throws {
        let suite = "SSHTerminalTests.pill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHTerminalBarStore(defaults: defaults)
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}, barStore: store)
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let terminal = mounted.controller
        func frames() -> (pill: CGRect, back: CGRect)? {
            terminal.updatePropertiesIfNeeded()
            mounted.host.view.layoutIfNeeded()
            guard let pill = mounted.find({ $0 is SSHTerminalBarPill }), let back = mounted.find({ $0 is SSHTerminalBackPill }) else { return nil }
            return (pill.convert(pill.bounds, to: terminal.view), back.convert(back.bounds, to: terminal.view))
        }
        try #require(await waitForMainActorCondition { frames() != nil })
        let start = try #require(frames())
        #expect(abs(start.pill.midX - terminal.view.bounds.midX) < 0.5, "few buttons: centered on the screen, \(start.pill)")

        // Every button on, and three custom keys: more than the room holds.
        for key in ["d", "l", "k"] { store.save(SSHTerminalCustomKey(name: key.uppercased(), control: true, key: key)) }
        store.setLayout(SSHTerminalBarLayout(order: store.layout.order, shown: Set(store.layout.order)))
        try #require(await waitForMainActorCondition { (frames()?.pill.width ?? 0) > 280 })
        let crowded = try #require(frames())
        let width = terminal.view.bounds.width
        let expected = SSHTerminalBottomBar.pillMinX(
            pillWidth: crowded.pill.width, viewWidth: width, safeInsets: terminal.view.safeAreaInsets, rexPanesShown: false
        )
        #expect(abs(crowded.pill.minX - expected) < 0.5, "crowded: at the clamp \(expected), not \(crowded.pill.minX)")
        #expect(crowded.pill.minX >= crowded.back.maxX + SSHTerminalBottomBar.pillGap - 0.5, "never closer than the gap to Back")
        #expect(crowded.pill.maxX <= width - SSHTerminalBottomBar.sideInset + 0.5)
        #expect(crowded.pill.midX > width / 2, "shifted toward the open side, not centered")
    }

    /// With the Rex pane switcher at the trailing corner the room is smaller: a
    /// crowded pill stops a gap short of its pill and never overlaps it.
    @Test func theBarPillKeepsAGapFromTheRexPaneSwitcher() async throws {
        let suite = "SSHTerminalTests.pill.rex.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHTerminalBarStore(defaults: defaults)
        for key in ["d", "l", "k"] { store.save(SSHTerminalCustomKey(name: key.uppercased(), control: true, key: key)) }
        store.setLayout(SSHTerminalBarLayout(order: store.layout.order, shown: Set(store.layout.order)))
        let rig = try await RexSessionTerminalTests().open(["a", "b"])
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {}, barStore: store)
        )
        defer { mounted.dismiss() }
        let terminal = mounted.controller
        func frames() -> (pill: CGRect, panes: CGRect)? {
            terminal.updatePropertiesIfNeeded()
            mounted.host.view.layoutIfNeeded()
            guard let pill = mounted.find({ $0 is SSHTerminalBarPill }),
                  let panes = mounted.find({ $0 is SSHTerminalRexPanesPill }), !panes.isHidden, panes.bounds.width > 0 else { return nil }
            return (pill.convert(pill.bounds, to: terminal.view), panes.convert(panes.bounds, to: terminal.view))
        }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { (frames()?.pill.width ?? 0) > 220 })
        let layout = try #require(frames())
        #expect(layout.pill.maxX <= layout.panes.minX - SSHTerminalBottomBar.pillGap + 0.5, "a gap before the pane switcher: \(layout)")
        let expected = SSHTerminalBottomBar.pillMinX(
            pillWidth: layout.pill.width, viewWidth: terminal.view.bounds.width, safeInsets: terminal.view.safeAreaInsets, rexPanesShown: true
        )
        #expect(abs(layout.pill.minX - expected) < 0.5)
        await rig.stop()
    }

    @Test func inputAndPasteBannersSitOnAMaterialCard() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        channel.event(.data(Data("prompt> ls\nfile.txt\n".utf8)))
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        channel.event(.eof)
        channel.modifierLatch.toggle(GhosttyMods(GHOSTTY_MODS_CTRL))
        #expect(!channel.key(GHOSTTY_KEY_C, text: "c"))
        mounted.host.view.setNeedsLayout()
        mounted.host.view.layoutIfNeeded()
        let banner = try #require(mounted.find { $0.accessibilityIdentifier == "sshTerminal.inputNotice" })
        #expect(banner.subviews.contains { $0 is UIVisualEffectView })
        #expect(banner.accessibilityIdentifier == "sshTerminal.inputNotice")
        if let dir = ProcessInfo.processInfo.environment["OPPI_NOTICE_SHOT"] {
            let folder = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let renderer = UIGraphicsImageRenderer(bounds: mounted.controller.view.bounds)
            let image = renderer.image { ctx in mounted.controller.view.layer.render(in: ctx.cgContext) }
            try image.pngData()?.write(to: folder.appendingPathComponent("input-notice-after.png"))
        }
    }

    @Test func aPasswordPromptMovesTypingOffTheChatBarAndBack() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        // An agent that reports itself does not bring up the chat bar.
        channel.event(.data(Data("\u{1b}]7501;state=idle:app=pi\u{1b}\\".utf8)))
        try await settle(mounted)
        let grid = try #require(mounted.controller.gridView)
        let draft = { mounted.find { $0 is PastableUITextView } as? PastableUITextView }
        #expect(draft() == nil, "a pi report alone shows no chat bar")
        try mounted.tapChatBar()
        try await settle(mounted)
        let textView = try #require(draft(), "Chat Bar brings it up")
        // A later report change does not close a bar the person opened.
        channel.event(.data(Data("\u{1b}]7501;state=working:app=pi\u{1b}\\".utf8)))
        try await settle(mounted)
        #expect(draft() === textView, "a report change leaves the bar open")

        channel.engine.receive(Data("\r\n[sudo] password for duh: ".utf8))
        grid.drawFrame()
        try await settle(mounted)
        #expect(grid.isSecureTextEntry)
        #expect(grid.isFirstResponder, "the prompt is typed into the terminal")
        #expect(draft() == nil, "and the password cannot reach the draft")

        // pwfeedback echoes one mark per key; the prompt must stay secure and
        // the chat bar must not come back for the rest of the secret.
        for mark in ["*", "**", "***"] {
            channel.engine.receive(Data(mark.utf8))
            grid.drawFrame()
            try await settle(mounted)
            #expect(grid.isSecureTextEntry, "after \(mark)")
            #expect(draft() == nil, "the draft stays away after \(mark)")
        }

        // One half-drawn frame puts the cursor on another row and back, as a
        // repaint in a neighbouring Herdr pane does. Nothing may switch on it.
        let promptRow = channel.engine.cursorCell.row
        channel.engine.receive(Data("\u{1b}[\(promptRow + 2);1H".utf8))
        grid.drawFrame()
        try await settle(mounted)
        #expect(grid.isSecureTextEntry, "one off frame is not a release")
        #expect(draft() == nil, "and the chat bar does not come back for it")
        let prompt = "[sudo] password for duh: "
        channel.engine.receive(Data("\u{1b}[\(promptRow + 1);\(prompt.count + 1)H".utf8))
        grid.drawFrame()
        try await settle(mounted)
        #expect(grid.isSecureTextEntry)
        #expect(draft() == nil)

        // The hide key during the prompt keeps the keyboard down. Ending the
        // prompt still puts the chat bar back, just without the keyboard.
        let strip = try #require(grid.inputAccessoryView)
        let hide = try #require(mounted.find(in: strip, matching: {
            $0.accessibilityIdentifier == "sshTerminal.hideKeyboard"
        }) as? UIButton)
        hide.sendActions(for: .touchUpInside)
        try await settle(mounted)
        #expect(!grid.isFirstResponder, "the hide key sends the keyboard away")

        // Two pictures have to agree before the prompt is over. A layout
        // picture (here a resize, as a keyboard transition or a rotation
        // causes) is a picture the renderer draws, but it is not output: it
        // must not stand in for the second look and end the prompt early.
        channel.engine.receive(Data("\r\n".utf8))
        grid.drawFrame()
        try await settle(mounted)
        channel.engine.resize(.init(columns: 79, rows: 23))
        grid.drawFrame()
        try await settle(mounted)
        #expect(grid.isSecureTextEntry, "a resize is not the second picture")
        channel.engine.receive(Data("\r\n".utf8))
        grid.drawFrame()
        try await settle(mounted)
        #expect(!grid.isSecureTextEntry)
        #expect(draft() === textView, "the chat bar comes back")
        #expect(!textView.isFirstResponder, "without the keyboard the user hid")
        #expect(textView.text.isEmpty)
    }

    /// Type in Terminal during a password prompt brings back the keyboard the
    /// user hid; it is not a choice to stay in the terminal, so the chat bar
    /// still returns when the prompt ends, with the keyboard they brought back.
    @Test func typeInTerminalDuringAPasswordPromptStillReturnsToTheChatBar() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        channel.event(.data(Data("\u{1b}]7501;state=idle:app=pi\u{1b}\\".utf8)))
        try mounted.tapChatBar()
        try await settle(mounted)
        let grid = try #require(mounted.controller.gridView)
        let draft = { mounted.find { $0 is PastableUITextView } as? PastableUITextView }
        #expect(draft() != nil, "Chat Bar brings the chat bar")

        channel.engine.receive(Data("\r\n[sudo] password for duh: ".utf8))
        grid.drawFrame()
        try await settle(mounted)
        #expect(grid.isFirstResponder, "the prompt is typed into the terminal")

        let strip = try #require(grid.inputAccessoryView)
        let hide = try #require(mounted.find(in: strip, matching: {
            $0.accessibilityIdentifier == "sshTerminal.hideKeyboard"
        }) as? UIButton)
        hide.sendActions(for: .touchUpInside)
        try await settle(mounted)
        #expect(!grid.isFirstResponder)

        let typeInTerminal = try #require(mounted.find {
            $0.accessibilityIdentifier == "sshTerminal.bar.keyboard"
        } as? UIButton)
        typeInTerminal.sendActions(for: .touchUpInside)
        try await settle(mounted)
        #expect(grid.isFirstResponder, "Type in Terminal brings the keyboard back")
        #expect(grid.isSecureTextEntry)
        #expect(draft() == nil, "the password still cannot reach the draft")

        // The prompt ends when two painted pictures agree it has gone.
        for _ in 0..<2 {
            channel.engine.receive(Data("\r\n".utf8))
            grid.drawFrame()
            try await settle(mounted)
        }
        #expect(!grid.isSecureTextEntry)
        let textView = try #require(draft(), "the chat bar comes back")
        #expect(textView.isFirstResponder, "with the keyboard the user brought back")
    }

    /// A coding agent's report picks the key strip's program, never the input:
    /// the chat bar shows only after Chat Bar, and then outlives report changes.
    @Test func anAgentReportDoesNotShowTheChatBarButTheChatBarActionDoes() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let draft = { mounted.find { $0 is PastableUITextView } as? PastableUITextView }
        func selected(_ id: String) throws -> Bool {
            let button = try #require(mounted.find { $0.accessibilityIdentifier == id } as? UIButton, "\(id)")
            return button.accessibilityTraits.contains(.selected)
        }

        for report in ["idle", "working", "blocked:kind=permission", "done"] {
            channel.event(.data(Data("\u{1b}]7501;state=\(report):app=pi\u{1b}\\".utf8)))
            try await settle(mounted)
            #expect(draft() == nil, "a \(report) pi report shows no chat bar")
            #expect(try selected("sshTerminal.bar.keyboard"), "and typing stays in the terminal")
        }

        // Chat Bar on a pane running pi turns the bar on (it must not toggle it off).
        try mounted.tapChatBar()
        try await settle(mounted)
        let textView = try #require(draft(), "Chat Bar brings the bar up on a pi pane")
        #expect(textView.isFirstResponder)
        #expect(try selected("sshTerminal.bar.chatBar"))

        // The choice outlives the program: its report ends and changes.
        channel.event(.data(Data("\u{1b}]133;A\u{7}".utf8)))
        try await settle(mounted)
        #expect(draft() === textView, "the shell coming back does not close it")
        channel.event(.data(Data("\u{1b}]7501;state=working:app=pi\u{1b}\\".utf8)))
        try await settle(mounted)
        #expect(draft() === textView, "a new report does not either")

        // The raw keyboard still wins over the explicit choice.
        let grid = try #require(mounted.controller.gridView)
        grid.rawKeyboardChanged(true)
        try await settle(mounted)
        #expect(draft() == nil, "the remote raw keyboard hides the bar")
    }

    /// The bar's input buttons move typing where they say, and the one in use
    /// carries the selected trait for VoiceOver (and the filled glyph).
    @Test func theBarsInputButtonsMoveTypingAndMarkTheInputInUse() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        defer { mounted.dismiss(); channel.close(reason: "done") }
        try await settle(mounted)
        let grid = try #require(mounted.controller.gridView)
        let draft = { mounted.find { $0 is PastableUITextView } as? PastableUITextView }
        func button(_ id: String) throws -> UIButton {
            try #require(mounted.find { $0.accessibilityIdentifier == id } as? UIButton, "\(id)")
        }
        func selected(_ id: String) throws -> Bool { try button(id).accessibilityTraits.contains(.selected) }

        // A shell types into the terminal, but nothing starts typing on its own.
        #expect(try selected("sshTerminal.bar.keyboard"))
        #expect(try !selected("sshTerminal.bar.chatBar"))
        #expect(!grid.isFirstResponder)
        #expect(draft() == nil)

        try button("sshTerminal.bar.chatBar").sendActions(for: .touchUpInside)
        try await settle(mounted)
        let textView = try #require(draft(), "Chat Bar brings the chat bar")
        #expect(textView.isFirstResponder, "and focuses it")
        #expect(try selected("sshTerminal.bar.chatBar"))
        #expect(try !selected("sshTerminal.bar.keyboard"))

        try button("sshTerminal.bar.keyboard").sendActions(for: .touchUpInside)
        try await settle(mounted)
        #expect(grid.isFirstResponder, "Type in Terminal types into the terminal")
        #expect(draft() == nil)
        #expect(try selected("sshTerminal.bar.keyboard"))
        #expect(try !selected("sshTerminal.bar.chatBar"))
    }

    /// The screen updates its properties on the next runloop pass.
    private func settle(_ mounted: MountedTerminalTestController) async throws {
        for _ in 0..<4 {
            await Task.yield()
            mounted.host.view.setNeedsLayout()
            mounted.host.view.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(250))
        mounted.host.view.layoutIfNeeded()
    }
}

@MainActor
private final class MountedTerminalTestGrid {
    let host: UIViewController
    let window: UIWindow

    init(_ grid: SSHTerminalGridView) throws {
        let host = UIViewController()
        self.host = host
        grid.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func dismiss() {
        window.endEditing(true)  // a hidden window must not leave its keyboard up
        window.isHidden = true
        window.rootViewController = nil
    }

    func find(in view: UIView, matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = find(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

@MainActor
private final class MountedTerminalTestController {
    let controller: SSHTerminalViewController
    let host: UIViewController
    let window: UIWindow

    init(_ controller: SSHTerminalViewController) throws {
        self.controller = controller
        let nav = UINavigationController(rootViewController: controller)
        host = nav
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.view.layoutIfNeeded()
        // The grid only paints while its scene is foreground-active, and a system
        // alert on the simulator (the notification permission prompt) leaves the
        // test host inactive. These tests exercise the screen, not scene
        // activation, so say the app is active, as OrbMetalTests does.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func dismiss() {
        window.endEditing(true)  // a hidden window must not leave its keyboard up
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Sends a software keyboard an earlier test left behind away, and lets a
    /// dismissal already animating finish so the guide stops moving before the
    /// first measurement.
    ///
    /// This does not wait for an idle guide, because it cannot always get one:
    /// the simulator keeps a keyboard raised for a field whose window went away
    /// mid dismissal, no responder is left to resign it, and a test cannot
    /// dismiss a keyboard its process no longer owns. Everything the bar tests
    /// measure is relative to the guide the bar and the grid are both anchored
    /// to, so a raised keyboard shifts both and cancels out.
    func dismissStrayKeyboards() async {
        // Another test may have hidden its window with a field still focused;
        // that keeps the real keyboard up, and it is not in this window's chain.
        // OppiTests runs serially (not parallelizable in project.yml); with
        // parallel suites this would also unfocus a field another test is using.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.endEditing(true) }
        }
        for _ in 0..<10 {
            host.view.layoutIfNeeded()
            // A software keyboard is far taller than the home-indicator strip
            // the guide rests as.
            if controller.view.keyboardLayoutGuide.layoutFrame.height < 100 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func keyboardDiagnostics() -> String {
        func responders(in view: UIView) -> [String] {
            (view.isFirstResponder ? [String(describing: type(of: view))] : []) + view.subviews.flatMap(responders)
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows).map { (window: UIWindow) -> String in
            let root = window.rootViewController.map { String(describing: type(of: $0)) } ?? "none"
            return "hidden=\(window.isHidden) key=\(window.isKeyWindow) root=\(root) responders=\(responders(in: window))"
        }
        return "guide=\(controller.view.keyboardLayoutGuide.layoutFrame) windows=\(windows)"
    }

    func find(_ predicate: (UIView) -> Bool) -> UIView? {
        find(in: host.view, matching: predicate)
    }

    /// The person's explicit ask for the chat bar: the bottom bar's button.
    func tapChatBar() throws {
        let button = try #require(find { $0.accessibilityIdentifier == "sshTerminal.bar.chatBar" } as? UIButton)
        button.sendActions(for: .touchUpInside)
    }

    func find(in view: UIView, matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = find(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

@MainActor
private final class MountedTerminalComposer {
    let session: SSHTerminalComposerHost
    let bar: ComposerBarController
    let wrapper: UIViewController
    let window: UIWindow

    init(channel: SSHTerminalChannel) throws {
        session = SSHTerminalComposerHost(
            channel: channel,
            connection: nil,
            draftStore: nil,
            themeID: ThemeRuntimeState.currentThemeID(),
            showRawKeyboard: {}
        )
        bar = ComposerBarController()
        session.attach(bar)
        _ = bar.view
        bar.apply()
        wrapper = UIViewController()
        wrapper.addChild(bar)
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.view.addSubview(bar.view)
        NSLayoutConstraint.activate([
            bar.view.leadingAnchor.constraint(equalTo: wrapper.view.leadingAnchor),
            bar.view.trailingAnchor.constraint(equalTo: wrapper.view.trailingAnchor),
            bar.view.bottomAnchor.constraint(equalTo: wrapper.view.bottomAnchor),
        ])
        bar.didMove(toParent: wrapper)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = wrapper
        window.makeKeyAndVisible()
        wrapper.view.layoutIfNeeded()
    }

    func dismiss() {
        window.endEditing(true)  // a hidden window must not leave its keyboard up
        window.isHidden = true
        window.rootViewController = nil
    }

    func update() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            wrapper.view.setNeedsLayout()
            wrapper.view.layoutIfNeeded()
        }
    }

    func find(_ predicate: (UIView) -> Bool) -> UIView? {
        find(in: wrapper.view, matching: predicate)
    }

    func find(in view: UIView, matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = find(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

/// A terminal whose chat bar holds a six-line draft over a screen filled
/// down to its last row, so the cursor sits under the grown bar.
@MainActor
private final class GrownChatBarTerminal {
    let channel: SSHTerminalChannel
    let mounted: MountedTerminalTestController
    let grid: SSHTerminalGridView
    let bar: UIView

    init() async throws {
        channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        mounted = try MountedTerminalTestController(
            SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {})
        )
        channel.event(.data(Data("\u{1b}]7501;state=idle:app=pi\u{1b}\\".utf8)))
        try mounted.tapChatBar()
        try await Self.settle(mounted)
        let textView = try #require(mounted.find { $0 is PastableUITextView } as? PastableUITextView)
        grid = try #require(mounted.controller.gridView)
        let controllerView = mounted.controller.view
        bar = try #require(sequence(first: textView as UIView, next: \.superview).first { $0.superview === controllerView })
        channel.event(.data(Data(String(repeating: "output\r\n", count: 120).utf8)))
        channel.event(.data(Data("pi> ".utf8)))
        textView.text = "one\ntwo\nthree\nfour\nfive\nsix"
        textView.delegate?.textViewDidChange?(textView)
        try await Self.settle(mounted)
    }

    func close() {
        mounted.dismiss()
        channel.close(reason: "done")
    }

    private static func settle(_ mounted: MountedTerminalTestController) async throws {
        for _ in 0..<4 {
            await Task.yield()
            mounted.host.view.setNeedsLayout()
            mounted.host.view.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(250))
        mounted.host.view.layoutIfNeeded()
    }

    /// Writes `text` as one output chunk and waits for the frame that draws it.
    func output(_ text: String) async throws {
        channel.event(.data(Data(text.utf8)))
        try await nextFrame()
    }

    /// The display link's frame for what changed, without a layout pass. Run
    /// directly: a loaded simulator can delay real ticks past any timeout.
    func nextFrame() async throws {
        await Task.yield()
        grid.drawFrame()
    }

    /// Where the grid's picture starts on screen, shift included.
    func gridTop() -> CGFloat {
        grid.convert(CGPoint.zero, to: mounted.controller.view).y
    }

    func barTop() -> CGFloat {
        bar.convert(CGPoint.zero, to: mounted.controller.view).y
    }

    func cursorBottom() -> CGFloat {
        let row = channel.engine.cursorCell.row
        return grid.convert(CGPoint(x: 0, y: CGFloat(row + 1) * grid.cellSize.height), to: mounted.controller.view).y
    }
}

@MainActor
private final class SSHTerminalResizeLog {
    var sizes: [SSHTerminalGeometry] = []
}

private actor TerminalConnectionFixture: SSHTerminalConnection {
    nonisolated let bytes: AsyncStream<Data>
    nonisolated let resizes: AsyncStream<SSHTerminalGeometry>
    nonisolated let attempts: AsyncStream<Data>
    private let byteSink: AsyncStream<Data>.Continuation
    private let resizeSink: AsyncStream<SSHTerminalGeometry>.Continuation
    private let attemptSink: AsyncStream<Data>.Continuation
    private var suspendFirstSend: Bool
    private var suspendedSend: CheckedContinuation<Void, any Error>?
    private(set) var sentBytes = Data()

    init(suspendFirstSend: Bool = false) {
        (bytes, byteSink) = AsyncStream.makeStream()
        (resizes, resizeSink) = AsyncStream.makeStream()
        (attempts, attemptSink) = AsyncStream.makeStream()
        self.suspendFirstSend = suspendFirstSend
    }
    func send(_ data: Data) async throws {
        if suspendFirstSend {
            suspendFirstSend = false
            try await withCheckedThrowingContinuation { continuation in
                suspendedSend = continuation
                attemptSink.yield(data)
            }
        }
        sentBytes.append(data)
        byteSink.yield(data)
    }
    func rejectSuspendedSend() {
        suspendedSend?.resume(throwing: SSHConnectionError.notWritable)
        suspendedSend = nil
    }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        resizeSink.yield(.init(columns: columns, rows: rows,
                              cellWidth: pixelWidth / columns, cellHeight: pixelHeight / rows))
    }
    private(set) var runs = [(command: String, input: Data)]()
    private var runResult: SSHExecResult?
    private var commandResults: [String: SSHExecResult] = [:]
    func setRunResult(_ result: SSHExecResult) { runResult = result }
    /// The answer to one exact command; every other command gets `runResult`.
    func setRunResult(_ result: SSHExecResult, for command: String) { commandResults[command] = result }
    /// Commands that get no answer until `releaseHangs()`, as a host that
    /// stopped responding would leave them.
    private var hanging: Set<String> = []
    private var hung: [CheckedContinuation<Void, Never>] = []
    func hang(_ command: String) { hanging.insert(command) }
    func releaseHangs() {
        hanging.removeAll()
        hung.forEach { $0.resume() }
        hung.removeAll()
    }
    private var hosts: [RexFakeHost] = []
    private(set) var streamCommands: [String] = []
    /// The Rex server the next `openStream` reaches; none left, none reachable.
    func queue(_ host: RexFakeHost) { hosts.append(host) }
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        streamCommands.append(command)
        guard !hosts.isEmpty else { throw SSHConnectionError.notConnected }
        return hosts.removeFirst().open(sink: sink)
    }
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        runs.append((command, input))
        if hanging.contains(command) {
            await withCheckedContinuation { hung.append($0) }
            throw SSHConnectionError.requestTimedOut
        }
        guard let result = commandResults[command] ?? runResult else { throw SSHConnectionError.commandRequestRejected }
        return result
    }
    private var alive = true
    func setAlive(_ value: Bool) { alive = value }
    func checkAlive() throws { if !alive { throw SSHConnectionError.requestTimedOut } }
    nonisolated func close() {}
    func cancel() {
        suspendedSend?.resume(throwing: SSHConnectionError.connectionClosed)
        suspendedSend = nil
        byteSink.finish()
        resizeSink.finish()
        attemptSink.finish()
    }
}

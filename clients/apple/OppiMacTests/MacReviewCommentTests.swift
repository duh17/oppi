import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("Mac review comment selection")
struct MacReviewCommentSelectionTests {
    @Test func normalizesLineEndingsAndTrimsOuterWhitespace() {
        let result = MacReviewCommentSelectionFormatting.normalizedSelectedText("  first\r\nsecond\rthird  \n")
        #expect(result == "first\nsecond\nthird")
    }

    @Test func preservesInternalWhitespace() {
        let result = MacReviewCommentSelectionFormatting.normalizedSelectedText("let  value = 42")
        #expect(result == "let  value = 42")
    }

    @Test func emptyOrWhitespaceSelectionIsRejected() {
        #expect(MacReviewCommentSelectionFormatting.normalizedSelectedText("   \n\t") == "")
        #expect(!MacReviewCommentMenu.shouldOfferComment("   \n"))
        #expect(MacReviewCommentMenu.shouldOfferComment("let value = 1"))
        #expect(MacReviewCommentMenu.addCommentTitle == "Add Review Comment…")
    }

    @Test func mapsSelectedUTF16RangeToSourceLineNumbers() {
        let text = "alpha\nbeta\ngamma"
        let range = (text as NSString).range(of: "beta")
        let local = MacReviewCommentSelectionFormatting.textLineRange(in: text, range: range)
        #expect(local == 2...2)
        #expect(
            MacReviewCommentSelectionFormatting.absoluteLineRange(local: 2...3, startLine: 20)
                == 21...22
        )
    }

    @Test func codeWithAPathBecomesAFileReference() throws {
        let text = "let value = 1\nlet next = 2"
        let range = (text as NSString).range(of: "let value = 1")
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: range,
                in: text,
                source: MacReviewCommentSource(
                    kind: .file,
                    path: "App.swift",
                    languageHint: "swift",
                    timelineItemId: "tool-a",
                    startLine: 10
                )
            )
        )

        #expect(draft.reference.source == .file)
        #expect(draft.reference.path == "App.swift")
        #expect(draft.reference.selectedText == "let value = 1")
        #expect(draft.reference.startLine == 10)
        #expect(draft.reference.endLine == 10)
        #expect(draft.reference.languageHint == "swift")
        #expect(draft.reference.timelineItemId == "tool-a")
    }

    @Test func terminalSelectionUsesTerminalOutputSource() throws {
        let text = "App.swift\nmain.go"
        let range = (text as NSString).range(of: "main.go")
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "main.go",
                utf16Range: range,
                in: text,
                source: MacReviewCommentSource(
                    kind: .terminalOutput,
                    label: "bash",
                    timelineItemId: "tool-bash"
                )
            )
        )

        #expect(draft.reference.source == .terminalOutput)
        #expect(draft.reference.label == "bash")
        #expect(draft.reference.startLine == 2)
        #expect(draft.reference.endLine == 2)
        #expect(draft.reference.timelineItemId == "tool-bash")
    }

    @Test func fileBackedSelectionUsesFileSourceNotTerminalOutput() {
        let withPath = MacReviewCommentSource.fileDocument(
            path: "notes.txt",
            itemID: "tool-read",
            startLine: 4
        )
        #expect(withPath.kind == .file)
        #expect(withPath.path == "notes.txt")
        #expect(withPath.kind != .terminalOutput)
        #expect(withPath.timelineItemId == "tool-read")
        #expect(withPath.startLine == 4)

        #expect(MacReviewCommentSource.selectable(filePath: "App.swift").kind == .file)
        #expect(MacReviewCommentSource.selectable(filePath: "App.swift").path == "App.swift")
        #expect(MacReviewCommentSource.selectable(filePath: nil).kind == .timelineText)
        #expect(MacReviewCommentSource.selectable(filePath: "").kind == .timelineText)
    }

    @Test func whitespaceOnlySelectionDoesNotBuildADraft() {
        let text = "keep this"
        #expect(
            MacReviewCommentDraft.make(
                selectedText: "   \n",
                utf16Range: NSRange(location: 0, length: 4),
                in: text,
                source: MacReviewCommentSource(kind: .file, path: "App.swift")
            ) == nil
        )
    }

    @MainActor
    @Test func menuInsertsCommentItemOnlyWhenSelectionIsHonest() {
        let withSelection = MacReviewCommentMenuBuilder.menu(
            insertingCommentInto: NSMenu(),
            selectedText: "let value = 1"
        )
        #expect(withSelection.items.first?.title == MacReviewCommentMenu.addCommentTitle)

        let withCopy = NSMenu()
        withCopy.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c"))
        let mixed = MacReviewCommentMenuBuilder.menu(
            insertingCommentInto: withCopy,
            selectedText: "let value = 1"
        )
        #expect(mixed.items.first?.title == MacReviewCommentMenu.addCommentTitle)
        #expect(mixed.items.contains { $0.isSeparatorItem })

        let empty = MacReviewCommentMenuBuilder.menu(
            insertingCommentInto: NSMenu(),
            selectedText: "  "
        )
        #expect(empty.items.isEmpty)
    }
}

@Suite("Mac review comment store wiring")
@MainActor
struct MacReviewCommentStoreTests {
    @Test func stagesACommentFromDocumentSelection() throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        store.select(makeReviewTarget())

        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: NSRange(location: 0, length: 13),
                in: "let value = 1\nlet next = 2",
                source: MacReviewCommentSource(kind: .file, path: "App.swift", startLine: 1)
            )
        )

        #expect(store.saveReviewComment(body: "  Tighten this.  ", draft: draft) == nil)
        #expect(store.stagedReviewCommentCount == 1)
        #expect(store.stagedReviewComments.first?.body == "Tighten this.")
        #expect(store.stagedReviewComments.first?.reference.path == "App.swift")
        #expect(store.stagedReviewComments.first?.reference.selectedText == "let value = 1")
    }

    @Test func rejectsAnEmptyCommentBody() throws {
        let store = MacSessionTraceStore(reviewComments: try makeComments())
        store.select(makeReviewTarget())
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: NSRange(location: 0, length: 13),
                in: "let value = 1",
                source: MacReviewCommentSource(kind: .file, path: "App.swift")
            )
        )

        #expect(store.saveReviewComment(body: "   \n", draft: draft) != nil)
        #expect(store.stagedReviewCommentCount == 0)
    }

    @Test func sendAppendsTheReviewBlockAndClearsStagedComments() async throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        let target = makeReviewTarget()
        store.select(target)
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "guard let value else { return }",
                utf16Range: NSRange(location: 0, length: 31),
                in: "guard let value else { return }",
                source: MacReviewCommentSource(kind: .file, path: "Sources/App.swift", startLine: 12)
            )
        )
        #expect(store.saveReviewComment(body: "Check the nil path.", draft: draft) == nil)

        let sent = SentReviewMessageBox()
        store._sendLiveMessageForTesting = { message in
            sent.message = message
            return true
        }

        let didSend = await store.sendPrompt(
            "Please fix this.",
            target: target,
            client: unusedReviewClient
        )

        #expect(didSend)
        #expect(store.stagedReviewCommentCount == 0)
        switch sent.message {
        case .prompt(let text, _, _, _, _):
            #expect(text.contains("Please fix this."))
            #expect(text.contains("## Review comments"))
            #expect(text.contains("Check the nil path."))
            #expect(text.contains("guard let value else { return }"))
        default:
            Issue.record("Expected prompt, got \(String(describing: sent.message))")
        }
    }

    @Test func failedSendKeepsStagedComments() async throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        let target = makeReviewTarget()
        store.select(target)
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: NSRange(location: 0, length: 13),
                in: "let value = 1",
                source: MacReviewCommentSource(kind: .file, path: "App.swift")
            )
        )
        #expect(store.saveReviewComment(body: "Keep this.", draft: draft) == nil)

        store._sendLiveMessageForTesting = { _ in
            throw MacSessionTraceStoreError.commandRejected("offline")
        }

        let didSend = await store.sendPrompt(
            "Please fix this.",
            target: target,
            client: unusedReviewClient
        )

        #expect(!didSend)
        #expect(store.stagedReviewCommentCount == 1)
        #expect(store.stagedReviewComments.first?.body == "Keep this.")
    }

    @Test func commentsAloneAreEnoughToSend() throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        store.select(makeReviewTarget())
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: NSRange(location: 0, length: 13),
                in: "let value = 1",
                source: MacReviewCommentSource(kind: .file, path: "App.swift")
            )
        )
        #expect(store.saveReviewComment(body: "Tighten this.", draft: draft) == nil)
        #expect(store.hasStagedReviewComments)
        #expect(MacReviewCommentComposerPaint.stashTitle(count: 1) == "1 review comment staged")
        #expect(MacReviewCommentComposerPaint.sendPlaceholder(count: 2) == "Send 2 review comments…")
    }

    @Test func changingSessionsLoadsThatSessionDrafts() throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        store.select(makeReviewTarget(sessionId: "session-a"))
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "one",
                utf16Range: NSRange(location: 0, length: 3),
                in: "one",
                source: MacReviewCommentSource(kind: .file, path: "A.swift")
            )
        )
        #expect(store.saveReviewComment(body: "Session A note.", draft: draft) == nil)
        #expect(store.stagedReviewCommentCount == 1)

        store.select(makeReviewTarget(sessionId: "session-b"))
        #expect(store.stagedReviewCommentCount == 0)

        store.select(makeReviewTarget(sessionId: "session-a"))
        #expect(store.stagedReviewCommentCount == 1)
        #expect(store.stagedReviewComments.first?.body == "Session A note.")
    }

    @Test func sendDoesNotClearCommentsIfSessionChanged() async throws {
        let comments = try makeComments()
        let store = MacSessionTraceStore(reviewComments: comments)
        let sessionA = makeReviewTarget(sessionId: "session-a")
        store.select(sessionA)
        let draft = try #require(
            MacReviewCommentDraft.make(
                selectedText: "let value = 1",
                utf16Range: NSRange(location: 0, length: 13),
                in: "let value = 1",
                source: MacReviewCommentSource.fileDocument(path: "App.swift")
            )
        )
        #expect(store.saveReviewComment(body: "Keep this on A.", draft: draft) == nil)

        store._sendLiveMessageForTesting = { _ in
            store.select(makeReviewTarget(sessionId: "session-b"))
            return true
        }

        let didSend = await store.sendPrompt(
            "Please fix this.",
            target: sessionA,
            client: unusedReviewClient
        )

        #expect(didSend)
        store.select(sessionA)
        #expect(store.stagedReviewCommentCount == 1)
        #expect(store.stagedReviewComments.first?.body == "Keep this on A.")
    }
}

@Suite("Mac review comment paint")
struct MacReviewCommentPaintTests {
    @MainActor
    @Test func plainTextPaintTracksLiveThemeWithoutOverwritingAttributedContent() {
        let textView = NSTextView()
        let initial = NSColor(deviceRed: 0.15, green: 0.25, blue: 0.35, alpha: 1)
        let refreshed = NSColor(deviceRed: 0.75, green: 0.65, blue: 0.55, alpha: 1)

        MacReviewCommentTextPaint.applyPlainTextColor(
            initial,
            to: textView,
            usesAttributedText: false
        )
        #expect(textView.textColor?.isEqual(initial) == true)
        #expect(textView.insertionPointColor.isEqual(initial))

        MacReviewCommentTextPaint.applyPlainTextColor(
            refreshed,
            to: textView,
            usesAttributedText: false
        )
        #expect(textView.textColor?.isEqual(refreshed) == true)
        #expect(textView.insertionPointColor.isEqual(refreshed))

        MacReviewCommentTextPaint.applyPlainTextColor(
            initial,
            to: textView,
            usesAttributedText: true
        )
        #expect(textView.textColor?.isEqual(refreshed) == true)
    }

    @Test func reviewTextViewReappliesPlainTextPaintDuringUpdates() throws {
        let textView = try source(named: "OppiMac/Views/MacReviewCommentTextView.swift")
        #expect(textView.contains("MacReviewCommentTextPaint.applyPlainTextColor("))
        #expect(textView.contains("usesAttributedText: attributedText != nil"))
    }

    @Test func documentColumnUsesNSTextViewSelectionAndOmitsIOSMenus() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        #expect(column.contains("MacReviewCommentTextView"))
        #expect(column.contains("mac.documentColumn.code"))
        #expect(column.contains("mac.documentColumn.terminal"))
        #expect(!column.contains(".sheet("))
        #expect(!column.contains("UIMenu"))
        #expect(!column.contains("UIAction"))
        #expect(!column.contains("QuickComment"))
        #expect(!column.contains("ChatView"))
        #expect(!column.contains("ChatReviewCommentsController"))
        #expect(!column.contains("command: file.filePath"))
        #expect(column.contains("MacReviewCommentSource.fileDocument"))
    }

    @Test func timelineCodeAndTerminalReuseTheSameNSTextView() throws {
        let timeline = try source(named: "OppiMac/Views/MacSessionTimelineViews.swift")
        #expect(timeline.contains("MacReviewCommentTextView"))
        #expect(!timeline.contains("UIMenu"))
        #expect(!timeline.contains("QuickComment"))
        #expect(!timeline.contains("ChatView"))
    }

    @Test func sessionShellStagesCommentsWithoutCopyingIOSSelectionMenus() throws {
        let shell = try source(named: "OppiMac/Views/MacSessionShellViews.swift")
        let composer = try source(named: "OppiMac/Views/MacSessionComposerBar.swift")
        #expect(shell.contains("MacReviewCommentStaging"))
        #expect(shell.contains("MacReviewCommentSource.fileDocument"))
        #expect(composer.contains("mac.composer.reviewComments.stash"))
        #expect(composer.contains("MacReviewCommentStashSheet"))
        #expect(composer.contains("MacReviewCommentComposerSheet"))
        #expect(!composer.contains("swipeActions"))
        #expect(!composer.contains("ChatInputBar<"))
        #expect(!composer.contains("UIMenu"))
        #expect(!shell.contains("ChatView"))
        #expect(!shell.contains("QuickComment"))
    }

    @Test func workspaceGitReviewStillDoesNotFakeComments() throws {
        let gitView = try source(named: "OppiMac/Views/MacWorkspaceGitStatusView.swift")
        let gitStore = try source(named: "OppiMac/Stores/MacWorkspaceGitReviewStore.swift")
        #expect(!gitView.contains("ReviewComment"))
        #expect(!gitView.contains("Leave a comment"))
        #expect(!gitStore.contains("ReviewComment"))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
private func makeComments() throws -> ReviewCommentStore {
    let suiteName = "MacReviewCommentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return ReviewCommentStore(defaults: defaults, keyPrefix: "test.mac.reviewComments")
}

private func makeReviewTarget(sessionId: String = "session-review") -> MacSelectedSessionTarget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(
        id: sessionId,
        workspaceId: "workspace-review",
        workspaceName: "Workspace",
        status: .ready,
        createdAt: now,
        lastActivity: now,
        model: "provider/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello",
        runtime: .oppi
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace-review",
        sessionId: session.id,
        summary: SessionSummary(from: session)
    )
}

private let unusedReviewClient = MacWorkspaceClient(
    socketPath: "/tmp/oppi-mac-review-unused.sock",
    token: "test"
)

@MainActor
private final class SentReviewMessageBox {
    var message: ClientMessage?
}

import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Basic")
@MainActor
struct TimelineReducerBasicTests {

    @Test func basicAgentTurn() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Hello "))
        reducer.process(.textDelta(sessionId: "s1", delta: "world!"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Hello world!")
    }

    @Test func thinkingThenText() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "I need to "))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "think..."))
        reducer.process(.textDelta(sessionId: "s1", delta: "The answer is 42."))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 2) // thinking + assistant
        guard case .thinking(_, let preview, _, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("I need to think"))
    }

    @Test func thinkingStreamingShowsPreviewBeforeFinalization() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "Let me "))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "analyze this"))

        // Mid-stream: thinking item exists with isDone == false and preview text
        #expect(reducer.items.count == 1)
        guard case .thinking(_, let preview, _, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking item during streaming")
            return
        }
        #expect(preview.contains("Let me analyze"))
        #expect(!isDone) // Still streaming

        // Finalize
        reducer.process(.textDelta(sessionId: "s1", delta: "Answer."))
        reducer.process(.agentEnd(sessionId: "s1"))

        // After finalization: thinking isDone, then assistant message
        #expect(reducer.items.count == 2)
        guard case .thinking(_, _, _, let finalDone) = reducer.items[0] else {
            Issue.record("Expected thinking item after finalization")
            return
        }
        #expect(finalDone)
    }

    @Test func multipleAgentTurns() {
        let reducer = TimelineReducer()

        // Turn 1
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "First"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // Turn 2
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Second"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let assistants = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistants.count == 2)

        guard case .assistantMessage(_, let t1, _) = assistants[0],
              case .assistantMessage(_, let t2, _) = assistants[1] else {
            Issue.record("Expected two assistant messages")
            return
        }
        #expect(t1 == "First")
        #expect(t2 == "Second")
    }

    @Test func agentEndWithoutContentProducesNoItems() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // No text deltas → no assistant message or thinking item
        #expect(reducer.items.isEmpty)
    }

    @Test func appendUserMessage() {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("Hello from user")

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "Hello from user")
    }

    @Test func appendSystemEvent() {
        let reducer = TimelineReducer()

        reducer.appendSystemEvent("Session force-stopped")

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent")
            return
        }
        #expect(msg == "Session force-stopped")
    }

    @Test func loadSessionUsesInjectedEnvironmentForPrewarmAndLogging() {
        var cancelCount = 0
        var cacheClearCount = 0
        var prewarmedTexts: [[String]] = []
        var logMessages: [String] = []
        let environment = TimelineReducerEnvironment(
            markdownPrewarmer: TimelineMarkdownPrewarmer(
                cachePurgeItemThreshold: 0,
                cancel: { cancelCount += 1 },
                clearCache: { cacheClearCount += 1 },
                prewarm: { prewarmedTexts.append($0) }
            ),
            logLoadSession: { logMessages.append($0) }
        )
        let reducer = TimelineReducer(environment: environment)

        reducer.loadSession([
            TraceEvent(
                id: "a1",
                type: .assistant,
                timestamp: "2025-01-01T00:00:00.000Z",
                text: "hello"
            )
        ])
        reducer.reset()

        #expect(cancelCount == 2)
        #expect(cacheClearCount == 1)
        #expect(prewarmedTexts == [["hello"]])
        #expect(logMessages.count == 1)
        #expect(logMessages[0].contains("full rebuild"))
    }

    @Test func userMessageProjectionStripsAttachmentMetadataForComparison() {
        let marked = "[[oppi-attachments:b:photos=1;p:repoFile=README.md]]\nhello"
        #expect(UserMessageTextProjection.comparableText(marked) == "hello")

        let withFiles = "hello\n\nAttached files:\n- report.pdf: .pi/attachments/report.pdf"
        #expect(UserMessageTextProjection.comparableText(withFiles) == "hello")

        let withReferences = "hello\n\nReferenced workspace files:\n- Sources/App.swift"
        #expect(UserMessageTextProjection.comparableText(withReferences) == "hello")

        let withCommit = "hello\n\nSelected commit:\n- SHA: 9b82f81\n- Message: Fix composer chips"
        #expect(UserMessageTextProjection.comparableText(withCommit) == "hello")
        #expect(UserMessageTextProjection.visibleText(from: withCommit) == "hello")
    }

    @Test func userMessageProjectionMatchesOptimisticSkillCommandToReloadedSkillBlock() {
        let live = "/skill:demo investigate this"
        let reloaded = """
        <skill name="demo" location="/tmp/SKILL.md">
        # Demo
        </skill>

        investigate this
        """
        let reducer = TimelineReducer()
        reducer.appendUserMessage(live)

        #expect(UserMessageTextProjection.comparableText(live) == UserMessageTextProjection.comparableText(reloaded))
        #expect(reducer.hasUserMessage(matching: reloaded))
    }

    @Test func userMessageProjectionKeepsOrdinaryMultilineTextDistinctFromSingleLine() {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("alpha\nbeta")

        #expect(UserMessageTextProjection.comparableText("alpha\nbeta") == "alpha\nbeta")
        #expect(UserMessageTextProjection.comparableText("alpha beta") == "alpha beta")
        #expect(!reducer.hasUserMessage(matching: "alpha beta"))
    }

    @Test func userMessageProjectionPreservesReservedHeadersUsedAsProse() {
        let commitPrompt = """
        Extra focus:
        Referenced workspace files: - Sources/App.swift

        Git hygiene:
        - Do not commit unless explicitly asked.
        """
        #expect(UserMessageTextProjection.visibleText(from: commitPrompt) == commitPrompt)

        let attachmentProse = """
        Attached files: explanatory text

        Checklist:
        - report.pdf: keep this visible
        """
        #expect(UserMessageTextProjection.visibleText(from: attachmentProse) == attachmentProse)

        let leadingSpaceHeader = " Referenced workspace files:\n- Keep this instruction visible."
        #expect(
            UserMessageTextProjection.visibleText(from: leadingSpaceHeader)
                == "Referenced workspace files:\n- Keep this instruction visible."
        )
    }

    @Test func userMessageProjectionMatchesScreenshotEchoWithImageHintSuffix() {
        let typed = "look at this screenshot"
        let echo = """
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        """

        #expect(UserMessageTextProjection.visibleText(from: echo) == typed)
        #expect(UserMessageTextProjection.comparableText(echo) == typed)

        let reducer = TimelineReducer()
        let image = ImageAttachment(data: "AAAA", mimeType: "image/png")
        let optimisticID = reducer.appendUserMessage(typed, images: [image])
        #expect(reducer.hasUserMessage(matching: echo))

        if !reducer.hasUserMessage(matching: echo) {
            reducer.appendUserMessage(echo)
        }

        #expect(reducer.items.count == 1)
        guard case .userMessage(let id, let text, let images, _) = reducer.items[0] else {
            Issue.record("Expected the optimistic image row to remain")
            return
        }
        #expect(id == optimisticID)
        #expect(text == typed)
        #expect(images == [image])
    }

    @Test(arguments: [
        "[Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]",
        "[Image converted from image/jpeg to image/png.]",
        "[Image omitted: could not be resized below the inline image size limit.]",
        "[Image omitted: could not be converted to a supported inline image format.]",
        "[Image: resized for a future model profile.]",
    ])
    func userMessageProjectionStripsEachPiImageHintAfterAttachedFilesBlock(_ hint: String) {
        let typed = "look at this screenshot"
        let echo = """
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png
          MIME: image/png
          Size: 2 MB

        \(hint)
        """
        #expect(UserMessageTextProjection.visibleText(from: echo) == typed)
        #expect(UserMessageTextProjection.comparableText(echo) == typed)
    }

    @Test func userMessageProjectionStripsMultiplePiImageHintsAfterAttachedFilesBlock() {
        let typed = "look at this screenshot"
        let echo = """
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Image converted from image/jpeg to image/png.]
        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        [Image omitted: could not be resized below the inline image size limit.]
        """
        #expect(UserMessageTextProjection.visibleText(from: echo) == typed)
        #expect(UserMessageTextProjection.comparableText(echo) == typed)
    }

    @Test func userMessageProjectionMatchesMarkerRowToHintedAttachmentEcho() {
        let typed = "look at this screenshot"
        let optimistic = """
        [[oppi-attachments:b:photos=1]]
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png
        """
        let echo = """
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        """
        let reducer = TimelineReducer()
        reducer.appendUserMessage(
            optimistic,
            images: [ImageAttachment(data: "AAAA", mimeType: "image/png")]
        )

        #expect(UserMessageTextProjection.comparableText(optimistic) == typed)
        #expect(UserMessageTextProjection.comparableText(echo) == typed)
        #expect(reducer.hasUserMessage(matching: echo))
        #expect(!reducer.hasUserMessage(matching: "ship the fix"))
    }

    @Test func imageOnlyHintEchoKeepsOptimisticImageRow() {
        let image = ImageAttachment(data: "AAAA", mimeType: "image/png")
        let optimistic = "[[oppi-attachments:b:photos=1]]"
        let echo = """
        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        [Image converted from image/jpeg to image/png.]
        [Image omitted: could not be resized below the inline image size limit.]
        """
        let reducer = TimelineReducer()
        let optimisticID = reducer.appendUserMessage(optimistic, images: [image])
        #expect(reducer.hasUserMessage(matching: echo))
        #expect(reducer.hasLatestImageUserMessage(matchingEcho: echo))

        if !reducer.hasUserMessage(matching: echo),
           !reducer.hasLatestImageUserMessage(matchingEcho: echo) {
            reducer.appendUserMessage(echo)
        }

        #expect(reducer.items.count == 1)
        guard case .userMessage(let id, let text, let images, _) = reducer.items[0] else {
            Issue.record("Expected the optimistic image row to remain")
            return
        }
        #expect(id == optimisticID)
        #expect(text == optimistic)
        #expect(images == [image])
    }

    @Test func historyReloadDoesNotReappendCleanOptimisticRowWhenTraceHasImageHints() {
        let typed = "look at this screenshot"
        let optimistic = """
        [[oppi-attachments:b:photos=1]]
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png
        """
        let echo = """
        \(typed)

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        """
        let reducer = TimelineReducer()
        let optimisticID = reducer.appendUserMessage(
            optimistic,
            images: [ImageAttachment(data: "AAAA", mimeType: "image/png")]
        )
        reducer.appendUserMessage("ship the fix")
        reducer.loadSession([
            TraceEvent(
                id: "trace-user",
                type: .user,
                timestamp: "2025-01-01T00:00:00.000Z",
                text: echo
            )
        ])

        let userRows: [(id: String, text: String)] = reducer.items.compactMap { item in
            guard case .userMessage(let id, let text, _, _) = item else { return nil }
            return (id, text)
        }
        #expect(userRows.count == 2)
        #expect(userRows[0].id == "trace-user")
        #expect(!userRows.map(\.id).contains(optimisticID))
        #expect(UserMessageTextProjection.comparableText(userRows[0].text) == typed)
        #expect(userRows[1].text == "ship the fix")
    }

    @Test func userMessageProjectionStripsEveryImageHintInAMultiImageSend() {
        let typed = "compare these screenshots"
        let echo = """
        \(typed)

        Attached files:
        - one.png: .pi/attachments/s1/t1/one.png
          MIME: image/png
          Size: 1 MB
        - two.jpg: .pi/attachments/s1/t1/two.jpg
          MIME: image/jpeg
          Size: 2 MB
        - three.png: .pi/attachments/s1/t1/three.png

        [Image converted from image/jpeg to image/png.]
        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        [Image: original 800x600, displayed at 800x600. Multiply coordinates by 1.00 to map to original image.]
        [Image omitted: could not be resized below the inline image size limit.]
        [Image: future wording that is still an image hint.]
        """
        #expect(UserMessageTextProjection.visibleText(from: echo) == typed)
        #expect(UserMessageTextProjection.comparableText(echo) == typed)
        #expect(
            UserMessageTextProjection.attachmentPaths(from: echo) == [
                ".pi/attachments/s1/t1/one.png",
                ".pi/attachments/s1/t1/two.jpg",
                ".pi/attachments/s1/t1/three.png",
            ]
        )

        let reducer = TimelineReducer()
        let images = [
            ImageAttachment(data: "one", mimeType: "image/png"),
            ImageAttachment(data: "two", mimeType: "image/jpeg"),
            ImageAttachment(data: "three", mimeType: "image/png"),
        ]
        let optimisticID = reducer.appendUserMessage(
            "[[oppi-attachments:b:photos=3]]\n\(typed)",
            images: images
        )
        #expect(reducer.hasUserMessage(matching: echo))
        #expect(reducer.hasLatestImageUserMessage(matchingEcho: echo))
        #expect(reducer.items.count == 1)
        guard case .userMessage(let id, _, let keptImages, _) = reducer.items[0] else {
            Issue.record("Expected the optimistic multi-image row to remain")
            return
        }
        #expect(id == optimisticID)
        #expect(keptImages == images)
    }

    @Test func distinctImageOnlySendsDoNotCollapse() {
        let firstOptimistic = "[[oppi-attachments:b:photos=1]]"
        let secondOptimistic = "[[oppi-attachments:b:photos=2]]"
        let firstEcho = """
        Attached files:
        - one.png: .pi/attachments/s1/t1/one.png

        [Image: original 100x100, displayed at 100x100. Multiply coordinates by 1.00 to map to original image.]
        """
        let reducer = TimelineReducer()
        reducer.appendUserMessage(firstOptimistic, images: [ImageAttachment(data: "one", mimeType: "image/png")])
        reducer.appendUserMessage(
            secondOptimistic,
            images: [
                ImageAttachment(data: "one", mimeType: "image/png"),
                ImageAttachment(data: "two", mimeType: "image/png"),
            ]
        )
        reducer.loadSession([
            TraceEvent(id: "trace-one", type: .user, timestamp: "2025-01-01T00:00:00.000Z", text: firstEcho)
        ])

        let userTexts: [String] = reducer.items.compactMap { item in
            guard case .userMessage(_, let text, _, _) = item else { return nil }
            return text
        }
        #expect(userTexts.count == 2)
        #expect(userTexts[0] == firstEcho)
        #expect(userTexts[1] == secondOptimistic)
    }

    @Test func rewrittenEchoWithTheSameImagesDoesNotNeedASecondRow() {
        let optimistic = """
        look at both

        Attached files:
        - one.png: .pi/attachments/s1/t1/one.png
        - two.png: .pi/attachments/s1/t1/two.png
        """
        let echo = """
        an extension rewrote the prompt

        Attached files:
        - one.png: .pi/attachments/s1/t1/one.png
        - two.png: .pi/attachments/s1/t1/two.png

        [Image: future wording.]
        """
        let reducer = TimelineReducer()
        let images = [
            ImageAttachment(data: "one", mimeType: "image/png"),
            ImageAttachment(data: "two", mimeType: "image/png"),
        ]
        let composer = """
        [[oppi-attachments:b:photos=2]]
        look at both
        """
        reducer.appendUserMessage(composer, images: images)
        #expect(!reducer.hasUserMessage(matching: echo))
        #expect(reducer.hasLatestImageUserMessage(matchingEcho: echo))
        #expect(reducer.items.count == 1)
    }

    @Test func userMessageProjectionDoesNotStripNonHintSuffixesOrBareAttachedFilesHeadings() {
        let arbitraryBracket = """
        See the note.

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        [Note: keep this user note visible.]
        """
        #expect(UserMessageTextProjection.visibleText(from: arbitraryBracket) == arbitraryBracket)

        let fileBlock = """
        Keep the file block.

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png

        <file name="screenshot.png">
        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        </file>
        """
        #expect(UserMessageTextProjection.visibleText(from: fileBlock) == fileBlock)

        let bareHeading = """
        Attached files:
        look at the screenshot
        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]
        """
        #expect(UserMessageTextProjection.visibleText(from: bareHeading) == bareHeading)

        let leadingHint = """
        [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]

        Please inspect this.

        Attached files:
        - screenshot.png: .pi/attachments/s1/t1/screenshot.png
        """
        #expect(
            UserMessageTextProjection.visibleText(from: leadingHint)
                == """
                [Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]

                Please inspect this.
                """
        )
    }

    @Test func retryStartRendersAsError() {
        let reducer = TimelineReducer()
        reducer.process(.retryStart(sessionId: "s1", attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: "rate limit"))

        #expect(reducer.items.count == 1)
        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected error for retry, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("Retrying"))
        #expect(msg.contains("1/3"))
    }

    @Test func realErrorRendersAsError() {
        let reducer = TimelineReducer()
        reducer.process(.error(sessionId: "s1", message: "Something went wrong"))

        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected error")
            return
        }
        #expect(msg == "Something went wrong")
    }
}

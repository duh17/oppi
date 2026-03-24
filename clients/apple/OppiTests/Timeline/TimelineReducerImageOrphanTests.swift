import Testing
import Foundation
@testable import Oppi

/// Tests for user messages with images flowing through loadSession.
///
/// Regression suite for the bug where a user message with images ends up
/// at the wrong timeline position after a history reload. Root cause:
/// ImageExtractor's regex includes `\n` in the base64 character class,
/// which greedily consumes into the next data URI when trace text joins
/// content blocks with newlines. This causes:
///   1. Second+ images not extracted → raw base64 left in "clean" text
///   2. Orphan detection text mismatch → duplicate user message at wrong position
@Suite("TimelineReducer — Image Orphan Detection")
@MainActor
struct TimelineReducerImageOrphanTests {

    // A small valid JPEG header in base64 (enough to test regex matching)
    private static let fakeBase64A = "AAAA1234BBBB5678"
    private static let fakeBase64B = "CCCC9012DDDD3456"

    // MARK: - ImageExtractor regression

    @Test func extractorFindsMultipleImagesJoinedByNewlines() {
        let text = "message text\ndata:image/jpeg;base64,\(Self.fakeBase64A)\ndata:image/png;base64,\(Self.fakeBase64B)"
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 2, "Should find both images when separated by newlines")
        guard images.count >= 2 else { return }
        #expect(images[0].mimeType == "image/jpeg")
        #expect(images[0].base64 == Self.fakeBase64A)
        #expect(images[1].mimeType == "image/png")
        #expect(images[1].base64 == Self.fakeBase64B)
    }

    @Test func extractorCleanTextMatchesOriginalAfterStrippingNewlineSeparatedURIs() {
        let userText = "let's improve the experience"
        let traceText = "\(userText)\ndata:image/jpeg;base64,\(Self.fakeBase64A)\ndata:image/png;base64,\(Self.fakeBase64B)"

        let images = ImageExtractor.extract(from: traceText)
        #expect(images.count == 2)

        // Simulate extractImagesFromText behavior
        var cleanText = traceText
        for image in images.reversed() {
            cleanText.removeSubrange(image.range)
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(cleanText == userText,
                "Clean text after stripping newline-separated data URIs should match original user text")
    }

    @Test func extractorStillHandlesNewlinesInsideBase64() {
        // PEM-style line-wrapped base64 (single image, newlines within data)
        let text = "data:image/gif;base64,R0lGODlh\nAQABAIAAAP///wAAA\nCH5BAEAAA=="
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 1, "Should handle newlines within a single image's base64")
        #expect(!images[0].base64.contains("\n"), "Newlines should be stripped from extracted base64")
    }

    @Test func extractorMultipleImagesWithSpaceSeparator() {
        // Existing behavior: space-separated should still work
        let text = "data:image/png;base64,\(Self.fakeBase64A) data:image/jpeg;base64,\(Self.fakeBase64B)"
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 2)
    }

    // MARK: - loadSession orphan detection with images

    @Test func loadSessionWithImageUserMessageNoOrphan() {
        let reducer = TimelineReducer()

        // Simulate: user sent prompt with images, then left
        let initialTrace: [TraceEvent] = [
            .init(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                  text: "Hello", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                  text: "Hi there", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(initialTrace)

        // User sends a new message with images (optimistic local insert)
        let userText = "check this out"
        let attachment = ImageAttachment(data: Self.fakeBase64A, mimeType: "image/jpeg")
        _ = reducer.appendUserMessage(userText, images: [attachment])
        #expect(reducer.items.count == 3)

        // Fresh trace includes the user message with data URIs (as pi records it)
        let traceUserText = "\(userText)\ndata:image/jpeg;base64,\(Self.fakeBase64A)"
        let freshTrace = initialTrace + [
            .init(id: "e3", type: .user, timestamp: "2025-01-01T00:00:02.000Z",
                  text: traceUserText, tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "e4", type: .assistant, timestamp: "2025-01-01T00:00:03.000Z",
                  text: "Got it, analyzing...", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(freshTrace)

        // Should have exactly 4 items: user, assistant, user (from trace), assistant
        #expect(reducer.items.count == 4, "No duplicate user message should exist")

        // The user message should be at index 2 (between old and new turns)
        guard case .userMessage(_, let text, let images, _) = reducer.items[2] else {
            Issue.record("Expected userMessage at index 2, got \(reducer.items[2])")
            return
        }
        #expect(text == userText, "User message text should be clean (no base64)")
        #expect(images.count == 1, "Should have extracted image attachment from trace")
    }

    @Test func loadSessionWithMultipleImageUserMessageNoOrphan() {
        let reducer = TimelineReducer()

        let initialTrace: [TraceEvent] = [
            .init(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                  text: "Hello", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                  text: "Hi there", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(initialTrace)

        // User sends message with TWO images
        let userText = "let's improve the experience"
        let attachmentA = ImageAttachment(data: Self.fakeBase64A, mimeType: "image/jpeg")
        let attachmentB = ImageAttachment(data: Self.fakeBase64B, mimeType: "image/png")
        _ = reducer.appendUserMessage(userText, images: [attachmentA, attachmentB])

        // Fresh trace with two data URIs joined by newlines (server's extractText format)
        let traceUserText = "\(userText)\ndata:image/jpeg;base64,\(Self.fakeBase64A)\ndata:image/png;base64,\(Self.fakeBase64B)"
        let freshTrace = initialTrace + [
            .init(id: "e3", type: .user, timestamp: "2025-01-01T00:00:02.000Z",
                  text: traceUserText, tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:03.000Z",
                  text: nil, tool: "bash", args: ["command": .string("ls")],
                  output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:04.000Z",
                  text: nil, tool: nil, args: nil, output: "file.txt",
                  toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
            .init(id: "e4", type: .assistant, timestamp: "2025-01-01T00:00:05.000Z",
                  text: "Done analyzing", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(freshTrace)

        // Count user messages — should be exactly 2 (original "Hello" + the new one)
        let userMessages = reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(userMessages.count == 2, "Should have exactly 2 user messages, not a duplicate")

        // The new user message should be at index 2 (after initial user+assistant)
        guard case .userMessage(_, let text, let images, _) = reducer.items[2] else {
            Issue.record("Expected userMessage at index 2, got \(reducer.items[2])")
            return
        }
        #expect(text == userText, "User message should have clean text without raw base64")
        #expect(!text.contains("base64"), "User message text must not contain raw base64")
        #expect(images.count == 2, "Should have extracted both image attachments")
    }

    @Test func loadSessionTraceUserMessageWithImagesRendersCleanText() {
        let reducer = TimelineReducer()

        // Directly load a trace where the user message has two data URIs
        let userText = "look at these screenshots"
        let traceUserText = "\(userText)\ndata:image/jpeg;base64,\(Self.fakeBase64A)\ndata:image/png;base64,\(Self.fakeBase64B)"

        let trace: [TraceEvent] = [
            .init(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                  text: traceUserText, tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            .init(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                  text: "I see the images", tool: nil, args: nil, output: nil,
                  toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(trace)

        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let text, let images, _) = reducer.items[0] else {
            Issue.record("Expected userMessage at index 0")
            return
        }
        #expect(text == userText, "Should extract clean text without data URIs")
        #expect(!text.contains("data:image"), "Text must not contain data URI prefix")
        #expect(!text.contains("base64"), "Text must not contain base64 data")
        #expect(images.count == 2, "Should extract both images from data URIs")
        #expect(images[0].mimeType == "image/jpeg")
        #expect(images[1].mimeType == "image/png")
    }
}

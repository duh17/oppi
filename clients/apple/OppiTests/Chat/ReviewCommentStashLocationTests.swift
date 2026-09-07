import Foundation
import Testing
@testable import Oppi

@Suite("Review comment stash location")
@MainActor
struct ReviewCommentStashLocationTests {
    @Test("Long shared prefixes keep filename, lines, and distinguishing parent")
    func longSharedPrefixesKeepFilenameLinesAndParent() {
        let chat = comment(
            id: "chat-view",
            path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            startLine: 910,
            endLine: 918
        )
        let review = comment(
            id: "review-view",
            path: "clients/apple/Oppi/Features/Review/ChatView.swift",
            startLine: 40,
            endLine: 48
        )
        let stash = [chat, review]

        let chatCompact = ReviewCommentStashLocation.compactText(for: chat, among: stash)
        let reviewCompact = ReviewCommentStashLocation.compactText(for: review, among: stash)

        #expect(chatCompact == "Chat/ChatView.swift:910-918")
        #expect(reviewCompact == "Review/ChatView.swift:40-48")
        #expect(locationPath(chatCompact) != locationPath(reviewCompact))
        #expect(!chatCompact.hasPrefix("clients/apple"))
        #expect(!reviewCompact.hasPrefix("clients/apple"))
    }

    @Test("Duplicate basenames in different folders stay distinguishable")
    func duplicateBasenamesInDifferentFoldersStayDistinguishable() {
        let ios = comment(
            id: "ios",
            path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            startLine: 12
        )
        let mac = comment(
            id: "mac",
            path: "clients/apple/OppiMac/Views/ChatView.swift",
            startLine: 12
        )
        let stash = [ios, mac]

        let iosCompact = ReviewCommentStashLocation.compactText(for: ios, among: stash)
        let macCompact = ReviewCommentStashLocation.compactText(for: mac, among: stash)

        #expect(iosCompact == "Chat/ChatView.swift:12")
        #expect(macCompact == "Views/ChatView.swift:12")
        #expect(locationPath(iosCompact) != locationPath(macCompact))
    }

    @Test("Same immediate parent expands until distinct paths differ")
    func sameImmediateParentExpandsUntilDistinctPathsDiffer() {
        let app = comment(id: "app-src", path: "a/src/Foo.swift", startLine: 12, endLine: 12)
        let server = comment(id: "server-src", path: "b/src/Foo.swift", startLine: 12, endLine: 12)
        let stash = [app, server]

        let appCompact = ReviewCommentStashLocation.compactText(for: app, among: stash)
        let serverCompact = ReviewCommentStashLocation.compactText(for: server, among: stash)

        #expect(appCompact == "a/src/Foo.swift:12")
        #expect(serverCompact == "b/src/Foo.swift:12")
        #expect(locationPath(appCompact) == "a/src/Foo.swift")
        #expect(locationPath(serverCompact) == "b/src/Foo.swift")
        #expect(locationPath(appCompact) != locationPath(serverCompact))
        #expect(!appCompact.hasPrefix("src/"))
        #expect(!serverCompact.hasPrefix("src/"))
    }

    @Test("Same two parents expand one more ancestor")
    func sameTwoParentsExpandOneMoreAncestor() {
        let chat = comment(
            id: "chat-support",
            path: "clients/apple/Oppi/Features/Chat/Support/Helper.swift",
            startLine: 8
        )
        let review = comment(
            id: "review-support",
            path: "clients/apple/Oppi/Features/Review/Support/Helper.swift",
            startLine: 8
        )
        let stash = [chat, review]

        let chatCompact = ReviewCommentStashLocation.compactText(for: chat, among: stash)
        let reviewCompact = ReviewCommentStashLocation.compactText(for: review, among: stash)

        #expect(chatCompact == "Chat/Support/Helper.swift:8")
        #expect(reviewCompact == "Review/Support/Helper.swift:8")
        #expect(locationPath(chatCompact) != locationPath(reviewCompact))
        #expect(locationPath(chatCompact) != "Support/Helper.swift")
        #expect(locationPath(reviewCompact) != "Support/Helper.swift")
    }

    @Test("Same-file comments share the compact path and keep their own line ranges")
    func sameFileCommentsSharePathAndKeepLineRanges() {
        let first = comment(
            id: "same-file-1",
            path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            startLine: 910,
            endLine: 918
        )
        let second = comment(
            id: "same-file-2",
            path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            startLine: 40,
            endLine: 48
        )
        let stash = [first, second]

        let firstCompact = ReviewCommentStashLocation.compactText(for: first, among: stash)
        let secondCompact = ReviewCommentStashLocation.compactText(for: second, among: stash)

        #expect(locationPath(firstCompact) == locationPath(secondCompact))
        #expect(firstCompact == "ChatView.swift:910-918")
        #expect(secondCompact == "ChatView.swift:40-48")
        #expect(firstCompact != secondCompact)
    }

    @Test("Missing path keeps non-file labels and does not use lastPathComponent")
    func missingPathKeepsNonFileLabels() {
        let labeled = comment(
            id: "labeled",
            path: nil,
            label: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            source: .timelineText
        )
        let urlLabel = comment(
            id: "url",
            path: nil,
            label: "https://example.com/foo/bar.swift",
            source: .toolOutput
        )
        let fallback = comment(id: "fallback", path: nil, label: nil, source: .timelineText)
        let emptyPath = comment(id: "empty", path: "   ", label: "Timeline", source: .timelineText)
        let file = comment(id: "file", path: "a/src/Foo.swift", startLine: 3)
        let stash = [labeled, urlLabel, fallback, emptyPath, file]

        #expect(ReviewCommentStashLocation.compactText(for: labeled, among: stash) == labeled.reference.label)
        #expect(ReviewCommentStashLocation.completeText(for: labeled) == labeled.reference.label)
        #expect(ReviewCommentStashLocation.compactText(for: urlLabel, among: stash) == urlLabel.reference.label)
        #expect(ReviewCommentStashLocation.compactText(for: fallback, among: stash) == "Timeline")
        #expect(ReviewCommentStashLocation.completeText(for: fallback) == "Timeline")
        #expect(ReviewCommentStashLocation.compactText(for: emptyPath, among: stash) == "Timeline")
        #expect(locationPath(ReviewCommentStashLocation.compactText(for: labeled, among: stash)) != "Chat/ChatView.swift")
    }

    @Test("Ordinary short locations stay unique at the filename")
    func ordinaryShortLocationsStayUnchanged() {
        let short = comment(id: "short", path: "App.swift", startLine: 3)
        #expect(ReviewCommentStashLocation.compactText(for: short, among: [short]) == "App.swift:3")
        #expect(ReviewCommentStashLocation.completeText(for: short) == "App.swift:3")
    }

    @Test("Single-line and range suffixes stay on the shared compact path")
    func lineAndRangeSuffixesMatchCompleteLocation() {
        let single = comment(id: "single", path: "Sources/App.swift", startLine: 8, endLine: 8)
        let range = comment(id: "range", path: "Sources/App.swift", startLine: 8, endLine: 14)
        let noLines = comment(id: "none", path: "Sources/App.swift")
        let stash = [single, range, noLines]

        #expect(ReviewCommentStashLocation.compactText(for: single, among: stash) == "App.swift:8")
        #expect(ReviewCommentStashLocation.completeText(for: single) == "Sources/App.swift:8")
        #expect(ReviewCommentStashLocation.compactText(for: range, among: stash) == "App.swift:8-14")
        #expect(ReviewCommentStashLocation.completeText(for: range) == "Sources/App.swift:8-14")
        #expect(ReviewCommentStashLocation.compactText(for: noLines, among: stash) == "App.swift")
        #expect(ReviewCommentStashLocation.completeText(for: noLines) == "Sources/App.swift")
        #expect(locationPath(ReviewCommentStashLocation.compactText(for: single, among: stash))
            == locationPath(ReviewCommentStashLocation.compactText(for: range, among: stash)))
    }

    @Test("Complete location and outgoing review block keep the full reference")
    func completeLocationAndOutgoingReviewBlockKeepFullReference() {
        let originalPath = "clients/apple/Oppi/Features/Chat/ChatView.swift"
        let chat = comment(
            id: "outgoing",
            path: originalPath,
            startLine: 910,
            endLine: 918,
            body: "Name the owner of this fallback before merging."
        )
        let originalReference = chat.reference

        _ = ReviewCommentStashLocation.compactText(for: chat, among: [chat])
        _ = ReviewCommentStashLocation.completeText(for: chat)

        #expect(chat.reference == originalReference)
        #expect(chat.reference.path == originalPath)
        #expect(
            ReviewCommentStashLocation.completeText(for: chat)
                == "clients/apple/Oppi/Features/Chat/ChatView.swift:910-918"
        )

        let block = ReviewCommentStore.reviewBlock(for: [chat])
        #expect(block.contains("**Where:** `clients/apple/Oppi/Features/Chat/ChatView.swift`:910-918 (file)"))
        #expect(!block.contains("**Where:** `Chat/ChatView.swift`"))
        #expect(!block.contains("**Where:** `ChatView.swift`"))
    }
}

private func comment(
    id: String,
    path: String?,
    label: String? = nil,
    source: ReviewCommentReferenceSource = .file,
    startLine: Int? = nil,
    endLine: Int? = nil,
    body: String = "Comment",
    selectedText: String? = nil,
    createdAt: Int64 = 1
) -> ReviewComment {
    ReviewComment(
        id: id,
        workspaceId: "workspace-1",
        sessionId: "session-1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: body,
        attachments: nil,
        reference: ReviewCommentReference(
            source: source,
            label: label,
            path: path,
            side: nil,
            startLine: startLine,
            endLine: endLine,
            selectedText: selectedText,
            languageHint: nil,
            toolCallId: nil,
            timelineItemId: nil,
            url: nil
        ),
        createdAt: createdAt,
        updatedAt: createdAt,
        sentAt: nil
    )
}

private func locationPath(_ text: String) -> String {
    guard let range = text.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) else {
        return text
    }
    return String(text[..<range.lowerBound])
}

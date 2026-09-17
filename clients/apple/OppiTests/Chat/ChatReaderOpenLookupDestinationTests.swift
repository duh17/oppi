import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat reader add-to-chat destination")
@MainActor
struct ChatReaderOpenLookupDestinationTests {
    @Test("open(.image) from a chat-anchored view does not capture a destination")
    func openImageFromChatAnchoredViewCapturesDestination() throws {
        let opened = try openFromChatAnchoredView(.image(try makePNG().0))

        #expect(addToChatSessionId(from: opened) == nil)
    }

    @Test("open(.document) rendered artifacts from a chat-anchored view capture the visible composer destination")
    func openDocumentRenderedArtifactsFromChatAnchoredViewCaptureDestination() throws {
        let contents: [FullScreenCodeContent] = [
            .mermaid(content: "graph TD; A-->B", filePath: "diagram.mmd"),
            .latex(content: "x^2", filePath: "math.tex"),
            .html(content: "<p>hello</p>", filePath: "note.html"),
        ]
        for content in contents {
            let opened = try openFromChatAnchoredView(.document(content: content))
            #expect(addToChatSessionId(from: opened) == nil)
        }
    }

    @Test("open(.imageData) from a chat-anchored view does not capture a destination")
    func openImageDataFromChatAnchoredViewCapturesDestination() throws {
        let png = try makePNG()
        let opened = try openFromChatAnchoredView(
            .imageData(png.1, mimeType: "image/png")
        )

        #expect(addToChatSessionId(from: opened) == nil)
    }

    @Test("environment-open rendered artifacts stamp the origin chat destination")
    func environmentOpenRenderedArtifactsStampOriginChat() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let contents: [FullScreenCodeContent] = [
            .mermaid(content: "graph TD; A-->B", filePath: "diagram.mmd"),
            .latex(content: "x^2", filePath: "math.tex"),
            .html(content: "<p>hello</p>", filePath: "note.html"),
        ]
        for content in contents {
            var opened: ChatReaderPayload?
            let openChatReader = ChatReaderOpenAction { payload in
                opened = ChatView.stampedTimelineReaderPayload(
                    payload,
                    sessionId: "chat-origin",
                    composerDestination: destination
                )
            }
            openChatReader(.document(content: content))
            let stamped = try #require(opened)
            #expect(stamped.destination === destination)

            let store = ChatReaderPayloadStore()
            let target = store.store(stamped)
            let controller = try #require(
                ChatReaderDestinationView(target: target, store: store).debugMakeControllerForTesting()
            )
            #expect(controller.makeAnnotateHostForTesting().destinationSessionIdForTesting == "chat-origin")
        }
        #expect(acceptedCount == 0)
    }

    @Test("timeline stamp uses matching active destination A")
    func timelineStampUsesMatchingActiveDestinationA() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let activeA = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in true }
        let composerA = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in true }
        ComposerCanvasActiveDestination.push(activeA)

        let stamped = ChatView.stampedTimelineReaderPayload(
            .document(content: .html(content: "<p>hello</p>", filePath: "note.html")),
            sessionId: "chat-a",
            composerDestination: composerA
        )
        #expect(stamped.destination === activeA)
        #expect(stamped.destination !== composerA)
    }

    @Test("timeline stamp does not let active destination B replace source A")
    func timelineStampDoesNotLetActiveDestinationBReplaceSourceA() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let composerA = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in true }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "chat-b") { _, _ in true }
        )

        let stamped = ChatView.stampedTimelineReaderPayload(
            .document(content: .html(content: "<p>hello</p>", filePath: "note.html")),
            sessionId: "chat-a",
            composerDestination: composerA
        )
        #expect(stamped.destination === composerA)
        #expect(stamped.destination?.sessionId == "chat-a")
    }

    @Test("timeline stamp overwrites an incoming pre-stamped payload with source A")
    func timelineStampOverwritesIncomingPreStampedPayloadWithSourceA() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let composerA = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in true }
        let other = ComposerCanvasDestination(sessionId: "chat-other") { _, _ in true }
        let incoming = ChatReaderPayload.document(
            content: .html(content: "<p>hello</p>", filePath: "note.html"),
            destination: other
        )

        let stamped = ChatView.stampedTimelineReaderPayload(
            incoming,
            sessionId: "chat-a",
            composerDestination: composerA
        )
        #expect(stamped.destination === composerA)
        #expect(stamped.destination !== other)
    }

    @Test("timeline stamp applies the same destination to every payload kind")
    func timelineStampAppliesTheSameDestinationToEveryPayloadKind() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let composerA = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in true }
        for payload in try payloadsOfEveryKind() {
            let stamped = ChatView.stampedTimelineReaderPayload(
                payload,
                sessionId: "chat-a",
                composerDestination: composerA
            )
            #expect(stamped.destination === composerA)
        }
    }

    @Test("nested reader inherit keeps the parent stamp including nil")
    func nestedReaderInheritsParentStampIncludingNil() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "chat-later") { _, _ in true }
        )

        let origin = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in true }
        let parent = ChatReaderPayload.document(
            content: .markdown(content: "# doc", filePath: "doc.md"),
            destination: origin
        )
        let nested = ChatReaderPayload.document(
            content: .mermaid(content: "graph TD; A-->B", filePath: "diagram.mmd")
        )
        #expect(nested.inheritingDestination(from: parent).destination?.sessionId == "chat-origin")

        let nilParent = ChatReaderPayload.document(
            content: .markdown(content: "# doc", filePath: "doc.md")
        )
        #expect(nested.inheritingDestination(from: nilParent).destination == nil)
    }

    @Test("stamped origin A is not replaced by later live chat B")
    func stampedOriginAIsNotReplacedByLaterLiveChatB() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var originCount = 0
        var laterCount = 0
        let origin = ComposerCanvasDestination(sessionId: "chat-a") { _, _ in
            originCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "chat-b") { _, _ in
                laterCount += 1
                return true
            }
        )

        let store = ChatReaderPayloadStore()
        let target = store.store(
            ChatView.stampedTimelineReaderPayload(
                .document(content: .html(content: "<p>hello</p>", filePath: "note.html")),
                sessionId: "chat-a",
                composerDestination: origin
            )
        )
        let controller = try #require(
            ChatReaderDestinationView(target: target, store: store).debugMakeControllerForTesting()
        )
        let host = controller.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "chat-a")

        let png = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: png.1,
                image: png.0
            ),
            recognizedText: "note"
        )
        #expect(outcome == .accepted)
        #expect(originCount == 1)
        #expect(laterCount == 0)
        #expect(host.didDismissForTesting)
    }

    @Test("captured-nil document reader stays fail-closed against a live chat")
    func capturedNilDocumentReaderStaysFailClosedAgainstLiveChat() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "chat-later") { _, _ in true }
        )

        let store = ChatReaderPayloadStore()
        let target = store.store(
            ChatReaderPayload.document(
                content: .html(content: "<p>hello</p>", filePath: "note.html")
            )
        )
        let controller = try #require(
            ChatReaderDestinationView(target: target, store: store).debugMakeControllerForTesting()
        )
        let host = controller.makeAnnotateHostForTesting()
        let png = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: png.1,
                image: png.0
            ),
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.destinationSessionIdForTesting == nil)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
    }

    @Test("lookup does not capture a live chat destination onto the payload")
    func lookupDoesNotCaptureLiveChatDestination() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "live-chat") { _, _ in true }
        )

        let presenter = UIViewController()
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        var opened: ChatReaderPayload?
        ChatReaderOpenLookup.install({ opened = $0 }, on: presenter.view)

        #expect(ChatReaderOpenLookup.open(
            .document(content: .mermaid(content: "graph TD; A-->B", filePath: "diagram.mmd")),
            from: sourceView
        ))
        #expect(addToChatSessionId(from: try #require(opened)) == nil)

        #expect(ChatReaderOpenLookup.open(.image(try makePNG().0), from: sourceView))
        #expect(addToChatSessionId(from: try #require(opened)) == nil)
    }

    @Test("tool row openFullScreen(.image) includes the visible chat destination")
    func toolRowOpenFullScreenImageIncludesVisibleChatDestination() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "timeline-chat") { _, _ in
            acceptedCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(destination)

        let harness = makeHostHarness()
        defer { harness.window.isHidden = true }
        harness.host.composerCanvasDestination = destination

        let image = try makePNG().0
        var opened: ChatReaderPayload?
        var configuration = makeTimelineToolConfiguration(
            collapsedImageBase64: image.pngData()?.base64EncodedString(),
            collapsedImageMimeType: "image/png",
            isExpanded: false
        )
        configuration.openFullScreen = { opened = $0 }
        let view = ToolTimelineRowContentView(configuration: configuration)
        harness.host.view.addSubview(view)
        view.frame = harness.host.view.bounds
        harness.host.view.layoutIfNeeded()

        #expect(view.presentCollapsedImagePreviewIfAvailable())
        let payload = try #require(opened)
        #expect(addToChatSessionId(from: payload) == nil)
        let stamped = ChatView.stampedTimelineReaderPayload(
            payload,
            sessionId: "timeline-chat",
            composerDestination: destination
        )
        #expect(stamped.destination === destination)
        #expect(acceptedCount == 0)
        #expect(harness.host.presentedViewController == nil)
    }

    @Test("annotate host from a lookup image payload accepts Add to Chat")
    func annotateHostFromLookupImagePayloadAcceptsAddToChat() throws {
        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let opened = try openFromChatAnchoredView(.image(try makePNG().0))
        guard case .image(let image) = opened.kind else {
            Issue.record("Expected image reader payload")
            return
        }
        #expect(opened.destination == nil)
        let stamped = ChatView.stampedTimelineReaderPayload(
            opened,
            sessionId: "chat-origin",
            composerDestination: destination
        )
        #expect(stamped.destination === destination)

        let embeddedNavigation = EmbeddedImageViewerView(
            image: image,
            addToChatDestination: stamped.destination
        ).debugMakeControllerForTesting()
        let embeddedViewer = try #require(
            (embeddedNavigation as? UINavigationController)?
                .viewControllers.first as? FullScreenImageViewController
        )
        try expectAddToChatAccepted(on: embeddedViewer.makeAnnotateHostForTesting())

        let sheetViewer = FullScreenImageViewController(
            image: image,
            addToChatDestination: stamped.destination
        )
        try expectAddToChatAccepted(on: sheetViewer.makeAnnotateHostForTesting())
        #expect(acceptedCount == 2)
    }

    @Test("off-chat lookup image still fail-closed and keeps the canvas open")
    func offChatLookupImageStillFailClosedAndKeepsCanvasOpen() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let presenter = UIViewController()
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        var opened: ChatReaderPayload?
        ChatReaderOpenLookup.install({ opened = $0 }, on: presenter.view)

        #expect(ChatReaderOpenLookup.open(.image(try makePNG().0), from: sourceView))
        let payload = try #require(opened)
        #expect(addToChatSessionId(from: payload) == nil)

        guard case .image(let image) = payload.kind else {
            Issue.record("Expected image reader payload")
            return
        }
        let host = FullScreenImageViewController(
            image: image,
            addToChatDestination: payload.destination
        ).makeAnnotateHostForTesting()
        let png = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: png.1,
                image: png.0
            ),
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
    }

    private func openFromChatAnchoredView(
        _ payload: ChatReaderPayload,
        accept: @escaping (PendingAttachment, String) -> Bool = { _, _ in true }
    ) throws -> ChatReaderPayload {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let destination = ComposerCanvasDestination(sessionId: "chat-origin", accept: accept)
        let presenter = UIViewController()
        presenter.composerCanvasDestination = destination
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        var opened: ChatReaderPayload?
        ChatReaderOpenLookup.install({ opened = $0 }, on: presenter.view)
        #expect(ChatReaderOpenLookup.open(payload, from: sourceView))
        return try #require(opened)
    }

    private func expectAddToChatAccepted(on host: PaperMarkupCanvasHostController) throws {
        #expect(host.destinationSessionIdForTesting == "chat-origin")
        let png = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: png.1,
                image: png.0
            ),
            recognizedText: "note"
        )
        #expect(outcome == .accepted)
        #expect(host.didDismissForTesting)
    }

    private func addToChatSessionId(from payload: ChatReaderPayload) -> String? {
        payload.destination?.sessionId
    }

    private func payloadsOfEveryKind() throws -> [ChatReaderPayload] {
        let png = try makePNG()
        let payloads: [ChatReaderPayload] = [
            .document(content: .mermaid(content: "graph TD; A-->B", filePath: "diagram.mmd")),
            .image(png.0),
            .imageData(png.1, mimeType: "image/png"),
            .audioLyrics(
                AudioLyricsReaderContent(
                    title: "Track",
                    lyrics: nil,
                    itemID: "item",
                    audioPlayer: nil,
                    play: { _ in },
                    openFile: nil,
                    autoplayOnAppear: false
                )
            ),
            .video(
                ChatReaderVideoContent(
                    source: AuthenticatedMediaSource(
                        url: try #require(URL(string: "https://example.com/video.mp4")),
                        authorizationHeaderValue: "Bearer test",
                        tlsCertFingerprint: nil,
                        contentTypeHint: "video/mp4",
                        sourceFileExtension: "mp4"
                    )
                )
            ),
            .nowPlaying(AudioPlayerService()),
            .extensionNative(
                ExtensionNativeReaderContent(
                    surface: ExtensionUINativeSurface(
                        version: 1,
                        id: "surface",
                        source: "widget",
                        presentation: ExtensionUINativePresentation(
                            style: "surfacePanel",
                            title: "Title",
                            subtitle: nil
                        ),
                        blocks: [],
                        fallback: ExtensionUINativeFallback(text: "fallback", lines: nil)
                    ),
                    identifierSuffix: "suffix",
                    title: "Title",
                    subtitle: nil,
                    statusText: nil
                )
            ),
        ]
        for payload in payloads {
            switch payload.kind {
            case .document, .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
                break
            }
        }
        return payloads
    }

    private func makePNG() throws -> (UIImage, Data) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = try #require(image.pngData())
        return (image, data)
    }

    private struct HostHarness {
        let window: UIWindow
        let host: UIViewController
    }

    private func makeHostHarness() -> HostHarness {
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        return HostHarness(window: window, host: host)
    }
}

import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat reader image add-to-chat destination")
@MainActor
struct ChatReaderOpenLookupDestinationTests {
    @Test("open(.image) from a chat-anchored view captures the visible composer destination")
    func openImageFromChatAnchoredViewCapturesDestination() throws {
        let opened = try openFromChatAnchoredView(.image(try makePNG().0))

        #expect(addToChatSessionId(from: opened) == "chat-origin")
    }

    @Test("open(.imageData) from a chat-anchored view captures the visible composer destination")
    func openImageDataFromChatAnchoredViewCapturesDestination() throws {
        let png = try makePNG()
        let opened = try openFromChatAnchoredView(
            .imageData(png.1, mimeType: "image/png")
        )

        #expect(addToChatSessionId(from: opened) == "chat-origin")
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
        #expect(addToChatSessionId(from: payload) == "timeline-chat")
        #expect(acceptedCount == 0)
        #expect(harness.host.presentedViewController == nil)
    }

    @Test("annotate host from a lookup image payload accepts Add to Chat")
    func annotateHostFromLookupImagePayloadAcceptsAddToChat() throws {
        var acceptedCount = 0
        let opened = try openFromChatAnchoredView(.image(try makePNG().0)) { _, _ in
            acceptedCount += 1
            return true
        }
        guard case .image(let image, let destination) = opened else {
            Issue.record("Expected image reader payload")
            return
        }
        #expect(destination?.sessionId == "chat-origin")

        let embeddedNavigation = EmbeddedImageViewerView(
            image: image,
            addToChatDestination: destination
        ).debugMakeControllerForTesting()
        let embeddedViewer = try #require(
            (embeddedNavigation as? UINavigationController)?
                .viewControllers.first as? FullScreenImageViewController
        )
        try expectAddToChatAccepted(on: embeddedViewer.makeAnnotateHostForTesting())

        let sheetViewer = FullScreenImageViewController(
            image: image,
            addToChatDestination: destination
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

        guard case .image(let image, let destination) = payload else {
            Issue.record("Expected image reader payload")
            return
        }
        let host = FullScreenImageViewController(
            image: image,
            addToChatDestination: destination
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
        switch payload {
        case .image(_, let destination), .imageData(_, _, let destination):
            return destination?.sessionId
        case .document, .audioLyrics, .video, .nowPlaying, .extensionNative:
            return nil
        }
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

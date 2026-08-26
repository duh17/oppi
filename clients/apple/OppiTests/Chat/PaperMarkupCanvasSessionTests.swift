import PaperKit
import Testing
import UIKit
@testable import Oppi

@Suite("PaperMarkupCanvasSession")
@MainActor
struct PaperMarkupCanvasSessionTests {
    @Test("+ menu exposes Canvas with the existing attach sources")
    func plusMenuExposesCanvasWithExistingAttachSources() {
        let titles = PaperMarkupCanvasSession.attachmentMenuItems.map(\.title)

        #expect(titles == ["Photo Library", "Camera", "Choose File", "Canvas"])
        #expect(PaperMarkupCanvasSession.attachmentMenuItems.contains(.canvas))
    }

    @Test("Add to Chat yields a PNG pending image and prepends recognized text")
    func addToChatYieldsPNGPendingImageAndPrependsRecognizedText() throws {
        let (image, pngData) = try makePNG()
        var composerText = "existing prompt"
        var pendingAttachments: [PendingAttachment] = []

        PaperMarkupCanvasSession.applyAddToChat(
            pngData: pngData,
            image: image,
            recognizedText: "login box",
            composerText: &composerText,
            pendingAttachments: &pendingAttachments
        )

        let attachment = try #require(pendingAttachments.first)
        let encoded = try #require(attachment.imageAttachment)
        let decoded = try #require(Data(base64Encoded: encoded.data, options: .ignoreUnknownCharacters))

        #expect(pendingAttachments.count == 1)
        #expect(attachment.source == .image)
        #expect(encoded.mimeType == "image/png")
        #expect(decoded.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(composerText.hasPrefix("login box"))
        #expect(composerText.contains("existing prompt"))
    }

    @Test("Add to Chat prefers indexable content and uses handwriting when that string is empty")
    func addToChatPrefersIndexableContentThenHandwritingFallback() {
        #expect(
            PaperMarkupCanvasSession.resolvedRecognizedText(
                indexableContent: "typed label",
                handwritingFallback: "ink words"
            ) == "typed label"
        )
        #expect(
            PaperMarkupCanvasSession.resolvedRecognizedText(
                indexableContent: "   ",
                handwritingFallback: "ink words"
            ) == "ink words"
        )
        #expect(
            PaperMarkupCanvasSession.resolvedRecognizedText(
                indexableContent: nil,
                handwritingFallback: nil
            ).isEmpty
        )
    }

    @Test("Add to Chat leaves composer text unchanged when recognized text is empty")
    func addToChatLeavesComposerTextUnchangedWhenRecognizedTextIsEmpty() throws {
        let (image, pngData) = try makePNG()
        var composerText = "keep me"
        var pendingAttachments: [PendingAttachment] = []

        PaperMarkupCanvasSession.applyAddToChat(
            pngData: pngData,
            image: image,
            recognizedText: "  \n",
            composerText: &composerText,
            pendingAttachments: &pendingAttachments
        )

        #expect(pendingAttachments.count == 1)
        #expect(composerText == "keep me")
    }

    @Test("empty cancel dismisses immediately")
    func emptyCancelDismissesImmediately() {
        #expect(PaperMarkupCanvasSession.cancelDisposition(isDirty: false) == .dismiss)
        #expect(
            PaperMarkupCanvasHostController(background: .blank).cancelDisposition == .dismiss
        )
    }

    @Test("dirty cancel asks before discarding")
    func dirtyCancelAsksBeforeDiscarding() {
        #expect(PaperMarkupCanvasSession.cancelDisposition(isDirty: true) == .confirmDiscard)

        let host = PaperMarkupCanvasHostController(background: .blank)
        host.markChangedForTesting()
        #expect(host.cancelDisposition == .confirmDiscard)
        #expect(PaperMarkupCanvasSession.DiscardPrompt.title == "Discard Canvas?")
        #expect(PaperMarkupCanvasSession.DiscardPrompt.discardAction == "Discard")
        #expect(PaperMarkupCanvasSession.DiscardPrompt.keepAction == "Keep Editing")
    }

    @Test("markup host presents full screen and never writes the source image back")
    func markupHostPresentsFullScreenAndNeverWritesSourceImageBack() throws {
        let original = try makePNG().0
        let copied = PaperMarkupCanvasSession.copiedImage(from: original)
        let controller = PaperMarkupCanvasHostController.makeFullScreenController(
            background: .image(copied)
        )

        #expect(controller.modalPresentationStyle == .fullScreen)
        #expect(copied !== original)
        #expect(PaperMarkupCanvasSession.writesBackToSourceFile == false)
        #expect(PaperMarkupCanvasSession.annotateSource(for: .rasterImage) == .currentImage)
        #expect(PaperMarkupCanvasSession.annotateSource(for: .svg) == .renderedSnapshot)
        #expect(PaperMarkupCanvasSession.annotateSource(for: .html) == .renderedSnapshot)
    }

    @Test("fullscreen image viewer exposes Annotate next to Share and Save")
    func fullscreenImageViewerExposesAnnotateNextToShareAndSave() throws {
        let viewController = FullScreenImageViewController(image: try makePNG().0)
        viewController.loadViewIfNeeded()

        let toolbar = try #require(firstSubview(ofType: UIToolbar.self, in: viewController.view))
        let identifiers = (toolbar.items ?? []).compactMap(\.accessibilityIdentifier)

        #expect(identifiers.contains(PaperMarkupCanvasSession.AnnotateAction.imageViewerIdentifier))
        #expect(
            (toolbar.items ?? []).contains { $0.accessibilityLabel == "Annotate" }
        )
    }

    @Test("image annotate opens the shared markup host with a copy of the current image")
    func imageAnnotateOpensSharedMarkupHostWithCopiedImage() throws {
        let original = try makePNG().0
        let viewController = FullScreenImageViewController(image: original)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        viewController.loadViewIfNeeded()

        viewController.debugAnnotateForTesting()

        let presented = viewController.presentedViewController
        let host = presented as? PaperMarkupCanvasHostController
            ?? (presented as? UINavigationController)?
            .viewControllers.first as? PaperMarkupCanvasHostController
        let unwrapped = try #require(host)

        #expect(unwrapped.modalPresentationStyle == .fullScreen || presented?.modalPresentationStyle == .fullScreen)
        #expect(unwrapped.usesCopiedBackgroundImage)
        #expect(unwrapped.backgroundImageForTesting !== original)
    }

    @Test("SVG viewer exposes Annotate and snapshots the rendered view")
    func svgViewerExposesAnnotateAndSnapshotsTheRenderedView() throws {
        let controller = FullScreenImageDataPreviewViewController(
            data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>".utf8),
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        let annotate = try #require(
            controller.navigationItem.rightBarButtonItems?.first {
                $0.accessibilityIdentifier == PaperMarkupCanvasSession.AnnotateAction.dataViewerIdentifier
            }
        )
        #expect(annotate.accessibilityLabel == "Annotate")
        #expect(controller.annotateSourceForTesting == PaperMarkupCanvasSession.AnnotateSource.renderedSnapshot)
    }

    @Test("HTML viewer exposes Annotate and snapshots the rendered view")
    func htmlViewerExposesAnnotateAndSnapshotsTheRenderedView() throws {
        let controller = FullScreenCodeViewController(
            content: .html(content: "<p>hello</p>", filePath: "note.html")
        )
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        let navigation = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigation.topViewController)
        let annotate = contentController.navigationItem.rightBarButtonItems?.first {
            $0.accessibilityIdentifier == PaperMarkupCanvasSession.AnnotateAction.htmlViewerIdentifier
        }

        #expect(annotate?.accessibilityLabel == "Annotate")
        #expect(controller.installedBodyViewForTesting is HTMLRenderView)
        #expect(controller.annotateSourceForTesting == PaperMarkupCanvasSession.AnnotateSource.renderedSnapshot)
    }

    @Test("Add to Chat delivers only to the origin destination")
    func addToChatDeliversOnlyToOriginDestination() throws {
        let (image, pngData) = try makePNG()
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(pngData: pngData, image: image)

        var originCount = 0
        var otherCount = 0
        let origin = ComposerCanvasDestination(sessionId: "session-origin") { received, _ in
            originCount += 1
            #expect(received.id == attachment.id)
            return true
        }
        let other = ComposerCanvasDestination(sessionId: "session-other") { _, _ in
            otherCount += 1
            return true
        }

        let host = PaperMarkupCanvasHostController(
            background: .blank,
            destination: origin
        )
        let outcome = host.completeAddToChatForTesting(
            attachment: attachment,
            recognizedText: "login box"
        )

        #expect(other.sessionId == "session-other")
        #expect(outcome == .accepted)
        #expect(originCount == 1)
        #expect(otherCount == 0)
        #expect(host.didDismissForTesting)
        #expect(host.destinationSessionIdForTesting == "session-origin")
        #expect(host.lastFailureMessageForTesting == nil)
    }

    @Test("Add to Chat without a destination keeps the canvas and shows a failure")
    func addToChatWithoutDestinationKeepsCanvasAndShowsFailure() throws {
        let (image, pngData) = try makePNG()
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(pngData: pngData, image: image)
        let host = PaperMarkupCanvasHostController(background: .blank)

        let outcome = host.completeAddToChatForTesting(
            attachment: attachment,
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
        #expect(host.isShowingExportProgressForTesting == false)
    }

    @Test("Add to Chat stays open when the destination rejects the attachment")
    func addToChatStaysOpenWhenDestinationRejects() throws {
        let (image, pngData) = try makePNG()
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(pngData: pngData, image: image)
        let destination = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in false }
        let host = PaperMarkupCanvasHostController(
            background: .blank,
            destination: destination
        )

        let outcome = host.completeAddToChatForTesting(
            attachment: attachment,
            recognizedText: "note"
        )

        #expect(outcome == .rejected)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.destinationRejectedMessage)
    }

    @Test("image annotate carries an origin-owned destination into the markup host")
    func imageAnnotateCarriesOriginOwnedDestination() throws {
        let original = try makePNG().0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in true }
        let viewController = FullScreenImageViewController(
            image: original,
            addToChatDestination: destination
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        viewController.loadViewIfNeeded()

        viewController.debugAnnotateForTesting()

        let presented = viewController.presentedViewController
        let host = presented as? PaperMarkupCanvasHostController
            ?? (presented as? UINavigationController)?
            .viewControllers.first as? PaperMarkupCanvasHostController
        let unwrapped = try #require(host)

        #expect(unwrapped.destinationSessionIdForTesting == "chat-origin")
        #expect(unwrapped.backgroundImageForTesting !== original)
    }

    @Test("raster export uses native pixels and caps the long edge")
    func rasterExportUsesNativePixelsAndCapsLongEdge() {
        let photo = PaperMarkupCanvasSession.exportPixelSize(
            imagePixelSize: CGSize(width: 4_032, height: 3_024),
            markupSize: CGSize(width: 4_032, height: 3_024),
            screenScale: 3
        )
        let blank = PaperMarkupCanvasSession.exportPixelSize(
            imagePixelSize: nil,
            markupSize: CGSize(width: 2_400, height: 1_600),
            screenScale: 3
        )
        let small = PaperMarkupCanvasSession.exportPixelSize(
            imagePixelSize: CGSize(width: 800, height: 600),
            markupSize: CGSize(width: 800, height: 600),
            screenScale: 3
        )

        #expect(photo == CGSize(width: 2_000, height: 1_500))
        #expect(photo != CGSize(width: 12_096, height: 9_072))
        #expect(max(photo.width, photo.height) == PendingImage.autoResizeMaxDimension)
        #expect(blank == CGSize(width: 2_000, height: 1_333))
        #expect(small == CGSize(width: 800, height: 600))
    }

    @Test("copied raster is bounded once and the host does not copy it again")
    func copiedRasterIsBoundedOnceAndHostDoesNotCopyAgain() throws {
        let original = makeImage(width: 2_400, height: 1_600)
        let copied = PaperMarkupCanvasSession.copiedImage(from: original)
        let host = PaperMarkupCanvasHostController(background: .image(copied))
        let pixels = try #require(copied.cgImage)

        #expect(copied !== original)
        #expect(pixels.width == 2_000)
        #expect(pixels.height == 1_333)
        #expect(host.backgroundImageForTesting === copied)
    }

    @Test("snapshot failures preserve the WebKit error")
    func snapshotFailuresPreserveWebKitError() {
        let webKitError = NSError(
            domain: "WKErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "snapshot failed"]
        )

        let failure = PaperMarkupCanvasSession.renderedSnapshot(image: nil, error: webKitError)
        let success = PaperMarkupCanvasSession.renderedSnapshot(image: UIImage(), error: webKitError)

        guard case .failure(let error) = failure else {
            Issue.record("expected snapshot failure to keep the WebKit error")
            return
        }
        #expect((error as NSError).domain == "WKErrorDomain")
        #expect((error as NSError).localizedDescription == "snapshot failed")
        guard case .success = success else {
            Issue.record("expected a rendered image to succeed")
            return
        }
    }

    @Test("SVG annotate stays disabled until the rendered view is ready")
    func svgAnnotateStaysDisabledUntilRenderedViewIsReady() throws {
        let controller = FullScreenImageDataPreviewViewController(
            data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>".utf8),
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        let annotate = try #require(
            controller.navigationItem.rightBarButtonItems?.first {
                $0.accessibilityIdentifier == PaperMarkupCanvasSession.AnnotateAction.dataViewerIdentifier
            }
        )
        #expect(annotate.isEnabled == false)

        controller.markRenderReadyForTesting()
        #expect(annotate.isEnabled == true)
        #expect(controller.isShowingSnapshotProgressForTesting == false)
    }

    @Test("HTML annotate stays disabled until the rendered view is ready")
    func htmlAnnotateStaysDisabledUntilRenderedViewIsReady() throws {
        let controller = FullScreenCodeViewController(
            content: .html(content: "<p>hello</p>", filePath: "note.html")
        )
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        let navigation = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigation.topViewController)
        let annotate = try #require(
            contentController.navigationItem.rightBarButtonItems?.first {
                $0.accessibilityIdentifier == PaperMarkupCanvasSession.AnnotateAction.htmlViewerIdentifier
            }
        )
        #expect(annotate.isEnabled == false)

        controller.markRenderReadyForTesting()
        #expect(annotate.isEnabled == true)
        #expect(controller.isShowingSnapshotProgressForTesting == false)
    }

    @Test("ask or review mode rejects Add to Chat and keeps the canvas")
    func askOrReviewModeRejectsAddToChatAndKeepsCanvas() throws {
        for mode: ChatComposerDraftController.Mode in [.ask, .reviewComment] {
            let (image, pngData) = try makePNG()
            let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            )

            let destinationDraft = ChatComposerDraftController(initialText: "keep me")
            destinationDraft.setMode(mode)
            var destinationPending: [PendingAttachment] = []
            let destination = ComposerCanvasDestination(sessionId: "session-origin") { received, recognized in
                ChatView.deliverCanvasToComposer(
                    attachment: received,
                    recognizedText: recognized,
                    draftController: destinationDraft,
                    pendingAttachments: &destinationPending
                )
            }
            let destinationHost = PaperMarkupCanvasHostController(
                background: .blank,
                destination: destination
            )
            let destinationOutcome = destinationHost.completeAddToChatForTesting(
                attachment: attachment,
                recognizedText: "note"
            )

            #expect(destinationOutcome == .rejected)
            #expect(destinationHost.didDismissForTesting == false)
            #expect(
                destinationHost.lastFailureMessageForTesting
                    == PaperMarkupCanvasSession.AddToChatFailure.destinationRejectedMessage
            )
            #expect(destinationPending.isEmpty)
            #expect(destinationDraft.pendingAttachments.isEmpty)
            #expect(destinationDraft.text != "note")
            destinationDraft.setMode(.message)
            #expect(destinationDraft.text == "keep me")

            let callbackDraft = ChatComposerDraftController(initialText: "keep me")
            callbackDraft.setMode(mode)
            var callbackPending: [PendingAttachment] = []
            let callbackHost = PaperMarkupCanvasHostController(
                background: .blank,
                onAddToChat: { received, recognized in
                    ChatView.deliverCanvasToComposer(
                        attachment: received,
                        recognizedText: recognized,
                        draftController: callbackDraft,
                        pendingAttachments: &callbackPending
                    )
                }
            )
            let callbackOutcome = callbackHost.completeAddToChatForTesting(
                attachment: attachment,
                recognizedText: "note"
            )

            #expect(callbackOutcome == .rejected)
            #expect(callbackHost.didDismissForTesting == false)
            #expect(
                callbackHost.lastFailureMessageForTesting
                    == PaperMarkupCanvasSession.AddToChatFailure.destinationRejectedMessage
            )
            #expect(callbackPending.isEmpty)
            #expect(callbackDraft.pendingAttachments.isEmpty)
            #expect(callbackDraft.text != "note")
            callbackDraft.setMode(.message)
            #expect(callbackDraft.text == "keep me")
        }
    }

    @Test("cancel during export does not deliver")
    func cancelDuringExportDoesNotDeliver() async {
        var delivered = 0
        let destination = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in
            delivered += 1
            return true
        }
        let host = PaperMarkupCanvasHostController(
            background: .blank,
            destination: destination
        )
        host.loadViewIfNeeded()

        await host.debugAddToChatAndWaitUntilExportHeldForTesting()
        host.debugCancelForTesting()
        await host.debugFinishHeldExportForTesting()

        #expect(delivered == 0)
        #expect(host.didDismissForTesting)
        #expect(host.isShowingExportProgressForTesting == false)
    }

    @Test("present(image:from: chat presenter) Add to Chat accepts")
    func presentFromChatPresenterAddToChatAccepts() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let presenter = UIViewController()
        presenter.composerCanvasDestination = destination

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        FullScreenImageViewController.present(image: try makePNG().0, from: presenter)

        // Later rediscovery from the sheet must not be required.
        presenter.composerCanvasDestination = nil

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "chat-origin")

        let (image, pngData) = try makePNG()
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: pngData,
            image: image
        )
        let outcome = host.completeAddToChatForTesting(
            attachment: attachment,
            recognizedText: "note"
        )

        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
        #expect(host.didDismissForTesting)
        #expect(viewer.didDismissAfterCanvasDeliveryForTesting)
    }

    @Test("missing destination still fail-closed off-chat")
    func missingDestinationStillFailClosedOffChat() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        FullScreenImageViewController.present(image: try makePNG().0, from: presenter)

        // A destination that appears after presentation must not be rediscovered.
        presenter.composerCanvasDestination = ComposerCanvasDestination(sessionId: "late-chat") { _, _ in
            true
        }

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        let host = viewer.makeAnnotateHostForTesting()
        let (image, pngData) = try makePNG()
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: pngData,
            image: image
        )
        let outcome = host.completeAddToChatForTesting(
            attachment: attachment,
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
        #expect(viewer.didDismissAfterCanvasDeliveryForTesting == false)
    }

    @Test("SVG present captures origin destination and refuses later rediscovery")
    func svgPresentCapturesOriginAndRefusesLaterRediscovery() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let presenter = UIViewController()
        presenter.composerCanvasDestination = destination

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        FullScreenImageDataPreviewPresenter.present(
            data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>".utf8),
            mimeType: "image/svg+xml",
            title: "Preview",
            from: presenter
        )

        presenter.composerCanvasDestination = nil

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageDataPreviewViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "chat-origin")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
        #expect(host.didDismissForTesting)
    }

    @Test("SVG missing destination still fail-closed off-chat")
    func svgMissingDestinationStillFailClosedOffChat() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        FullScreenImageDataPreviewPresenter.present(
            data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>".utf8),
            mimeType: "image/svg+xml",
            title: "Preview",
            from: presenter
        )

        presenter.composerCanvasDestination = ComposerCanvasDestination(sessionId: "late-chat") { _, _ in
            true
        }

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageDataPreviewViewController)
        let host = viewer.makeAnnotateHostForTesting()
        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
    }

    @Test("HTML present captures origin destination and refuses later rediscovery")
    func htmlPresentCapturesOriginAndRefusesLaterRediscovery() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }
        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "chat-origin") { _, _ in
            acceptedCount += 1
            return true
        }
        let presenter = UIViewController()
        presenter.composerCanvasDestination = destination
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            .html(content: "<p>hello</p>", filePath: "note.html"),
            from: sourceView
        )

        presenter.composerCanvasDestination = nil

        let viewer = try #require(presenter.presentedViewController as? FullScreenCodeViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "chat-origin")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
        #expect(host.didDismissForTesting)
    }

    @Test("HTML annotate does not steal a live chat destination")
    func htmlAnnotateDoesNotStealLiveChatDestination() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let controller = FullScreenCodeViewController(
            content: .html(content: "<p>hello</p>", filePath: "note.html")
        )
        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "other-chat") { _, _ in true }
        )

        let host = controller.makeAnnotateHostForTesting()
        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .missingDestination)
        #expect(host.didDismissForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
    }

    @Test("pending composer annotate uses full image bytes not the strip thumbnail")
    func pendingComposerAnnotateUsesFullImageBytesNotStripThumbnail() throws {
        let full = try makePNG()
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let pending = PendingAttachment(
            id: "pending-full",
            source: .image,
            displayName: "Image",
            thumbnail: thumb,
            imageAttachment: ImageAttachment(
                data: full.1.base64EncodedString(),
                mimeType: "image/png"
            ),
            localFileData: nil,
            localMimeType: nil
        )

        let image = try #require(ComposerShared.image(forPendingAttachment: pending))
        #expect(image.size.width == 8)
        #expect(image.size.height == 8)
        #expect(image.size != thumb.size)
    }

    @Test("annotating a pending composer photo replaces that attachment")
    func annotatingPendingComposerPhotoReplacesThatAttachment() throws {
        let original = try makePNG()
        let replacement = try makePNG()
        let existing = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: original.1,
            image: original.0
        )
        let next = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: replacement.1,
            image: replacement.0
        )
        let pending = ComposerShared.replacedPendingAttachments(
            [existing],
            with: next,
            replacingAttachmentID: existing.id
        )

        #expect(pending.count == 1)
        #expect(pending.first?.id == next.id)
    }

    @Test("visible chat destination updates from session A to B and survives cover")
    func visibleChatDestinationUpdatesFromAToBAndClearsOnDisappear() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let anchor = ComposerCanvasDestinationAnchorController()
        host.addChild(anchor)
        host.view.addSubview(anchor.view)
        anchor.didMove(toParent: host)
        anchor.viewDidAppear(false)

        let first = ComposerCanvasDestination(sessionId: "session-a") { _, _ in true }
        let second = ComposerCanvasDestination(sessionId: "session-b") { _, _ in true }
        anchor.destination = first
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-a")

        anchor.destination = second
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-b")

        // Covering the chat (wiki-link push) must not drop Add to Chat.
        anchor.viewDidDisappear(false)
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-b")
    }

    @Test("visible chat destination pops only when the chat is removed")
    func visibleChatDestinationPopsOnlyWhenChatIsRemoved() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let anchor = ComposerCanvasDestinationAnchorController()
        host.addChild(anchor)
        host.view.addSubview(anchor.view)
        anchor.didMove(toParent: host)
        anchor.viewDidAppear(false)
        anchor.destination = ComposerCanvasDestination(sessionId: "session-a") { _, _ in true }
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-a")

        anchor.viewDidDisappear(false)
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-a")

        anchor.willMove(toParent: nil)
        anchor.view.removeFromSuperview()
        anchor.removeFromParent()
        #expect(ComposerCanvasActiveDestination.current == nil)
    }

    @Test("visible chat destination pops while still in the window")
    func visibleChatDestinationPopsWhileStillInTheWindow() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let anchor = ComposerCanvasDestinationAnchorController()
        host.addChild(anchor)
        host.view.addSubview(anchor.view)
        anchor.didMove(toParent: host)
        anchor.viewDidAppear(false)
        anchor.destination = ComposerCanvasDestination(sessionId: "session-a") { _, _ in true }
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-a")

        anchor.willMove(toParent: nil)
        anchor.removeFromParent()
        #expect(anchor.view.window != nil)
        #expect(ComposerCanvasActiveDestination.current == nil)
    }

    @Test("visible chat destination keeps one owner when the same session rebuilds")
    func visibleChatDestinationKeepsOneOwnerWhenTheSameSessionRebuilds() {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let anchor = ComposerCanvasDestinationAnchorController()
        host.addChild(anchor)
        host.view.addSubview(anchor.view)
        anchor.didMove(toParent: host)
        anchor.viewDidAppear(false)

        var firstCount = 0
        var secondCount = 0
        let first = ComposerCanvasDestination(sessionId: "session-a") { _, _ in
            firstCount += 1
            return true
        }
        anchor.destination = first
        let owned = ComposerCanvasActiveDestination.current

        let second = ComposerCanvasDestination(sessionId: "session-a") { _, _ in
            secondCount += 1
            return true
        }
        anchor.destination = second

        #expect(ComposerCanvasActiveDestination.current === owned)
        #expect(ComposerCanvasActiveDestination.current?.sessionId == "session-a")

        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            image: makeImage(width: 8, height: 8)
        )
        let outcome = ComposerCanvasDelivery.deliver(
            attachment: attachment,
            recognizedText: "note",
            to: ComposerCanvasActiveDestination.current
        )

        #expect(outcome == .accepted)
        #expect(firstCount == 0)
        #expect(secondCount == 1)
    }

    @Test("timeline attachment presentFullScreenImage uses the visible chat destination")
    func timelineAttachmentPresentFullScreenImageUsesVisibleChatDestination() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "timeline-chat") { _, _ in
            acceptedCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(destination)

        let presenter = UIViewController()
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        ToolTimelineRowPresentationHelpers.presentFullScreenImage(try makePNG().0, from: sourceView)

        let navigation = try #require(presenter.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "timeline-chat")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
    }

    @Test("diagram present uses the visible chat destination and refuses later rediscovery")
    func diagramPresentUsesVisibleChatDestinationAndRefusesLaterRediscovery() throws {
        ComposerCanvasActiveDestination.resetForTesting()
        defer { ComposerCanvasActiveDestination.resetForTesting() }

        var acceptedCount = 0
        let destination = ComposerCanvasDestination(sessionId: "timeline-chat") { _, _ in
            acceptedCount += 1
            return true
        }
        ComposerCanvasActiveDestination.push(destination)

        let presenter = UIViewController()
        let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        presenter.view.addSubview(sourceView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        presenter.loadViewIfNeeded()

        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            .mermaid(content: "graph TD; A-->B", filePath: nil),
            from: sourceView
        )

        ComposerCanvasActiveDestination.push(
            ComposerCanvasDestination(sessionId: "later-chat") { _, _ in true }
        )

        let viewer = try #require(presenter.presentedViewController as? FullScreenCodeViewController)
        let host = viewer.makeAnnotateHostForTesting()
        #expect(host.destinationSessionIdForTesting == "timeline-chat")

        let (image, pngData) = try makePNG()
        let outcome = host.completeAddToChatForTesting(
            attachment: PaperMarkupCanvasSession.makePendingImageAttachment(
                pngData: pngData,
                image: image
            ),
            recognizedText: "note"
        )

        #expect(outcome == .accepted)
        #expect(acceptedCount == 1)
    }

    @Test("initial fit does not use raw 2000pt paper as the starting viewport")
    func initialFitDoesNotUseRaw2000ptPaperAsStartingViewport() throws {
        let image = makeImage(width: 2_000, height: 1_500)
        let viewBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let obscured = CGRect(x: 0, y: 744, width: 390, height: 100)

        let markupBounds = PaperMarkupCanvasViewport.markupBounds(
            imageSize: image.size,
            fallbackViewSize: viewBounds.size
        )
        let unobscured = PaperMarkupCanvasViewport.unobscuredRect(
            in: viewBounds,
            obscuredFrame: obscured
        )
        let zoomRange = PaperMarkupCanvasViewport.zoomRangeAllowingAspectFit(
            markupSize: markupBounds.size,
            unobscuredSize: unobscured.size
        )

        #expect(markupBounds.size == CGSize(width: 2_000, height: 1_500))
        #expect(markupBounds.size != viewBounds.size)
        #expect(unobscured.height == 744)
        #expect(zoomRange.lowerBound < 1)
        #expect(zoomRange.lowerBound <= unobscured.width / 2_000 + 0.0001)
        #expect(PaperMarkupCanvasViewport.contentVisibleFrame(for: markupBounds) == markupBounds)

        let host = PaperMarkupCanvasHostController(background: .image(image))
        let window = UIWindow(frame: viewBounds)
        let navigation = UINavigationController(rootViewController: host)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.loadViewIfNeeded()
        host.view.layoutIfNeeded()
        host.debugApplyInitialFitForTesting()

        #expect(host.didApplyInitialFitForTesting)
        #expect(host.markupBoundsForTesting?.width == 2_000)
        #expect(host.markupBoundsForTesting?.height == 1_500)
        let appliedRange = try #require(host.zoomRangeForTesting)
        #expect(appliedRange.lowerBound < 1)
        #expect(appliedRange.lowerBound <= 390 / 2_000 + 0.05)
    }

    @Test("tiny loupe insert is scaled into the visible photo")
    func tinyLoupeInsertIsScaledIntoTheVisiblePhoto() throws {
        let source = CGRect(x: 980, y: 740, width: 80, height: 80)
        let visible = CGRect(x: 0, y: 600, width: 2000, height: 800)
        let transform = try #require(
            PaperMarkupInsertScaling.transform(source: source, visibleMarkup: visible)
        )
        let scaled = source.applying(transform)
        #expect(scaled.width > 200)
        #expect(abs(scaled.midX - visible.midX) < 1)
        #expect(abs(scaled.midY - visible.midY) < 1)
    }

    @Test("composer attachment strip hit targets meet HIG minimum")
    func composerAttachmentStripHitTargetsMeetHIGMinimum() {
        #expect(ComposerShared.attachmentThumbnailSize >= 72)
        #expect(ComposerShared.attachmentTileSize >= 80)
        #expect(ComposerShared.attachmentRemoveHitSize >= 44)
    }

    @Test("insert is tray accessory not nav +")
    func insertIsTrayAccessoryNotNavPlus() throws {
        let host = PaperMarkupCanvasHostController(background: .image(makeImage(width: 80, height: 60)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let navigation = UINavigationController(rootViewController: host)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.loadViewIfNeeded()
        host.view.layoutIfNeeded()

        let navItems = host.navigationItem.rightBarButtonItems ?? []
        #expect(navItems.contains { $0.title == "Add to Chat" })
        #expect(!navItems.contains { $0.accessibilityLabel == "Insert" })
        #expect(!navItems.contains { $0.image == UIImage(systemName: "plus") })

        let insert = try #require(host.toolPickerAccessoryItemForTesting)
        #expect(insert.accessibilityLabel == "Insert")

        let features = try #require(host.supportedFeatureSetForTesting)
        #expect(features.contains(.drawing))
        #expect(features.contains(.text))
        #expect(features.contains(.stickers))
        #expect(features.contains(.loupes))
        #expect(!features.contains(.links))
        #expect(!features.contains(.images))
        #expect(host.toolPickerColorUserInterfaceStyleForTesting == .light)

        let blankFeatures = PaperMarkupCanvasSession.markupFeatureSet(for: .blank)
        #expect(blankFeatures.contains(.text))
        #expect(blankFeatures.contains(.stickers))
        #expect(blankFeatures.contains(.loupes))
        #expect(!blankFeatures.contains(.links))

        host.debugPresentInsertForTesting()
        let presentedInsert = host.presentedViewController
        #expect(presentedInsert is MarkupEditViewController)
        #expect(presentedInsert?.modalPresentationStyle == .popover)
        #expect((presentedInsert?.preferredContentSize.width ?? 0) >= 240)
        #expect((presentedInsert?.preferredContentSize.height ?? 0) < 500)
    }

    @Test("export failure keeps the canvas and shows an actionable error")
    func exportFailureKeepsCanvasAndShowsActionableError() async {
        let destination = ComposerCanvasDestination(sessionId: "session-origin") { _, _ in true }
        let host = PaperMarkupCanvasHostController(
            background: .blank,
            destination: destination
        )
        host.loadViewIfNeeded()

        await host.debugAddToChatForTesting(failExport: true)

        #expect(host.didDismissForTesting == false)
        #expect(host.isShowingExportProgressForTesting == false)
        #expect(host.lastFailureMessageForTesting == PaperMarkupCanvasSession.AddToChatFailure.exportMessage)
        #expect(PaperMarkupCanvasSession.ExportProgress.title == "Adding to Chat…")
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

    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func firstSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
        if let match = root as? T {
            return match
        }
        for child in root.subviews {
            if let match = firstSubview(ofType: type, in: child) {
                return match
            }
        }
        return nil
    }
}

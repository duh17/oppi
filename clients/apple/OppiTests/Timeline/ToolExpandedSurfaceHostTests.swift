import CryptoKit
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import Oppi

@Suite("Tool expanded surface host")
@MainActor
struct ToolExpandedSurfaceHostTests {
    private func snapshotOutputDirectory(_ component: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-tool-expanded-surface-host-tests", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func expandedSurfaceHostActivatesExpectedSurfaceForEachMode() {
        let markdownView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: markdownView, width: 360)
        #expect(markdownView.activeExpandedSurfaceKindForTesting == .markdown)

        let diffView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "old"),
                DiffLine(kind: .added, text: "new"),
            ], path: "File.swift"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: diffView, width: 360)
        #expect(diffView.activeExpandedSurfaceKindForTesting == .label)

    }

    @Test func surfaceHostSizesToActiveVoiceViewWithoutPriorLayout() {
        let host = ToolExpandedSurfaceHostView()
        let voiceView = NativeAudioMessageView()
        voiceView.apply(
            id: "voice-host-size",
            message: "This final voice transcript should determine the host height immediately when the audio card replaces streaming text, without clipping the lower lines or waiting for a later collection view sizing pass to recover.",
            attachmentId: "att-1",
            mimeType: "audio/wav",
            playbackBehavior: .playNow,
            sessionId: nil,
            audioPlayer: nil,
            attachmentFetcher: nil,
            palette: ThemeRuntimeState.currentPalette()
        )
        host.activateSurfaceView(voiceView)

        let fitted = host.systemLayoutSizeFitting(
            CGSize(width: 342, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(fitted.height >= 130)
    }

    @Test func readMediaLandscapePhonePreviewDoesNotGrowToThreeScreensForSquareImages() {
        let height = ImageViewportSizing.fittedHeight(
            forWidth: 1_800,
            heightToWidthRatio: 1,
            surface: .primaryMedia,
            screenHeight: 430
        )

        #expect(height <= 516, "Square read-tool images in landscape should stay near one screen tall; got \(height)")
    }

    @Test func base64ImageBlobDoesNotSingleScreenCapPortraitScreenshotPreview() async throws {
        let previewWidth: CGFloat = 300
        let image = makeReadToolTestImage(size: CGSize(width: 300, height: 648))
        let imageData = try #require(image.pngData())
        let decodedImage = try #require(ImageDecodeCache.decode(base64: imageData.base64EncodedString(), maxPixelSize: 1600))
        #expect(decodedImage.size.height > decodedImage.size.width)
        let controller = UIHostingController(
            rootView: ImageBlobView(
                base64: imageData.base64EncodedString(),
                mimeType: "image/png"
            )
        )
        controller.view.backgroundColor = .clear

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: previewWidth, height: 900))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let singleScreenCap = try #require(ImageViewportSizing.maxHeight(
            for: .singleScreenFit,
            screenHeight: UIScreen.main.bounds.height
        ))
        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return controller.sizeThatFits(in: CGSize(width: previewWidth, height: 2_000)).height > singleScreenCap + 24
        }
        #expect(decoded)

        let fitted = controller.sizeThatFits(in: CGSize(width: previewWidth, height: 2_000))
        #expect(
            fitted.height > singleScreenCap + 24,
            "Portrait image output should not be height-capped like inline prose, because that creates horizontal empty space; fitted=\(fitted.height), singleScreenCap=\(singleScreenCap)"
        )
    }

    @Test func readMediaTallInlineImageUsesNaturalAspectHeight() async throws {
        let preview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let imageData = try #require(makeTallReadToolTestImage().pngData())
        preview.apply(base64: imageData.base64EncodedString(), mimeType: "image/png")

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return firstToolSubview(ofType: UIImageView.self, in: preview)?.image != nil
        }
        #expect(decoded)

        let fitted = preview.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        let expectedHeight = 320.0 * (220.0 / 80.0)
        #expect(abs(fitted.height - expectedHeight) < 2, "Tall read-tool image should use its natural aspect height: \(fitted.height)")
    }

    @Test func readMediaAttachmentImageFetchesAndUsesNaturalAspectHeight() async throws {
        let preview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let imageData = try #require(makeTallReadToolTestImage().pngData())
        preview.apply(
            attachment: ToolPresentationBuilder.ToolMediaAttachment(
                kind: "image",
                id: "att-tall-image",
                mimeType: "image/png",
                fileName: "tall.png",
                sizeBytes: imageData.count,
                width: 80,
                height: 220
            ),
            fetcher: { attachmentId in
                #expect(attachmentId == "att-tall-image")
                return imageData
            }
        )

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return readMediaContentImageView(in: preview) != nil
        }
        #expect(decoded)

        let fitted = preview.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let expectedHeight = 320.0 * (220.0 / 80.0)
        #expect(abs(fitted.height - expectedHeight) < 2)
    }

    @Test func readMediaAttachmentRejectsIncompleteBytesAndDoesNotCacheThem() async throws {
        let imageData = try #require(makeTallReadToolTestImage().jpegData(compressionQuality: 0.85))
        let truncatedData = Data(imageData.prefix(max(2, imageData.count / 3)))
        let attachmentID = "att-incomplete-image-\(UUID().uuidString)"
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: attachmentID,
            mimeType: "image/jpeg",
            fileName: "incomplete.jpg",
            sizeBytes: imageData.count,
            sha256: sha256Hex(imageData),
            width: 80,
            height: 220
        )

        let firstCounter = FetchCounter()
        let firstPreview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let firstContainer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        firstPreview.translatesAutoresizingMaskIntoConstraints = false
        firstContainer.addSubview(firstPreview)
        NSLayoutConstraint.activate([
            firstPreview.leadingAnchor.constraint(equalTo: firstContainer.leadingAnchor),
            firstPreview.trailingAnchor.constraint(equalTo: firstContainer.trailingAnchor),
            firstPreview.topAnchor.constraint(equalTo: firstContainer.topAnchor),
        ])
        firstPreview.apply(
            attachment: attachment,
            fetcher: { attachmentId in
                #expect(attachmentId == attachmentID)
                await firstCounter.increment()
                return truncatedData
            }
        )

        let firstFetchAttempted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await firstCounter.count == 1
        }
        #expect(firstFetchAttempted)
        try await Task.sleep(for: .milliseconds(120))
        firstContainer.setNeedsLayout()
        firstContainer.layoutIfNeeded()
        #expect(readMediaContentImageView(in: firstPreview) == nil)

        let secondCounter = FetchCounter()
        let secondPreview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let secondContainer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        secondPreview.translatesAutoresizingMaskIntoConstraints = false
        secondContainer.addSubview(secondPreview)
        NSLayoutConstraint.activate([
            secondPreview.leadingAnchor.constraint(equalTo: secondContainer.leadingAnchor),
            secondPreview.trailingAnchor.constraint(equalTo: secondContainer.trailingAnchor),
            secondPreview.topAnchor.constraint(equalTo: secondContainer.topAnchor),
        ])
        secondPreview.apply(
            attachment: attachment,
            fetcher: { attachmentId in
                #expect(attachmentId == attachmentID)
                await secondCounter.increment()
                return imageData
            }
        )

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            secondContainer.setNeedsLayout()
            secondContainer.layoutIfNeeded()
            return readMediaContentImageView(in: secondPreview) != nil
        }
        #expect(decoded)
        #expect(await secondCounter.count == 1)
    }

    @Test func readMediaAttachmentImageFetchSurvivesPreviewRecreation() async throws {
        let imageData = try #require(makeTallReadToolTestImage().pngData())
        let fetchGate = AttachmentFetchGate(data: imageData)
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-recreated-preview-image",
            mimeType: "image/png",
            fileName: "recreated.png",
            sizeBytes: imageData.count,
            width: 80,
            height: 220
        )

        do {
            let firstPreview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
            firstPreview.apply(
                attachment: attachment,
                fetcher: { attachmentId in
                    #expect(attachmentId == "att-recreated-preview-image")
                    return await fetchGate.fetch()
                }
            )
        }

        let firstFetchStarted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await fetchGate.fetchCount == 1
        }
        #expect(firstFetchStarted)

        let secondPreview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        secondPreview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(secondPreview)
        NSLayoutConstraint.activate([
            secondPreview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            secondPreview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            secondPreview.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        secondPreview.apply(
            attachment: attachment,
            fetcher: { attachmentId in
                #expect(attachmentId == "att-recreated-preview-image")
                return await fetchGate.fetch()
            }
        )

        try await Task.sleep(for: .milliseconds(80))
        #expect(await fetchGate.fetchCount == 1, "Recreating an expanded image row should attach to the in-flight attachment fetch instead of starting a second request")

        await fetchGate.release()
        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return readMediaContentImageView(in: secondPreview) != nil
        }
        #expect(decoded)
    }

    @Test func readMediaImageAttachmentHidesReadToolBoilerplate() async throws {
        let imageData = try #require(makeReadToolTestImage(size: CGSize(width: 120, height: 80)).pngData())
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-generated-image",
            mimeType: "image/png",
            fileName: "generated.png",
            sizeBytes: imageData.count,
            width: 120,
            height: 80
        )
        let view = NativeExpandedReadMediaView()
        let filePath = "/tmp/generated.png"
        view.apply(
            output: "Read image file [image/png]",
            isError: false,
            filePath: filePath,
            startLine: 1,
            attachments: [attachment],
            themeID: ThemeRuntimeState.currentThemeID(),
            audioPlayer: nil,
            attachmentFetcher: { attachmentId in
                #expect(attachmentId == "att-generated-image")
                return imageData
            },
            sessionFileDataFetcher: nil,
            sessionFileMediaSourceProvider: nil
        )

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return readMediaContentImageView(in: view) != nil
        }
        #expect(decoded)

        let visibleLabelText = timelineAllLabels(in: view)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .map(timelineRenderedText)
            .filter { !$0.isEmpty }

        #expect(!visibleLabelText.contains(filePath))
        #expect(!visibleLabelText.contains("Read image file [image/png]"))
        #expect(!visibleLabelText.contains("Image"))
    }

    @Test func readMediaImageAttachmentWithoutFetcherKeepsReadToolFallback() throws {
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-unavailable-image",
            mimeType: "image/png",
            fileName: "generated.png",
            sizeBytes: 12_345,
            width: 120,
            height: 80
        )
        let view = NativeExpandedReadMediaView()
        let filePath = "/tmp/generated.png"
        view.apply(
            output: "Read image file [image/png]",
            isError: false,
            filePath: filePath,
            startLine: 1,
            attachments: [attachment],
            themeID: ThemeRuntimeState.currentThemeID(),
            audioPlayer: nil,
            attachmentFetcher: nil,
            sessionFileDataFetcher: nil,
            sessionFileMediaSourceProvider: nil
        )

        let visibleLabelText = timelineAllLabels(in: view)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .map(timelineRenderedText)
            .filter { !$0.isEmpty }

        #expect(visibleLabelText.contains(filePath))
        #expect(visibleLabelText.contains("Read image file [image/png]"))
    }

    @Test func readMediaAttachmentImageHidesReadDebugMetadata() async throws {
        let imageData = try #require(makeReadToolTestImage(size: CGSize(width: 120, height: 80)).pngData())
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-resized-image",
            mimeType: "image/png",
            fileName: "generated.png",
            sizeBytes: imageData.count,
            width: 120,
            height: 80
        )
        let view = NativeExpandedReadMediaView()
        view.apply(
            output: "Read image file [image/png]\n[Image: original 240x160, displayed at 120x80. Multiply coordinates by 2.00 to map to original image.]",
            isError: false,
            filePath: "/tmp/generated.png",
            startLine: 1,
            attachments: [attachment],
            themeID: ThemeRuntimeState.currentThemeID(),
            audioPlayer: nil,
            attachmentFetcher: { _ in imageData },
            sessionFileDataFetcher: nil,
            sessionFileMediaSourceProvider: nil
        )

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return readMediaContentImageView(in: view) != nil
        }
        #expect(decoded)

        let visibleLabelText = timelineAllLabels(in: view)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .map(timelineRenderedText)
            .filter { !$0.isEmpty }

        #expect(!visibleLabelText.contains("Read image file [image/png]"))
        #expect(!visibleLabelText.contains { $0.contains("original 240x160") })
    }

    @Test func readMediaAttachmentImageRetriesWhenFetcherBecomesAvailable() async throws {
        let imageData = try #require(makeTallReadToolTestImage().pngData())
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-late-fetcher-image",
            mimeType: "image/png",
            fileName: "late.png",
            sizeBytes: imageData.count,
            width: 80,
            height: 220
        )
        let baseConfiguration = makeTimelineToolConfiguration(
            title: "read /tmp/late.png",
            expandedContent: .readMedia(output: "", filePath: "/tmp/late.png", startLine: 1, attachments: [attachment]),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: baseConfiguration)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 1_600))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(readMediaContentImageView(in: view) == nil)
        let showsUnavailable = timelineAllLabels(in: view).contains {
            !$0.isHidden && $0.text == "Image unavailable"
        }
        let hasAnimatingIndicator = timelineAllViews(in: view)
            .compactMap { $0 as? UIActivityIndicatorView }
            .contains { $0.isAnimating }
        let unavailableViewport = timelineAllViews(in: view).first {
            $0.accessibilityIdentifier == "toolRow.readMedia.imageViewport"
        }
        #expect(showsUnavailable)
        #expect(!hasAnimatingIndicator)
        #expect(unavailableViewport?.accessibilityLabel == "Image unavailable")
        #expect(unavailableViewport?.accessibilityValue == nil)

        view.configuration = baseConfiguration.withSessionAttachmentFetcher { attachmentId in
            #expect(attachmentId == "att-late-fetcher-image")
            return imageData
        }

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return readMediaContentImageView(in: view) != nil
        }
        #expect(decoded)
    }

    /// Regression: expanded read-tool images decode asynchronously. Soft layout
    /// invalidation is skipped while the timeline is detached from bottom, so after
    /// scroll-away/recycle the row can stay cut off until another interaction.
    /// Image size changes must force-invalidate even while detached.
    @Test func readMediaImageGrowsToAspectHeightWhileDetachedFromBottom() async throws {
        let hostSize = CGSize(width: 390, height: 700)
        let image = makeReadToolTestImage(size: CGSize(width: 80, height: 320))
        let imageData = try #require(image.pngData())
        let attachmentID = "att-detached-read-image-\(UUID().uuidString)"
        let gate = AttachmentFetchGate(data: imageData)
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: attachmentID,
            mimeType: "image/png",
            fileName: "tall-detached.png",
            sizeBytes: imageData.count,
            width: nil,
            height: nil
        )
        let configuration = makeTimelineToolConfiguration(
            title: "read /tmp/tall-detached.png",
            expandedContent: .readMedia(
                output: "",
                filePath: "/tmp/tall-detached.png",
                startLine: 1,
                attachments: [attachment]
            ),
            toolNamePrefix: "read",
            isExpanded: true
        ).withSessionAttachmentFetcher { attachmentId in
            #expect(attachmentId == attachmentID)
            return await gate.fetch()
        }

        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = AnchoredCollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: layout
        )
        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.addSubview(collectionView)
        collectionView.frame = hostController.view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, itemID in
            if itemID == "tool-image" {
                cell.contentConfiguration = configuration
            } else {
                cell.contentConfiguration = makeTimelineToolConfiguration(
                    title: "read /tmp/\(itemID).txt",
                    expandedContent: .text(
                        text: Array(
                            repeating: "Stable trailing timeline context for \(itemID).",
                            count: 5
                        ).joined(separator: "\n"),
                        language: nil
                    ),
                    toolNamePrefix: "read",
                    isExpanded: true
                )
            }
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { cv, indexPath, itemID in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(
            ["tool-image", "tool-stable"] + (0..<8).map { "tool-tail-\($0)" }
        )
        await dataSource.apply(snapshot, animatingDifferences: false)
        hostController.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let firstIP = IndexPath(item: 0, section: 0)
        let stableIP = IndexPath(item: 1, section: 0)
        let initialFirstHeight = try #require(
            collectionView.layoutAttributesForItem(at: firstIP)?.frame.height
        )
        let stableViewportYBefore = try #require(
            collectionView.layoutAttributesForItem(at: stableIP)?.frame.minY
        ) - collectionView.contentOffset.y
        #expect(
            collectionView.bounds.contains(
                CGPoint(x: collectionView.bounds.midX, y: stableViewportYBefore)
            ),
            "Stable row after the image must begin visible before gated decode"
        )

        collectionView.isDetachedFromBottom = true
        collectionView.captureDetachedAnchor()
        #expect(collectionView.detachedAnchorIsActive)

        let fetchStarted = await waitForTimelineCondition(timeoutMs: 1_200) {
            await gate.fetchCount >= 1
        }
        #expect(fetchStarted, "Expected gated read-tool image fetch to start while detached")
        #expect(
            initialFirstHeight < 320,
            "Pre-decode detached image row should start compact; got \(initialFirstHeight)"
        )

        await gate.release()

        // Force-invalidate drives growth. Avoid settleTimelineLayout here so a
        // soft-invalidate regression cannot be masked by test-driven remeasure.
        let reflowed = await waitForTimelineCondition(timeoutMs: 2_400) { @MainActor in
            guard let firstCell = collectionView.cellForItem(at: firstIP),
                  let preview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: firstCell.contentView),
                  readMediaContentImageView(in: preview) != nil,
                  let firstFrame = collectionView.layoutAttributesForItem(at: firstIP)?.frame
            else {
                return false
            }
            // NativeExpandedInlineImageView uses window.bounds.height for the cap.
            let expectedImageHeight = ImageViewportSizing.fittedHeight(
                forWidth: max(1, preview.bounds.width),
                heightToWidthRatio: 320.0 / 80.0,
                surface: .primaryMedia,
                screenHeight: window.bounds.height
            )
            let imageTallEnough = preview.bounds.height >= expectedImageHeight - 8
            let rowGrew = firstFrame.height > initialFirstHeight + 80
            return imageTallEnough && rowGrew
        }

        let finalPreviewHeight: CGFloat = {
            guard let firstCell = collectionView.cellForItem(at: firstIP),
                  let preview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: firstCell.contentView)
            else {
                return -1
            }
            return preview.bounds.height
        }()
        let finalFirstHeight = collectionView.layoutAttributesForItem(at: firstIP)?.frame.height ?? -1
        #expect(
            reflowed,
            "Detached read-tool image stayed cut off after decode; initialRow=\(initialFirstHeight), finalRow=\(finalFirstHeight), previewHeight=\(finalPreviewHeight)"
        )
        let stableViewportYAfter = try #require(
            collectionView.layoutAttributesForItem(at: stableIP)?.frame.minY
        ) - collectionView.contentOffset.y
        #expect(
            abs(stableViewportYAfter - stableViewportYBefore) <= 1,
            "Gated read-image growth moved stable row from viewport y=\(stableViewportYBefore) to y=\(stableViewportYAfter)"
        )
    }

    @Test func readMediaImageGrowthKeepsAttachedReaderOnActualTail() async throws {
        let hostSize = CGSize(width: 390, height: 700)
        let imageData = try #require(
            makeReadToolTestImage(size: CGSize(width: 80, height: 320)).pngData()
        )
        let attachmentID = "att-attached-tail-\(UUID().uuidString)"
        let gate = AttachmentFetchGate(data: imageData)
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: attachmentID,
            mimeType: "image/png",
            fileName: "attached-tail.png",
            sizeBytes: imageData.count,
            width: nil,
            height: nil
        )
        let imageConfiguration = makeTimelineToolConfiguration(
            title: "read /tmp/attached-tail.png",
            expandedContent: .readMedia(
                output: "",
                filePath: "/tmp/attached-tail.png",
                startLine: 1,
                attachments: [attachment]
            ),
            toolNamePrefix: "read",
            isExpanded: true
        ).withSessionAttachmentFetcher { id in
            #expect(id == attachmentID)
            return await gate.fetch()
        }
        let stableConfiguration = makeTimelineToolConfiguration(
            title: "read /tmp/context.txt",
            expandedContent: .text(
                text: Array(repeating: "Stable attached-tail context.", count: 6).joined(separator: "\n"),
                language: nil
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let collectionView = AnchoredCollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.addSubview(collectionView)
        collectionView.frame = hostController.view.bounds
        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let ids = (0..<6).map { "tool-context-\($0)" } + ["tool-image", "tool-after"]
        let coordinator = ChatTimelineCollectionHost.Controller()
        let scrollController = ChatScrollController()
        coordinator.collectionView = collectionView
        coordinator.currentIDs = ids
        coordinator.scrollController = scrollController
        coordinator.sessionId = "attached-image-growth"
        coordinator.isTimelineBusy = true
        collectionView.delegate = coordinator

        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, itemID in
            cell.contentConfiguration = itemID == "tool-image"
                ? imageConfiguration
                : stableConfiguration
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            cv, indexPath, itemID in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        await dataSource.apply(snapshot, animatingDifferences: false)
        hostController.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: IndexPath(item: ids.count - 1, section: 0),
            at: .bottom,
            animated: false
        )
        collectionView.layoutIfNeeded()
        scrollController.updateNearBottom(true)

        let imageIndexPath = IndexPath(item: ids.count - 2, section: 0)
        let initialImageHeight = try #require(
            collectionView.layoutAttributesForItem(at: imageIndexPath)?.frame.height
        )
        let fetchStarted = await waitForTimelineCondition(timeoutMs: 1_200) {
            await gate.fetchCount >= 1
        }
        #expect(fetchStarted)
        await gate.release()

        let stayedAtTail = await waitForTimelineCondition(timeoutMs: 2_400) { @MainActor in
            guard let imageHeight = collectionView.layoutAttributesForItem(at: imageIndexPath)?.frame.height,
                  imageHeight > initialImageHeight + 80 else {
                return false
            }
            let maxOffsetY = TimelineOffsetController.clampedOffsetY(
                .greatestFiniteMagnitude,
                in: collectionView
            )
            return scrollController.isCurrentlyNearBottom
                && abs(collectionView.contentOffset.y - maxOffsetY) <= 1
        }

        #expect(
            stayedAtTail,
            "Near-tail image growth must settle the attached reader on the actual live tail"
        )
    }

    @Test func forcedImageInvalidationAggregatesTwoSourcesAcrossRecycleAndLongInteraction() async throws {
        let layout = ToolInvalidationCountingLayout()
        let collectionView = ToolInteractionTrackingCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            collectionViewLayout: layout
        )
        var firstSource: UIView? = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        weak var recycledFirstSource = firstSource
        let secondSource = UIView(frame: CGRect(x: 0, y: 50, width: 40, height: 40))
        collectionView.addSubview(try #require(firstSource))
        collectionView.addSubview(secondSource)
        collectionView.layoutIfNeeded()
        await Task.yield()

        collectionView.testIsTracking = true
        let baselineInvalidations = layout.invalidationCount
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: try #require(firstSource)
        )
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: secondSource
        )
        firstSource?.removeFromSuperview()
        firstSource = nil
        await Task.yield()
        #expect(recycledFirstSource == nil)

        try? await Task.sleep(for: .seconds(5))
        #expect(
            ToolTimelineRowPresentationHelpers.forcedInteractionInvalidationIsPendingForTesting(
                collectionView
            ),
            "The collection-level reflow must outlive its first recycled source and the old retry window"
        )
        collectionView.testIsTracking = false

        let invalidatedAfterInteraction = await waitForTimelineCondition(timeoutMs: 600) { @MainActor in
            layout.invalidationCount > baselineInvalidations
        }
        #expect(
            invalidatedAfterInteraction,
            "One eventual full invalidation must cover both decoded rows after the long interaction"
        )
        let settledInvalidationCount = layout.invalidationCount
        try? await Task.sleep(for: .milliseconds(350))
        #expect(
            layout.invalidationCount == settledInvalidationCount,
            "The aggregated forced request must settle once without a hot loop"
        )
    }

    /// Recycled/remounted image while detached: no dimension metadata, gated
    /// decode, prove short → tall without test-driven settle loops.
    ///
    /// This is the user scroll-away/back path reduced to its layout-critical
    /// core: a brand-new cell mounts short under an active detached anchor,
    /// then async image height must force-invalidate to grow the row.
    @Test func readMediaImageKeepsAspectHeightAfterScrollRecycleWhileDetached() async throws {
        let hostSize = CGSize(width: 390, height: 700)
        let image = makeReadToolTestImage(size: CGSize(width: 80, height: 320))
        let imageData = try #require(image.pngData())
        let attachmentID = "att-recycle-remount-\(UUID().uuidString)"
        let gate = AttachmentFetchGate(data: imageData)
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: attachmentID,
            mimeType: "image/png",
            fileName: "recycle-remount.png",
            sizeBytes: imageData.count,
            width: nil,
            height: nil
        )
        let imageConfiguration = makeTimelineToolConfiguration(
            title: "read /tmp/recycle-remount.png",
            expandedContent: .readMedia(
                output: "",
                filePath: "/tmp/recycle-remount.png",
                startLine: 1,
                attachments: [attachment]
            ),
            toolNamePrefix: "read",
            isExpanded: true
        ).withSessionAttachmentFetcher { id in
            #expect(id == attachmentID)
            return await gate.fetch()
        }
        let afterConfiguration = makeTimelineToolConfiguration(
            title: "read /tmp/after-recycle.txt",
            expandedContent: .text(
                text: "Trailing row after recycled image.",
                language: nil
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = AnchoredCollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: layout
        )
        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.addSubview(collectionView)
        collectionView.frame = hostController.view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, itemID in
            if itemID == "tool-image" {
                cell.contentConfiguration = imageConfiguration
            } else {
                cell.contentConfiguration = afterConfiguration
            }
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { cv, indexPath, itemID in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }

        // Phase 1: mount a plain row, detach, then replace it with the gated
        // image row so the image cell is a true remount under detached anchor.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(["tool-after"])
        await dataSource.apply(snapshot, animatingDifferences: false)
        hostController.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        collectionView.isDetachedFromBottom = true
        collectionView.captureDetachedAnchor()
        #expect(collectionView.detachedAnchorIsActive)

        snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(["tool-image", "tool-after"])
        await dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()

        let imageIP = IndexPath(item: 0, section: 0)
        let fetchStarted = await waitForTimelineCondition(timeoutMs: 1_200) {
            await gate.fetchCount >= 1
        }
        #expect(fetchStarted, "Expected recycled image fetch to start while gated")

        let mountedShort = await waitForTimelineCondition(timeoutMs: 800) { @MainActor in
            guard let cell = collectionView.cellForItem(at: imageIP),
                  let preview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: cell.contentView),
                  let rowFrame = collectionView.layoutAttributesForItem(at: imageIP)?.frame
            else {
                return false
            }
            return preview.bounds.height <= ImageViewportSizing.defaultPlaceholderHeight + 1
                && rowFrame.height < 320
                && readMediaContentImageView(in: preview) == nil
        }
        #expect(mountedShort, "Remounted detached image cell should start short before decode")

        let shortRowHeight = collectionView.layoutAttributesForItem(at: imageIP)?.frame.height ?? -1
        await gate.release()

        // Do not call settleTimelineLayout / setNeedsLayout after release. The
        // production force-invalidate path must drive the growth itself; soft
        // invalidation while detached would leave the short height stuck.
        let recovered = await waitForTimelineCondition(timeoutMs: 2_400) { @MainActor in
            guard let cell = collectionView.cellForItem(at: imageIP),
                  let preview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: cell.contentView),
                  readMediaContentImageView(in: preview) != nil,
                  let rowFrame = collectionView.layoutAttributesForItem(at: imageIP)?.frame
            else {
                return false
            }
            let expected = ImageViewportSizing.fittedHeight(
                forWidth: max(1, preview.bounds.width),
                heightToWidthRatio: 320.0 / 80.0,
                surface: .primaryMedia,
                screenHeight: window.bounds.height
            )
            return preview.bounds.height >= expected - 8
                && rowFrame.height > shortRowHeight + 80
                && rowFrame.height >= expected
        }

        let finalPreviewHeight: CGFloat = {
            guard let cell = collectionView.cellForItem(at: imageIP),
                  let preview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: cell.contentView)
            else {
                return -1
            }
            return preview.bounds.height
        }()
        let finalRowHeight = collectionView.layoutAttributesForItem(at: imageIP)?.frame.height ?? -1
        #expect(
            recovered,
            "Remounted detached image stayed cut off after gated decode; shortRow=\(shortRowHeight), finalPreview=\(finalPreviewHeight), finalRow=\(finalRowHeight)"
        )
    }

    @Test func readMediaTallImageKeepsExpandedScrollPinnedWhileOuterTimelineScrolls() async throws {
        let image = makeReadToolTestImage(size: CGSize(width: 80, height: 220))
        let imageData = try #require(image.pngData())
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(imageData.base64EncodedString())"
        let configuration = makeTimelineToolConfiguration(
            title: "read /tmp/tall-read-image.png",
            expandedContent: .readMedia(output: output, filePath: "/tmp/tall-read-image.png", startLine: 1, attachments: []),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: configuration)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 1_600))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return readMediaContentImageView(in: view) != nil
        }
        #expect(decoded)

        let rowSize = view.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(origin: .zero, size: rowSize)
        container.frame = CGRect(origin: .zero, size: rowSize)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let renderedImageView = try #require(readMediaContentImageView(in: view))
        let imageFrame = renderedImageView.convert(renderedImageView.bounds, to: view)
        let expectedImageHeight = imageFrame.width * (220.0 / 80.0)
        #expect(abs(imageFrame.height - expectedImageHeight) < 8)

        let scrollView = view.expandedScrollView
        let verticalOverflow = scrollView.contentSize.height - scrollView.bounds.height
        #expect(verticalOverflow <= 2, "Read-media should not leave an inner vertical viewport that can reveal different image slices while scrolling; overflow=\(verticalOverflow)")

        scrollView.contentOffset.y = 160
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let visualOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        #expect(abs(visualOffset) < 1, "Read-media inner scroll should stay pinned to top; got offset=\(scrollView.contentOffset)")
    }

    @Test func readMediaVerticalAndHorizontalSnapshotsUseExpectedAspectFits() async throws {
        let outputDirectory = try snapshotOutputDirectory("read-media-image-fit")

        let vertical = try await renderReadMediaSnapshot(
            image: makeReadToolTestImage(size: CGSize(width: 80, height: 220)),
            filePath: "/tmp/oppi-screenshots/vertical-read-image.png",
            outputURL: outputDirectory.appendingPathComponent("vertical-read-image.png")
        )
        let horizontal = try await renderReadMediaSnapshot(
            image: makeReadToolTestImage(size: CGSize(width: 220, height: 80)),
            filePath: "/tmp/oppi-screenshots/horizontal-read-image.png",
            outputURL: outputDirectory.appendingPathComponent("horizontal-read-image.png")
        )

        let expectedVerticalImageHeight = vertical.imageFrame.width * (220.0 / 80.0)
        #expect(abs(vertical.imageFrame.height - expectedVerticalImageHeight) < 8, "Vertical read-media image should not be clamped: frame=\(vertical.imageFrame)")
        #expect(vertical.imageFrame.height > vertical.imageFrame.width * 1.5)
        #expect(vertical.rowSize.height > horizontal.rowSize.height * 2.0)
        #expect(horizontal.imageFrame.width > horizontal.imageFrame.height * 2.0)
        #expect(FileManager.default.fileExists(atPath: vertical.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: horizontal.outputURL.path))
    }

    @Test func svgReadMediaAttachmentReflowsTimelineAfterAsyncDecodeWithoutDimensionMetadata() async throws {
        let hostSize = CGSize(width: 393, height: 852)
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: layout
        )
        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.addSubview(collectionView)
        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let svg = #"""
<svg xmlns="http://www.w3.org/2000/svg" width="720" height="420">
  <rect width="100%" height="100%" fill="#111827"/>
  <text x="32" y="48" font-family="-apple-system" font-size="28" fill="white">AMZN past week</text>
  <circle cx="84" cy="120" r="10" fill="#60a5fa"/>
  <circle cx="636" cy="320" r="10" fill="#60a5fa"/>
  <text x="40" y="388" font-family="-apple-system" font-size="22" fill="#cbd5e1">May 8</text>
  <text x="580" y="388" font-family="-apple-system" font-size="22" fill="#cbd5e1">May 14</text>
</svg>
"""#
        let svgData = Data(svg.utf8)
        let attachment = ToolPresentationBuilder.ToolMediaAttachment(
            kind: "image",
            id: "att-read-svg-no-size",
            mimeType: "image/svg+xml",
            fileName: "amzn-week.svg",
            sizeBytes: svgData.count,
            width: nil,
            height: nil
        )

        let items: [(String, ToolTimelineRowConfiguration)] = [
            (
                "tool-svg",
                makeTimelineToolConfiguration(
                    title: "read /tmp/amzn-week.svg",
                    expandedContent: .readMedia(output: "", filePath: "/tmp/amzn-week.svg", startLine: 1, attachments: [attachment]),
                    toolNamePrefix: "read",
                    isExpanded: true
                ).withSessionAttachmentFetcher { attachmentId in
                    #expect(attachmentId == "att-read-svg-no-size")
                    try await Task.sleep(for: .milliseconds(50))
                    return svgData
                }
            ),
            (
                "tool-after",
                makeTimelineToolConfiguration(
                    title: "read /tmp/after.txt",
                    expandedContent: .text(text: "This row must move down after the SVG preview grows.", language: nil),
                    toolNamePrefix: "read",
                    isExpanded: true
                )
            ),
        ]

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let config = items.first(where: { $0.0 == itemID })?.1 else { return }
            cell.contentConfiguration = config
        }

        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, indexPath, itemID in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.0))
        await dataSource.apply(snapshot, animatingDifferences: false)
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let firstIP = IndexPath(item: 0, section: 0)
        let secondIP = IndexPath(item: 1, section: 0)
        let initialSecondMinY = try #require(collectionView.layoutAttributesForItem(at: secondIP)?.frame.minY)

        let imageRendered = await waitForTimelineCondition(timeoutMs: 1_800) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()
            guard let firstCell = collectionView.cellForItem(at: firstIP),
                  let inlinePreview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: firstCell.contentView),
                  let webView = firstToolSubview(ofType: ReviewCommentWKWebView.self, in: inlinePreview) else {
                return false
            }
            let imageReady = (try? await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0") as? Bool) == true
            return imageReady && inlinePreview.bounds.height > 180
        }

        #expect(imageRendered, "Expected SVG attachment preview to render and grow beyond the placeholder height")

        let layoutReflowed = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()
            guard let firstFrame = collectionView.layoutAttributesForItem(at: firstIP)?.frame,
                  let secondFrame = collectionView.layoutAttributesForItem(at: secondIP)?.frame else {
                return false
            }
            let rowsSeparated = secondFrame.minY >= firstFrame.maxY - 0.5
            let secondRowMovedDown = secondFrame.minY > initialSecondMinY + 4
            let initialLayoutReservedUsefulSpace = initialSecondMinY >= firstFrame.maxY - 24
            return rowsSeparated && (secondRowMovedDown || initialLayoutReservedUsefulSpace)
        }

        #expect(layoutReflowed, "Tool timeline did not keep SVG attachment rows separated after async decode")
    }

    @Test func brentSVGPreviewSnapshotFillsWidthAndShowsLowerAxis() async throws {
        let outputDirectory = try snapshotOutputDirectory("svg-regression")
        let outputURL = outputDirectory.appendingPathComponent("brent-svg-preview.png")

        let screenshot = try await renderBrentSVGPreviewSnapshot(outputURL: outputURL)
        let edgeFillPixels = countBrightBackgroundPixelsNearHorizontalEdges(in: screenshot)
        let lowerBandPixels = countNonBackgroundPixels(
            in: screenshot,
            minYFraction: 0.78,
            maxYFraction: 0.98
        )

        #expect(
            edgeFillPixels > 5_000,
            "Expected the SVG to fill the preview width after WebKit layout; found only \(edgeFillPixels) bright edge pixels"
        )
        #expect(
            lowerBandPixels > 300,
            "Expected the scaled SVG screenshot to include the lower chart axis and labels; found only \(lowerBandPixels) non-background pixels in the lower band"
        )
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func brentSVGReadMediaRowSnapshotFillsWidthAndShowsLowerAxis() async throws {
        let outputDirectory = try snapshotOutputDirectory("svg-regression")
        let outputURL = outputDirectory.appendingPathComponent("brent-svg-read-media-row-preview.png")

        let screenshot = try await renderBrentSVGReadMediaPreviewSnapshot(outputURL: outputURL)
        let edgeFillPixels = countBrightBackgroundPixelsNearHorizontalEdges(in: screenshot)
        let lowerBandPixels = countNonBackgroundPixels(
            in: screenshot,
            minYFraction: 0.78,
            maxYFraction: 0.98
        )

        #expect(
            edgeFillPixels > 5_000,
            "Expected the SVG to fill the preview width after WebKit layout; found only \(edgeFillPixels) bright edge pixels"
        )
        #expect(
            lowerBandPixels > 300,
            "Expected the scaled SVG screenshot to include the lower chart axis and labels; found only \(lowerBandPixels) non-background pixels in the lower band"
        )
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func tallReadMediaKeepsImageAndOpenLabelAlignedInsideRowWidth() async throws {
        let hostSize = CGSize(width: 390, height: 700)
        let imageData = try #require(makeReadToolTestImage(size: CGSize(width: 160, height: 474)).pngData())
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(imageData.base64EncodedString())"
        let configuration = makeTimelineToolConfiguration(
            title: "read /tmp/telemetry-1d.png",
            expandedContent: .readMedia(
                output: output,
                filePath: "/tmp/telemetry-1d.png",
                startLine: 1,
                attachments: []
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: layout
        )
        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.addSubview(collectionView)
        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, _ in
            cell.contentConfiguration = configuration
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, indexPath, itemID in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(["tool-svg"])
        await dataSource.apply(snapshot, animatingDifferences: false)

        let ready = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()
            guard let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) else {
                return false
            }
            return readMediaContentImageView(in: cell.contentView) != nil
        }
        #expect(ready)

        let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        let view = try #require(firstToolSubview(ofType: ToolTimelineRowContentView.self, in: cell.contentView))
        let rowBounds = view.bounds
        let scrollView = view.expandedScrollView
        let preview = try #require(firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: view))
        let openLabel = try #require(timelineAllLabels(in: preview).first { $0.text == "Tap to open full image" })
        let previewFrame = preview.convert(preview.bounds, to: view)
        let openLabelFrame = openLabel.convert(openLabel.bounds, to: view)

        #expect(scrollView.contentInsetAdjustmentBehavior == .never)
        #expect(scrollView.contentOffset.x == -scrollView.adjustedContentInset.left)
        #expect(scrollView.contentSize.width <= scrollView.bounds.width + 1)
        #expect(previewFrame.minX >= rowBounds.minX - 1)
        #expect(previewFrame.maxX <= rowBounds.maxX + 1)
        #expect(openLabelFrame.minX >= previewFrame.minX - 1)
        #expect(openLabelFrame.maxX <= previewFrame.maxX + 1)

        let outputURL = try snapshotOutputDirectory("tall-read-media-alignment")
            .appendingPathComponent("tall-read-media-alignment.png")
        let screenshot = UIGraphicsImageRenderer(size: hostSize).image { _ in
            hostController.view.drawHierarchy(
                in: CGRect(origin: .zero, size: hostSize),
                afterScreenUpdates: true
            )
        }
        try #require(screenshot.pngData()).write(to: outputURL, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func svgReadMediaPreviewUsesSingleTapFullscreenActivation() async throws {
        let preview = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 260))
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        preview.apply(
            base64: Data(Self.brentCrudeSVGFromTempDirectory.utf8).base64EncodedString(),
            mimeType: "image/svg+xml"
        )

        let ready = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return firstToolSubview(ofType: AnimatedImageWebContainerView.self, in: preview) != nil
                && firstToolSubview(ofType: ReviewCommentWKWebView.self, in: preview) != nil
        }
        #expect(ready)

        let animatedView = try #require(firstToolSubview(ofType: AnimatedImageWebContainerView.self, in: preview))
        let webView = try #require(firstToolSubview(ofType: ReviewCommentWKWebView.self, in: preview))
        let singleTap = animatedView.gestureRecognizers?.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 1
        } ?? false

        #expect(singleTap, "SVG previews should open full screen with one tap, matching static image previews")
        #expect(!webView.isUserInteractionEnabled, "The nested WKWebView should not swallow taps meant for the preview card")
    }

    @Test func expandedMarkdownViewportRebuildsForThemeChange() {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        let configuration = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        )

        ThemeRuntimeState.setThemeID(.light)
        let view = ToolTimelineRowContentView(configuration: configuration)
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.expandedMarkdownViewportThemeIDForTesting == .light)

        ThemeRuntimeState.setThemeID(.dark)
        view.configuration = configuration
        _ = fittedTimelineSize(for: view, width: 360)

        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)
        #expect(view.expandedMarkdownViewportThemeIDForTesting == .dark)
    }

    @Test func expandedSurfaceHostSwitchesActiveSurfaceOnReuse() {
        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)

        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
            isExpanded: true
        )
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .label)

        view.configuration = makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: "data:image/png;base64,abc",
                filePath: "icon.png",
                startLine: 1
            , attachments: []),
            isExpanded: true
        )
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)

        view.configuration = makeTimelineToolConfiguration(isExpanded: false)
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .none)
    }

    private func makeTallReadToolTestImage() -> UIImage {
        makeReadToolTestImage(size: CGSize(width: 80, height: 220))
    }

    private func makeReadToolTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(
                x: size.width * 0.25,
                y: size.height * 0.08,
                width: size.width * 0.5,
                height: size.height * 0.84
            ))
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct ReadMediaSnapshotResult {
        let rowSize: CGSize
        let imageFrame: CGRect
        let outputURL: URL
    }

    private func renderReadMediaSnapshot(
        image: UIImage,
        filePath: String,
        outputURL: URL
    ) async throws -> ReadMediaSnapshotResult {
        let imageData = try #require(image.pngData())
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(imageData.base64EncodedString())"
        let configuration = makeTimelineToolConfiguration(
            title: "read \(filePath)",
            expandedContent: .readMedia(output: output, filePath: filePath, startLine: 1, attachments: []),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: configuration)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 1_400))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()
        view.configuration = configuration

        let decoded = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return readMediaContentImageView(in: view) != nil
        }
        #expect(decoded)

        let rowSize = view.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(origin: .zero, size: rowSize)
        container.frame = CGRect(origin: .zero, size: rowSize)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let renderedImageView = try #require(readMediaContentImageView(in: view))
        let imageFrame = renderedImageView.convert(renderedImageView.bounds, to: view)
        let snapshot = UIGraphicsImageRenderer(size: rowSize).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: rowSize), afterScreenUpdates: true)
        }
        try #require(snapshot.pngData()).write(to: outputURL, options: .atomic)

        return ReadMediaSnapshotResult(rowSize: rowSize, imageFrame: imageFrame, outputURL: outputURL)
    }

    private func readMediaContentImageView(in root: UIView) -> UIImageView? {
        timelineAllImageViews(in: root)
            .filter { view in
                guard !view.isHidden, let image = view.image else { return false }
                return image.size.width * image.size.height > 1_000
            }
            .max { lhs, rhs in
                let lhsPixels = (lhs.image?.size.width ?? 0) * (lhs.image?.size.height ?? 0)
                let rhsPixels = (rhs.image?.size.width ?? 0) * (rhs.image?.size.height ?? 0)
                return lhsPixels < rhsPixels
            }
    }

    private func renderBrentSVGReadMediaPreviewSnapshot(outputURL: URL) async throws -> UIImage {
        let hostSize = CGSize(width: 360, height: 700)
        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            title: "read /tmp/brent.svg",
            expandedContent: .readMedia(
                output: Self.brentCrudeSVGFromTempDirectory,
                filePath: "/tmp/brent.svg",
                startLine: 1
            , attachments: []),
            toolNamePrefix: "read",
            isExpanded: true
        ))
        view.translatesAutoresizingMaskIntoConstraints = false

        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: hostSize)
        hostController.view.backgroundColor = .systemBackground
        hostController.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: hostController.view.topAnchor),
        ])

        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let ready = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            view.setNeedsLayout()
            view.layoutIfNeeded()
            guard let inlinePreview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: view),
                  let webView = firstToolSubview(ofType: ReviewCommentWKWebView.self, in: inlinePreview),
                  !inlinePreview.isHidden,
                  !webView.isHidden else {
                return false
            }
            let imageReady = try? await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0") as? Bool
            return imageReady == true
                && inlinePreview.bounds.width > 300
                && inlinePreview.bounds.height > 180
                && webView.bounds.width >= inlinePreview.bounds.width - 1
                && webView.bounds.height >= inlinePreview.bounds.height - 1
        }
        #expect(ready, "Expected expanded read-media SVG preview to finish loading before snapshot")

        let inlinePreview = try #require(firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: view))
        let previewFrame = inlinePreview.convert(inlinePreview.bounds, to: hostController.view)
        let screenshot = await waitForPaintedSnapshot(timeoutMs: 3_000) {
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: previewFrame.size).image { _ in
                hostController.view.drawHierarchy(
                    in: CGRect(
                        x: -previewFrame.minX,
                        y: -previewFrame.minY,
                        width: hostSize.width,
                        height: hostSize.height
                    ),
                    afterScreenUpdates: true
                )
            }
        }
        try #require(screenshot.pngData()).write(to: outputURL, options: .atomic)
        return screenshot
    }

    private func renderBrentSVGPreviewSnapshot(outputURL: URL) async throws -> UIImage {
        let previewSize = CGSize(width: 360, height: 210)
        let preview = AnimatedImageWebContainerView(frame: CGRect(origin: .zero, size: previewSize))
        preview.translatesAutoresizingMaskIntoConstraints = false

        let hostController = UIViewController()
        hostController.view.frame = CGRect(origin: .zero, size: previewSize)
        hostController.view.backgroundColor = .systemBackground
        hostController.view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: hostController.view.topAnchor),
            preview.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
        ])

        let window = UIWindow(frame: CGRect(origin: .zero, size: previewSize))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let svgData = Data(Self.brentCrudeSVGFromTempDirectory.utf8)
        let dataURLString = "data:image/svg+xml;base64,\(svgData.base64EncodedString())"
        preview.apply(dataURLString: dataURLString)
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()

        let webView = try #require(firstToolSubview(ofType: ReviewCommentWKWebView.self, in: preview))
        let ready = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            let imageReady = try? await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0") as? Bool
            return imageReady == true
                && webView.bounds.width >= previewSize.width - 1
                && webView.bounds.height >= previewSize.height - 1
        }
        #expect(ready, "Expected SVG web view image to finish loading before snapshot")

        let screenshot = await waitForPaintedSnapshot(timeoutMs: 3_000) {
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: previewSize).image { _ in
                hostController.view.drawHierarchy(
                    in: CGRect(origin: .zero, size: previewSize),
                    afterScreenUpdates: true
                )
            }
        }
        try #require(screenshot.pngData()).write(to: outputURL, options: .atomic)
        return screenshot
    }

    private func waitForPaintedSnapshot(
        timeoutMs: Int,
        pollMs: Int = 50,
        capture: () -> UIImage
    ) async -> UIImage {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
        var latest = capture()
        while ContinuousClock.now < deadline {
            if hasBrightSVGBackgroundPixels(in: latest) {
                return latest
            }
            try? await Task.sleep(for: .milliseconds(pollMs))
            latest = capture()
        }
        return latest
    }

    private func hasBrightSVGBackgroundPixels(in image: UIImage) -> Bool {
        guard let raster = rasterize(image) else { return false }
        var count = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width where raster.pixel(x: x, y: y).isBrightSVGBackground {
                count += 1
                if count > 100 { return true }
            }
        }
        return false
    }

    private func countNonBackgroundPixels(
        in image: UIImage,
        minYFraction: CGFloat,
        maxYFraction: CGFloat
    ) -> Int {
        guard let raster = rasterize(image) else { return 0 }
        let minY = max(0, min(raster.height - 1, Int(CGFloat(raster.height) * minYFraction)))
        let maxY = max(minY, min(raster.height, Int(CGFloat(raster.height) * maxYFraction)))
        var count = 0
        for y in minY..<maxY {
            for x in 0..<raster.width {
                let pixel = raster.pixel(x: x, y: y)
                if pixel.alpha > 200 && (pixel.red < 235 || pixel.green < 235 || pixel.blue < 235) {
                    count += 1
                }
            }
        }
        return count
    }

    private func countBrightBackgroundPixelsNearHorizontalEdges(in image: UIImage) -> Int {
        guard let raster = rasterize(image) else { return 0 }
        let edgeWidth = max(1, Int(CGFloat(raster.width) * 0.06))
        let minY = max(0, Int(CGFloat(raster.height) * 0.25))
        let maxY = min(raster.height, Int(CGFloat(raster.height) * 0.75))
        var count = 0
        for y in minY..<maxY {
            for x in 0..<edgeWidth {
                if raster.pixel(x: x, y: y).isBrightSVGBackground {
                    count += 1
                }
            }
            for x in max(edgeWidth, raster.width - edgeWidth)..<raster.width {
                if raster.pixel(x: x, y: y).isBrightSVGBackground {
                    count += 1
                }
            }
        }
        return count
    }

    private func rasterize(_ image: UIImage) -> RasterImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RasterImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
    }

    private struct RasterImage {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]

        func pixel(x: Int, y: Int) -> Pixel {
            let offset = y * bytesPerRow + x * 4
            return Pixel(
                red: pixels[offset],
                green: pixels[offset + 1],
                blue: pixels[offset + 2],
                alpha: pixels[offset + 3]
            )
        }
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var isBrightSVGBackground: Bool {
            alpha > 200 && red > 245 && green > 240 && blue > 235
        }
    }

    private func firstToolSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstToolSubview(ofType: type, in: subview) { return match }
        }
        return nil
    }

    private actor FetchCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    private actor AttachmentFetchGate {
        let data: Data
        private(set) var fetchCount = 0
        private var continuations: [CheckedContinuation<Data, Never>] = []

        init(data: Data) {
            self.data = data
        }

        func fetch() async -> Data {
            fetchCount += 1
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func release() {
            let waiting = continuations
            continuations.removeAll()
            for continuation in waiting {
                continuation.resume(returning: data)
            }
        }
    }

    // Exact regression fixture copied from `/tmp/brent.svg` after the reported SVG preview failure.
    private static let brentCrudeSVGFromTempDirectory = #"""
<svg xmlns="http://www.w3.org/2000/svg" width="720" height="420" viewBox="0 0 720 420">
  <rect width="100%" height="100%" rx="24" fill="#faf9f6"/>
  <text x="28" y="36" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="22" font-weight="700" fill="#1f2937">Brent Crude (BZ=F)</text>
  <text x="28" y="64" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="16" fill="#374151">Last 113.95  -4.08 (-3.5%)  Apr28 -&gt; May03</text>
  <line x1="72" y1="76" x2="72" y2="366" stroke="#d6d3d1"/>
  <line x1="72" y1="366" x2="692" y2="366" stroke="#d6d3d1"/>
  <text x="18" y="81" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="13" fill="#6b7280">118.82</text>
  <text x="18" y="366" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="13" fill="#6b7280">107.38</text>
  <polyline points="72.0,96.0 278.7,197.9 485.3,346.0 692.0,199.4" fill="none" stroke="#b45309" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="72.0" cy="96.0" r="4" fill="#b45309"><title>Apr28 118.03</title></circle><circle cx="278.7" cy="197.9" r="4" fill="#b45309"><title>Apr29 114.01</title></circle><circle cx="485.3" cy="346.0" r="4" fill="#b45309"><title>Apr30 108.17</title></circle><circle cx="692.0" cy="199.4" r="4" fill="#b45309"><title>May03 113.95</title></circle>
  <text x="72" y="398" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="14" fill="#6b7280">Apr28</text>
  <text x="692" y="398" text-anchor="end" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="14" fill="#6b7280">May03</text>
</svg>
"""#
}

@MainActor
private final class ToolInvalidationCountingLayout: UICollectionViewFlowLayout {
    private(set) var invalidationCount = 0

    override func invalidateLayout() {
        invalidationCount += 1
        super.invalidateLayout()
    }
}

@MainActor
private final class ToolInteractionTrackingCollectionView: UICollectionView {
    var testIsTracking = false

    override var isTracking: Bool { testIsTracking }
}

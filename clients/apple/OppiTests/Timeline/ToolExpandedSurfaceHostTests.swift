import Testing
import UIKit
import WebKit
@testable import Oppi

@Suite("Tool expanded surface host")
@MainActor
struct ToolExpandedSurfaceHostTests {
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
            }
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
            attachmentFetcher: nil
        )

        let visibleLabelText = timelineAllLabels(in: view)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .map(timelineRenderedText)
            .filter { !$0.isEmpty }

        #expect(visibleLabelText.contains(filePath))
        #expect(visibleLabelText.contains("Read image file [image/png]"))
    }

    @Test func readMediaAttachmentImageKeepsUsefulReadNotes() async throws {
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
            attachmentFetcher: { _ in imageData }
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
        #expect(visibleLabelText.contains { $0.contains("original 240x160") })
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
        let outputDirectory = URL(fileURLWithPath: "/Users/chenda/workspace/oppi/.pi/reports/read-media-image-fit", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

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

        let imageRendered = await waitForTimelineCondition(timeoutMs: 2_500) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()
            guard let firstCell = collectionView.cellForItem(at: firstIP),
                  let inlinePreview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: firstCell.contentView),
                  let webView = firstToolSubview(ofType: PiWKWebView.self, in: inlinePreview) else {
                return false
            }
            let imageReady = (try? await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0") as? Bool) == true
            return imageReady && inlinePreview.bounds.height > 180
        }

        #expect(imageRendered, "Expected SVG attachment preview to render and grow beyond the placeholder height")

        let layoutReflowed = await waitForTimelineCondition(timeoutMs: 1_500) { @MainActor in
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
        let outputDirectory = URL(fileURLWithPath: "/Users/chenda/workspace/oppi/.pi/reports/svg-regression", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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
        let outputDirectory = URL(fileURLWithPath: "/Users/chenda/workspace/oppi/.pi/reports/svg-regression", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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

        let ready = await waitForTimelineCondition(timeoutMs: 1_500) { @MainActor in
            container.setNeedsLayout()
            container.layoutIfNeeded()
            return firstToolSubview(ofType: AnimatedImageWebContainerView.self, in: preview) != nil
                && firstToolSubview(ofType: PiWKWebView.self, in: preview) != nil
        }
        #expect(ready)

        let animatedView = try #require(firstToolSubview(ofType: AnimatedImageWebContainerView.self, in: preview))
        let webView = try #require(firstToolSubview(ofType: PiWKWebView.self, in: preview))
        let singleTap = animatedView.gestureRecognizers?.contains {
            guard let tap = $0 as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired == 1
        } ?? false

        #expect(singleTap, "SVG previews should open full screen with one tap, matching static image previews")
        #expect(!webView.isUserInteractionEnabled, "The nested WKWebView should not swallow taps meant for the preview card")
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

        let ready = await waitForTimelineCondition(timeoutMs: 3_500) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            view.setNeedsLayout()
            view.layoutIfNeeded()
            guard let inlinePreview = firstToolSubview(ofType: NativeExpandedInlineImageView.self, in: view),
                  let webView = firstToolSubview(ofType: PiWKWebView.self, in: inlinePreview),
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
        try await Task.sleep(for: .milliseconds(250))
        let screenshot = UIGraphicsImageRenderer(size: previewFrame.size).image { _ in
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

        let webView = try #require(firstToolSubview(ofType: PiWKWebView.self, in: preview))
        let ready = await waitForTimelineCondition(timeoutMs: 2_500) { @MainActor in
            hostController.view.setNeedsLayout()
            hostController.view.layoutIfNeeded()
            let imageReady = try? await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0") as? Bool
            return imageReady == true
                && webView.bounds.width >= previewSize.width - 1
                && webView.bounds.height >= previewSize.height - 1
        }
        #expect(ready, "Expected SVG web view image to finish loading before snapshot")

        try await Task.sleep(for: .milliseconds(250))
        let screenshot = UIGraphicsImageRenderer(size: previewSize).image { _ in
            hostController.view.drawHierarchy(
                in: CGRect(origin: .zero, size: previewSize),
                afterScreenUpdates: true
            )
        }
        try #require(screenshot.pngData()).write(to: outputURL, options: .atomic)
        return screenshot
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

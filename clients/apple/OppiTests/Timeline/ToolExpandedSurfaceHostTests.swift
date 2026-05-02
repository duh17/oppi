import Testing
import UIKit
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
        let voiceView = NativeVoiceMessageView()
        voiceView.apply(
            id: "voice-host-size",
            message: "This final voice transcript should determine the host height immediately when the audio card replaces streaming text, without clipping the lower lines or waiting for a later collection view sizing pass to recover.",
            attachmentId: "att-1",
            mimeType: "audio/wav",
            delivery: .directSpeak,
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

    @Test func readMediaTallInlineImageUsesFullVerticalFitHeight() async throws {
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

        #expect(fitted.height >= 870, "Tall read-tool image should keep its full vertical fit height: \(fitted.height)")
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

        #expect(vertical.imageFrame.height > vertical.imageFrame.width * 2.5)
        #expect(vertical.rowSize.height > horizontal.rowSize.height * 2.0)
        #expect(horizontal.imageFrame.width > horizontal.imageFrame.height * 2.0)
        #expect(FileManager.default.fileExists(atPath: vertical.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: horizontal.outputURL.path))
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
            ),
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
            expandedContent: .readMedia(output: output, filePath: filePath, startLine: 1),
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
            .filter { !$0.isHidden && $0.image != nil }
            .max { lhs, rhs in
                let lhsPixels = (lhs.image?.size.width ?? 0) * (lhs.image?.size.height ?? 0)
                let rhsPixels = (rhs.image?.size.width ?? 0) * (rhs.image?.size.height ?? 0)
                return lhsPixels < rhsPixels
            }
    }

    private func firstToolSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstToolSubview(ofType: type, in: subview) { return match }
        }
        return nil
    }
}

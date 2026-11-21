import Foundation
import UIKit
import Testing
@testable import Oppi

/// A landscape image in a streaming assistant row on the iPad mini: the row
/// must settle at the fitted (width-limited, aspect-correct) height when the
/// image arrives, keep that height true when the row's width changes, and the
/// timeline must still scroll past it.
@Suite("Wide image follow scroll")
@MainActor
struct WideImageFollowScrollTests {
    /// iPad mini portrait, the owner's device: 744 × 1133 pt. The timeline
    /// column is that minus its 16 pt side insets.
    private static let hostSize = CGSize(width: 744, height: 1_133)

    @Test(arguments: [true, false])
    func wideImageSettlesAtFittedHeightWhileFollowing(isStreaming: Bool) async throws {
        let fixture = try WideImageFixture(hostSize: Self.hostSize, streaming: isStreaming)
        defer { fixture.tearDown() }

        // A streaming tick while the image is still in flight reconfigures and
        // re-measures the row, as the stream does.
        try await Task.sleep(for: .milliseconds(60))
        fixture.appendStreamingLine()

        let decoded = await fixture.waitForImage()
        #expect(decoded, "the wide PNG never reached its row; \(fixture.stateSummary())")
        await fixture.settle()

        let row = fixture.rowHeight()
        let cold = try #require(fixture.coldMeasure())
        let image = try #require(fixture.imageGeometry())

        #expect(abs(row - cold) <= 2, "settled row \(row) is not the height a fresh row of the same content takes (\(cold))")
        #expect(abs(image.height - image.fitted) <= 2, "image box \(image.height) is not fitted \(image.fitted)")
        #expect(image.overflow <= 1, "the image overflows its row by \(image.overflow) pt")
        fixture.expectCanScrollPastImageRow()
    }

    @Test(arguments: [true, false])
    func wideImageRefitsWhenTheRowNarrows(isStreaming: Bool) async throws {
        let fixture = try WideImageFixture(hostSize: Self.hostSize, streaming: isStreaming)
        defer { fixture.tearDown() }

        let decoded = await fixture.waitForImage()
        #expect(decoded, "the wide PNG never reached its row; \(fixture.stateSummary())")
        await fixture.settle()

        // The timeline narrows, as the chat does when a pane opens beside it.
        let column = fixture.narrowTimeline(to: 480)
        await fixture.settle()
        let image = try #require(fixture.imageGeometry())

        // The picture fits the column it is now drawn in. The row it sits in
        // is the collection view's to re-measure (`WideImageFixture.coldMeasure`
        // is the height it takes then), so this test owns the picture's box.
        #expect(
            abs(image.height - image.fitted) <= 2,
            "at \(column) pt the picture kept the wider layout's height: box=\(image.height) fitted=\(image.fitted)"
        )
    }
}

/// One windowed timeline: an intro row taller than the screen, the wide image
/// row, and a tail row under it, pinned to the bottom (following the stream).
@MainActor
final class WideImageFixture {
    struct ImageGeometry: CustomStringConvertible {
        let height: CGFloat
        let fitted: CGFloat
        let overflow: CGFloat
        var description: String { "box=\(height) fitted=\(fitted) overflow=\(overflow)" }
    }

    let window: UIWindow
    let collectionView: AnchoredCollectionView
    let fetches: WideImageFetchCounter
    private let dataSource: UICollectionViewDiffableDataSource<Int, String>
    private let configs: WideImageFixtureConfigs
    private let itemIDs = ["msg-intro", "msg-wide", "msg-tail"]
    private let streaming: Bool
    private var imageRowText = """
    Here is the wide panorama you asked for.

    ![Wide panorama](fixtures/wide.png)

    The image is 1600 by 900.
    """

    private static let introText = (1...26)
        .map { "Intro line \($0) keeps the timeline taller than the screen." }
        .joined(separator: "\n\n")

    private static let tailText = "This row sits under the wide image."

    init(hostSize: CGSize, streaming: Bool) throws {
        self.streaming = streaming
        let fetches = WideImageFetchCounter()
        self.fetches = fetches
        let imageData = try Self.wideImageData()
        let window = makeTestWindow(frame: CGRect(origin: .zero, size: hostSize))
        self.window = window
        let collectionView = AnchoredCollectionView(
            frame: CGRect(origin: .zero, size: hostSize),
            collectionViewLayout: ChatTimelineController.makeTestLayout()
        )
        self.collectionView = collectionView
        // The chat's timeline turns this on: a visible row whose content
        // changed a constraint re-measures itself.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let column = ChatTimelineCachedHeightLayout.rowColumn(boundsWidth: hostSize.width).width
        let configs = WideImageFixtureConfigs()
        configs.byItemID = [
            "msg-intro": Self.configuration(text: Self.introText, isStreaming: false, columnWidth: column),
            "msg-wide": Self.configuration(
                text: imageRowText,
                isStreaming: streaming,
                columnWidth: column,
                fetch: { _, _ in
                    await fetches.recordFetch()
                    try await Task.sleep(for: .milliseconds(150))
                    return imageData
                }
            ),
            "msg-tail": Self.configuration(
                text: Self.tailText,
                isStreaming: false,
                columnWidth: column
            ),
        ]
        configs.streamingItemID = streaming ? "msg-wide" : nil
        self.configs = configs

        let registration = UICollectionView.CellRegistration<SafeSizingCell, String> { cell, _, itemID in
            cell.isStreamingAssistant = configs.streamingItemID == itemID
            cell.contentConfiguration = configs.byItemID[itemID]
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: id)
        }
        self.dataSource = dataSource

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(itemIDs)
        dataSource.apply(snapshot, animatingDifferences: false)
        layout()
        collectionView.isDetachedFromBottom = false
        // The image row is the one on screen while the image arrives; the
        // timeline stays attached to its tail (following), not detached.
        collectionView.scrollToItem(at: IndexPath(item: 1, section: 0), at: .centeredVertically, animated: false)
        layout()
    }

    func tearDown() {
        window.isHidden = true
    }

    /// The chat hands each row the width its markdown is laid out at: the row
    /// column inside the assistant bubble's chrome (`assistantMarkdownWidth()`).
    private static func markdownWidth(forColumn columnWidth: CGFloat) -> CGFloat {
        let card = ChatTimelineChromeStyle.standard.assistantBubble
        return columnWidth
            - card.margins.leading - card.margins.trailing
            - card.padding.leading - card.padding.trailing
    }

    private static func configuration(
        text: String,
        isStreaming: Bool,
        columnWidth: CGFloat,
        fetch: ((String, String) async throws -> Data)? = nil
    ) -> AssistantTimelineRowConfiguration {
        var configuration = AssistantTimelineRowConfiguration(
            text: text,
            isStreaming: isStreaming,
            canFork: false,
            onFork: nil,
            resourceAccess: MarkdownResourceAccess(
                identity: .init(
                    workspaceID: "ws-wide",
                    serverBaseURL: URL(string: "https://server.example.com")!
                ),
                fetchWorkspaceFile: fetch
            )
        )
        configuration.markdownWidth = markdownWidth(forColumn: columnWidth)
        return configuration
    }

    private static func wideImageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 900)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 900))
        }
        return try #require(image.pngData())
    }

    private func layout() {
        window.layoutIfNeeded()
        collectionView.layoutIfNeeded()
    }

    private func pinToBottom() {
        let insets = collectionView.adjustedContentInset
        let offset = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        layout()
    }

    private var imageIP: IndexPath { IndexPath(item: 1, section: 0) }
    private var tailIP: IndexPath { IndexPath(item: 2, section: 0) }
    private var columnWidth: CGFloat { collectionView.bounds.width - 32 }

    func appendStreamingLine() {
        guard streaming else { return }
        imageRowText += "\n\nThe decoder is still working on it."
        configs.byItemID["msg-wide"] = Self.configuration(
            text: imageRowText,
            isStreaming: true,
            columnWidth: columnWidth,
            fetch: configs.byItemID["msg-wide"]?.resourceAccess.fetchWorkspaceFile
        )
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(itemIDs)
        snapshot.reconfigureItems(["msg-wide"])
        dataSource.apply(snapshot, animatingDifferences: false)
        layout()
    }

    var imageView: NativeMarkdownImageView? {
        guard let cell = collectionView.cellForItem(at: imageIP),
              let markdown = timelineFirstView(ofType: AssistantMarkdownContentView.self, in: cell.contentView)
        else { return nil }
        return timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdown)
    }

    func waitForImage() async -> Bool {
        await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            self.layout()
            return self.imageView?.debugHasRasterPreviewForTesting == true
        }
    }

    /// Wait for the row to agree with its own content, then land one layout pass.
    func settle() async {
        _ = await waitForTimelineCondition(timeoutMs: 1_500) { @MainActor in
            self.layout()
            guard let rowFrame = self.collectionView.layoutAttributesForItem(at: self.imageIP)?.frame.height,
                  let cold = self.coldMeasure() else { return false }
            return abs(rowFrame - cold) <= 2
        }
        layout()
    }

    func rowHeight() -> CGFloat {
        layout()
        return collectionView.layoutAttributesForItem(at: imageIP)?.frame.height ?? -1
    }

    /// What a freshly configured row of this content takes at the current
    /// column width: the height the owner sees after the row scrolls out of
    /// view and back, and the height the settled row must already have. The
    /// picture comes from the shared cache synchronously, as it does then.
    func coldMeasure() -> CGFloat? {
        guard let config = configs.byItemID["msg-wide"] else { return nil }
        let row = AssistantTimelineRowContentView(configuration: config)
        return row.systemLayoutSizeFitting(
            CGSize(width: columnWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        ).height
    }

    func imageGeometry() -> ImageGeometry? {
        guard let imageView,
              let fitted = imageView.debugFittedHeightForTesting(
                  width: imageView.bounds.width,
                  screenHeight: window.bounds.height
              ),
              let cell = collectionView.cellForItem(at: imageIP),
              let row = timelineFirstView(ofType: AssistantTimelineRowContentView.self, in: cell.contentView)
        else { return nil }
        return ImageGeometry(
            height: imageView.bounds.height,
            fitted: fitted,
            overflow: row.debugMarkdownOverflowPoints
        )
    }

    /// Narrow the timeline, as an attached pane or a rotation does, and return
    /// the column width it now has.
    func narrowTimeline(to width: CGFloat) -> CGFloat {
        var frame = collectionView.frame
        frame.size.width = width
        collectionView.frame = frame
        layout()
        // The chat reconfigures its rows with the new column width.
        for itemID in itemIDs {
            if let text = configs.byItemID[itemID]?.text {
                configs.byItemID[itemID] = Self.configuration(
                    text: text,
                    isStreaming: configs.streamingItemID == itemID,
                    columnWidth: columnWidth,
                    fetch: configs.byItemID[itemID]?.resourceAccess.fetchWorkspaceFile
                )
            }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(itemIDs)
        snapshot.reconfigureItems(itemIDs)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
        layout()
        // The picture the reader is looking at stays on screen across the
        // width change, as it does when a pane opens beside it.
        collectionView.scrollToItem(at: imageIP, at: .centeredVertically, animated: false)
        layout()
        return columnWidth
    }

    func expectCanScrollPastImageRow() {
        layout()
        let insets = collectionView.adjustedContentInset
        let maxOffsetY = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        let imageRow = collectionView.layoutAttributesForItem(at: imageIP)?.frame
        collectionView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
        layout()
        let tailVisible = collectionView.indexPathsForVisibleItems.contains(tailIP)
        let tailFrame = collectionView.layoutAttributesForItem(at: tailIP)?.frame
        #expect(tailVisible, "the tail row under the image is not reachable")
        if let imageRow, let tailFrame {
            #expect(
                tailFrame.maxY <= maxOffsetY + collectionView.bounds.height + 1,
                "the tail row sits past the last reachable offset: tail=\(tailFrame) maxOffset=\(maxOffsetY)"
            )
            #expect(
                imageRow.maxY <= tailFrame.minY + 1,
                "the image row overlaps the row under it: imageRow=\(imageRow) tail=\(tailFrame)"
            )
        }
    }

    func stateSummary() -> String {
        "fetches=\(fetches.count) state=\(imageView?.debugStateForTesting ?? "no image view")"
    }
}

/// The rows a fixture's cells configure, and which one is streaming.
@MainActor
final class WideImageFixtureConfigs {
    var byItemID: [String: AssistantTimelineRowConfiguration] = [:]
    var streamingItemID: String?
}

/// Counts workspace image fetches across the fixture's fetch closure.
final class WideImageFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func recordFetch() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

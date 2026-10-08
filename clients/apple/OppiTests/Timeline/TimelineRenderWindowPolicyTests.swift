import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Timeline render window policy")
struct TimelineRenderWindowPolicyTests {
    @Test func showEarlierControlRemainsVisibleWhenOnlyServerRowsRemain() {
        #expect(TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: true))
        #expect(!TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: false))
    }

    @Test func showEarlierRevealsLocalHiddenRowsBeforeFetchingOlderPage() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 200,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .revealLocal(newWindow: 140))
    }

    @Test func showEarlierFetchesOlderServerPageWhenLocalRowsAreExhausted() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .fetchOlderPage)
    }

    @Test func showEarlierDoesNothingWhenNoLocalOrServerRowsRemain() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: false
        )

        #expect(action == .none)
    }
}

@Suite("Chat timeline chrome overlap")
struct ChatTimelineChromeOverlapTests {
    @Test func topInsetUsesHeaderBottomNotBarHeight() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        let header = CGRect(x: 16, y: 103, width: 358, height: 48)

        #expect(ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) == 151)
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) != header.height,
            "Bar height alone leaves the first rows under the navigation bar"
        )
    }

    @Test func emptyHeaderStillCoversNavigationGap() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Empty context bar: zero height, sitting at the safe-area top below
        // the nav bar while the timeline starts at the window top.
        let emptyHeaderAtSafeArea = CGRect(x: 0, y: 103, width: 390, height: 0)

        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timeline,
                headerFrame: emptyHeaderAtSafeArea
            ) == 103
        )
    }

    @Test func unmeasuredFramesDoNotInventInset() {
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: .zero, headerFrame: .zero) == 0
        )
    }

    /// Hosted under a real navigation bar: the measured overlap alone must
    /// cover the bar and the navigation chrome above it, with no inset read.
    @MainActor
    @Test func overlapFromFramesCoversNavigationChromeAndBar() async {
        let frames = await measureChromeOverlayFrames(hugHeader: true, barHeight: 48)
        let inset = ChatTimelineChromeOverlap.topInset(
            timelineFrame: frames.timeline,
            headerFrame: frames.header
        )
        #expect(
            abs(inset - (frames.safeAreaTop + 48)) < 1,
            "First row must clear the nav and the bar; safeArea=\(frames.safeAreaTop) header=\(frames.header) timeline=\(frames.timeline) inset=\(inset)"
        )
    }
}

@MainActor
@Suite("Chat timeline row column")
struct ChatTimelineRowColumnTests {
    private let margin = ChatTimelineCachedHeightLayout.sectionInsets.leading

    @Test func trailingOnlyInsetNarrowsRowsFromTheTrailingSideOnly() {
        let column = ChatTimelineCachedHeightLayout.rowColumn(
            boundsWidth: 700,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 83)
        )

        #expect(column.x == margin)
        #expect(column.x + column.width == 700 - 83 - margin)
    }

    @Test func leadingOnlyInsetShiftsRowsAndKeepsTheTrailingMargin() {
        let column = ChatTimelineCachedHeightLayout.rowColumn(
            boundsWidth: 700,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 83, bottom: 0, right: 0)
        )

        #expect(column.x == 83 + margin)
        #expect(column.x + column.width == 700 - margin)
    }

    @Test func narrowerThanTheInsetsNeverGoesNegative() {
        let column = ChatTimelineCachedHeightLayout.rowColumn(
            boundsWidth: 100,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 60)
        )

        #expect(column.width == 0)
    }

    @Test func collectionRowsFollowTheRailInsetAsItAppearsAndGoes() throws {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let collectionView = AnchoredCollectionView(
            frame: host.view.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.contentInsetAdjustmentBehavior = .never
        host.view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { _, _, _ in }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(["row"])
        dataSource.apply(snapshot, animatingDifferences: false)

        func rowFrame() throws -> CGRect {
            host.view.layoutIfNeeded()
            collectionView.layoutIfNeeded()
            return try #require(collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        }

        #expect(try rowFrame().maxX == 700 - margin)

        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 83)
        let withRail = try rowFrame()
        #expect(withRail.minX == margin)
        #expect(withRail.maxX == 700 - 83 - margin)

        host.additionalSafeAreaInsets = .zero
        #expect(try rowFrame().maxX == 700 - margin)
    }
}

@MainActor
private struct ChromeOverlayProbe: View {
    let hugHeader: Bool
    let barHeight: CGFloat
    let frames: ChromeOverlayFrames

    var body: some View {
        // Same order as ChatView.chatTimelineScaffold.
        Color.gray
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                frames.timeline = $0
            }
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.orange)
                        .frame(height: barHeight)
                }
                .modifier(ConditionalHuggingHeader(enabled: hugHeader))
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.header = $0
                }
            }
    }
}

private struct ConditionalHuggingHeader: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.modifier(ChatTimelineChromeOverlap.HuggingHeader())
        } else {
            content.frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

@MainActor
private final class ChromeOverlayFrames {
    var timeline: CGRect = .zero
    var header: CGRect = .zero
    var safeAreaTop: CGFloat = 0
}

@MainActor
private func measureChromeOverlayFrames(
    hugHeader: Bool,
    barHeight: CGFloat
) async -> ChromeOverlayFrames {
    let frames = ChromeOverlayFrames()
    let host = UIHostingController(
        rootView: NavigationStack {
            ChromeOverlayProbe(hugHeader: hugHeader, barHeight: barHeight, frames: frames)
                .navigationTitle("Chat")
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { frames.safeAreaTop = proxy.safeAreaInsets.top }
                            .onChange(of: proxy.safeAreaInsets.top) { _, top in
                                frames.safeAreaTop = top
                            }
                    }
                }
        }
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
        window.isHidden = true
        window.rootViewController = nil
    }

    _ = await waitForTimelineCondition(timeoutMs: 800) {
        await MainActor.run {
            host.view.layoutIfNeeded()
            return frames.timeline.height > 400 && frames.header.height > 1 && frames.safeAreaTop > 1
        }
    }
    return frames
}

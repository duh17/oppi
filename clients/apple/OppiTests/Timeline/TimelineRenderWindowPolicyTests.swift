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
        // Named-space overlay: zero-height bar stretched to timeline width,
        // origin at the safe-area top (below the nav bar).
        let emptyHeaderAtSafeArea = CGRect(x: 0, y: 103, width: 390, height: 0)

        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timeline,
                headerFrame: emptyHeaderAtSafeArea
            ) == 103
        )
    }

    @Test func globalFramesBelowNavCollapseToBarHeight() {
        let timelineLaidOutBelowNav = CGRect(x: 0, y: 103, width: 390, height: 741)
        let header = CGRect(x: 16, y: 103, width: 358, height: 48)
        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timelineLaidOutBelowNav,
                headerFrame: header
            ) == header.height,
            "Without a safe-area gap, shared-origin frames are only the bar height"
        )
        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timelineLaidOutBelowNav,
                headerFrame: header,
                safeAreaTop: 103
            ) == 151,
            "Shared-origin frames plus safe area keep the first row below the nav"
        )
    }

    @Test func unmeasuredFramesDoNotInventInset() {
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: .zero, headerFrame: .zero) == 0
        )
    }

    @MainActor
    @Test func namedSpaceBelowNavCollapsesInsetToBarHeight() async {
        let frames = await measureChromeOverlayFrames(hugHeader: true, barHeight: 48)
        let rawInset = ChatTimelineChromeOverlap.topInset(
            timelineFrame: frames.timeline,
            headerFrame: frames.header
        )
        #expect(abs(frames.header.minY - frames.timeline.minY) < 1)
        #expect(
            rawInset < 80,
            "0486bc75 named-space frames share the safe-area origin so inset is only the bar; header=\(frames.header) timeline=\(frames.timeline) inset=\(rawInset)"
        )
        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: frames.timeline,
                headerFrame: frames.header,
                safeAreaTop: frames.safeAreaTop
            ) >= frames.safeAreaTop + 40,
            "Safe-area compensation must keep the first row below the nav; safeArea=\(frames.safeAreaTop) header=\(frames.header)"
        )
    }
}

@MainActor
private struct ChromeOverlayProbe: View {
    let hugHeader: Bool
    let barHeight: CGFloat
    let frames: ChromeOverlayFrames

    var body: some View {
        Color.gray
            .ignoresSafeArea(.container, edges: .top)
            .coordinateSpace(name: ChatTimelineChromeOverlap.coordinateSpaceName)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(ChatTimelineChromeOverlap.coordinateSpaceName))
            } action: {
                frames.timeline = $0
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.orange)
                        .frame(height: barHeight)
                }
                .modifier(ConditionalHuggingHeader(enabled: hugHeader))
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(ChatTimelineChromeOverlap.coordinateSpaceName))
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

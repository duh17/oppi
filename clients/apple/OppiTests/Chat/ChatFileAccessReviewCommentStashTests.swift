import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat file access review comment stash")
@MainActor
struct ChatFileAccessReviewCommentStashTests {
    @Test func stashBottomPaddingStacksOneLeadingAccessory() {
        #expect(
            FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: 0)
                == FullScreenFloatingControlChrome.bottomPadding
        )
        #expect(
            FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: 1)
                == FullScreenFloatingControlChrome.bottomPadding
                + FullScreenFloatingControlChrome.controlSize
                + FullScreenFloatingControlChrome.stackSpacing
        )
        #expect(
            FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: 2)
                == FullScreenFloatingControlChrome.bottomPadding
                + (2 * (
                    FullScreenFloatingControlChrome.controlSize
                        + FullScreenFloatingControlChrome.stackSpacing
                ))
        )
    }

    @Test func gitContextReviewFileShowsStashWhenCommentsAreStaged() async throws {
        let fixture = try makeReviewDetailFixture(stagedCount: 1)
        defer { fixture.window.isHidden = true }

        let appeared = await waitForMainActorCondition {
            fixture.host.view.layoutIfNeeded()
            return stashButton(in: fixture.host.view) != nil
        }
        #expect(appeared)
        let button = try #require(stashButton(in: fixture.host.view))
        #expect(button.accessibilityIdentifier == FullScreenReviewCommentStashControl.accessibilityIdentifier)
        #expect(button.accessibilityLabel == FullScreenReviewCommentStashControl.accessibilityLabel)
        #expect(button.accessibilityValue as? String == "1 staged comment")
    }

    @Test func gitContextReviewFileHidesStashWhenNoCommentsAreStaged() async throws {
        let fixture = try makeReviewDetailFixture(stagedCount: 0)
        defer { fixture.window.isHidden = true }

        _ = await waitForMainActorCondition {
            fixture.host.view.layoutIfNeeded()
            return timelineAllViews(in: fixture.host.view).count > 5
        }
        #expect(stashButton(in: fixture.host.view) == nil)
    }

    @Test func gitContextReviewFileStacksStashAbovePreviousFile() async throws {
        let previous = GitFileStatus(
            status: " M",
            path: "benchmarks/lib/prior.py",
            addedLines: 2,
            removedLines: 0
        ).toReviewFile()
        let current = GitFileStatus(
            status: "??",
            path: "benchmarks/lib/headline.py",
            addedLines: 340,
            removedLines: 0
        ).toReviewFile()
        let fixture = try makeReviewDetailFixture(
            stagedCount: 1,
            file: current,
            navigationFiles: [previous, current]
        )

        let appeared = await waitForMainActorCondition {
            fixture.host.view.layoutIfNeeded()
            return stashButton(in: fixture.host.view) != nil
        }
        #expect(appeared)
        let stash = try #require(stashButton(in: fixture.host.view))
        let stashFrame = stash.convert(stash.bounds, to: fixture.host.view)
        let previousFile = try #require(
            timelineAllViews(in: fixture.host.view).first { view in
                let frame = view.convert(view.bounds, to: fixture.host.view)
                return view !== stash
                    && view.accessibilityIdentifier != FullScreenReviewCommentStashControl.accessibilityIdentifier
                    && abs(frame.width - FullScreenFloatingControlChrome.controlSize) <= 1
                    && abs(frame.height - FullScreenFloatingControlChrome.controlSize) <= 1
                    && abs(frame.minX - stashFrame.minX) <= 8
                    && frame.minY >= stashFrame.maxY - 1
            }
        )
        let previousFrame = previousFile.convert(previousFile.bounds, to: fixture.host.view)
        #expect(stashFrame.maxY <= previousFrame.minY + 1)
        #expect(abs(stashFrame.minX - previousFrame.minX) <= 8)
        fixture.window.isHidden = true
    }

    @Test func commitFileDiffShowsStashWhenCommentsAreStaged() async throws {
        let comments = try makeIsolatedReviewComments(stagedCount: 1)
        let router = ReviewCommentSelectionRouter(dispatch: { _ in }, stash: comments)
        let host = UIHostingController(
            rootView: NavigationStack {
                CommitFileDiffView(
                    workspaceId: "w1",
                    sha: "abc1234",
                    file: GitCommitFileInfo(
                        path: "Sources/App.swift",
                        status: "M",
                        addedLines: 2,
                        removedLines: 1
                    )
                )
                .environment(\.reviewCommentSelectionScope, .activeSession(router))
                .environment(\.theme, ThemeID.dark.appTheme)
                .environment(\.themeID, .dark)
            }
        )
        let window = present(host)
        defer { window.isHidden = true }

        let appeared = await waitForMainActorCondition {
            host.view.layoutIfNeeded()
            return stashButton(in: host.view) != nil
        }
        #expect(appeared)
        let button = try #require(stashButton(in: host.view))
        #expect(button.accessibilityIdentifier == FullScreenReviewCommentStashControl.accessibilityIdentifier)
        #expect(button.accessibilityValue as? String == "1 staged comment")
    }

    @Test func chatFileHostsInstallStashChrome() throws {
        let review = try chatFileAccessSource("Oppi/Features/Review/WorkspaceReviewFileDetailView.swift")
        let commit = try chatFileAccessSource("Oppi/Features/Review/CommitDetailView.swift")
        let files = try chatFileAccessSource("Oppi/Features/FileBrowser/FileBrowserContentView.swift")
        let touched = try chatFileAccessSource(
            "Oppi/Features/Chat/Support/SessionFiles/SessionTouchedFileContentView.swift"
        )
        let panel = try chatFileAccessSource(
            "Oppi/Features/Chat/Support/SessionFiles/ChatFileBrowserPanel.swift"
        )

        #expect(review.contains("fullScreenReviewCommentStashOverlay("))
        #expect(commit.contains("fullScreenReviewCommentStashOverlay("))
        #expect(files.contains("fullScreenReviewCommentStashOverlay("))
        #expect(files.contains("leadingFloatingAccessoryCount:"))
        #expect(touched.contains("fullScreenReviewCommentStashOverlay("))
        #expect(touched.contains("leadingFloatingAccessoryCount:"))
        #expect(panel.contains(".environment(\\.reviewCommentSelectionScope, fileDetailReviewCommentScope)"))
    }
}

@MainActor
private struct ReviewDetailStashFixture {
    let host: UIHostingController<AnyView>
    let window: UIWindow
    let comments: ChatReviewCommentsController
}

@MainActor
private func makeReviewDetailFixture(
    stagedCount: Int,
    file: WorkspaceReviewFile? = nil,
    navigationFiles: [WorkspaceReviewFile] = []
) throws -> ReviewDetailStashFixture {
    let comments = try makeIsolatedReviewComments(stagedCount: stagedCount)
    let router = ReviewCommentSelectionRouter(dispatch: { _ in }, stash: comments)
    let current = file ?? GitFileStatus(
        status: "??",
        path: "benchmarks/lib/headline.py",
        addedLines: 340,
        removedLines: 0
    ).toReviewFile()
    let host = UIHostingController(
        rootView: AnyView(
            NavigationStack {
                WorkspaceReviewFileDetailView(
                    workspaceId: "w1",
                    selectedSessionId: "session-1",
                    file: current,
                    reviewCommentSelectionScopeOverride: .activeSession(router),
                    navigationFiles: navigationFiles
                )
                .environment(SessionStore())
                .environment(\.theme, ThemeID.dark.appTheme)
                .environment(\.themeID, .dark)
            }
        )
    )
    let window = present(host)
    return ReviewDetailStashFixture(host: host, window: window, comments: comments)
}

@MainActor
private func present(_ host: UIViewController) -> UIWindow {
    host.loadViewIfNeeded()
    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window = UIWindow(frame: host.view.frame)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.view.layoutIfNeeded()
    return window
}

@MainActor
private func stashButton(in root: UIView) -> UIView? {
    timelineAllViews(in: root).first { view in
        view.accessibilityIdentifier == FullScreenReviewCommentStashControl.accessibilityIdentifier
            && timelineViewIsVisible(view)
    }
}

@MainActor
private func makeIsolatedReviewComments(stagedCount: Int) throws -> ChatReviewCommentsController {
    let suiteName = "ChatFileAccessReviewCommentStashTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let comments = ChatReviewCommentsController(
        store: ReviewCommentStore(defaults: defaults, keyPrefix: suiteName)
    )
    comments.load(localScopeId: "workspace-1", sessionId: "session-1")
    for index in 0..<stagedCount {
        #expect(comments.save(
            body: "Comment \(index + 1).",
            request: ReviewCommentSelectionRequest(
                selectedText: "payload",
                source: ReviewCommentSourceContext(
                    sessionId: "session-1",
                    surface: .fullScreenCode,
                    filePath: "benchmarks/lib/headline.py"
                )
            ),
            localScopeId: "workspace-1",
            sessionId: "session-1"
        ) == nil)
    }
    return comments
}

private func chatFileAccessSource(_ path: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: path)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

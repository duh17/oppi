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

    /// The stash pops in every reader: a review diff's button springs in when the
    /// first comment is added, and stays still under Reduce Motion.
    @Test(arguments: [false, true])
    func reviewDiffStashPopsWhenACommentIsAddedUnlessReduceMotion(reduceMotion: Bool) throws {
        let fixture = try makeReviewDetailFixture(stagedCount: 0)
        defer { fixture.window.isHidden = true }
        let detail = try #require((fixture.host as? UINavigationController)?.viewControllers.first)
        #expect(stashButton(in: fixture.host.view) == nil)

        // Other suites set this override too, so the update runs synchronously
        // while it holds, with no suspension in between.
        FullScreenReviewCommentStashControl.reduceMotionOverrideForTesting = reduceMotion
        defer { FullScreenReviewCommentStashControl.reduceMotionOverrideForTesting = nil }
        #expect(fixture.comments.save(
            body: "Rename this.",
            request: ReviewCommentSelectionRequest(
                selectedText: "payload",
                source: ReviewCommentSourceContext(sessionId: "session-1", surface: .fullScreenDiff)
            ),
            localScopeId: "workspace-1",
            sessionId: "session-1"
        ) == nil)
        detail.updatePropertiesIfNeeded()
        fixture.host.view.layoutIfNeeded()

        let button = try #require(stashButton(in: fixture.host.view))
        let animations = button.layer.animationKeys() ?? []
        #expect(animations.isEmpty == reduceMotion, "animations: \(animations)")
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

    /// The diff's Viewing Options and the previous and next file are items in
    /// the review's one bar, as in the file viewer: nothing floats over the
    /// diff but the staged-comment button, alone in its corner.
    @Test func gitContextReviewFileKeepsViewingOptionsAndFileSteppingOnItsBar() async throws {
        let files = ["Sources/Prior.swift", "Sources/App.swift", "Sources/Later.swift"].map {
            GitFileStatus(status: " M", path: $0, addedLines: 1, removedLines: 1).toReviewFile()
        }
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard let path = request.url?.path else { return nil }
            if path.hasSuffix("/quick-actions") {
                return try mockJSONResponse(encoding: WorkspaceQuickActionsResponse(actions: []), for: request)
            }
            guard path.hasSuffix("/diff") else { return nil }
            return try mockJSONResponse(json: """
            {"workspaceId": "w1", "path": "Sources/App.swift", "baselineText": "let a = 1",
             "currentText": "let a = 2", "addedLines": 1, "removedLines": 1,
             "hunks": [{"oldStart": 1, "oldCount": 1, "newStart": 1, "newCount": 1, "lines": [
               {"kind": "removed", "text": "let a = 1", "oldLine": 1, "newLine": null, "spans": null},
               {"kind": "added", "text": "let a = 2", "oldLine": null, "newLine": 1, "spans": null}]}]}
            """, for: request)
        })
        defer { routes.end() }
        let fixture = try makeReviewDetailFixture(
            stagedCount: 1,
            file: files[1],
            navigationFiles: files,
            apiClient: makeTestURLProtocolClient()
        )
        defer { fixture.window.isHidden = true }
        let detail = try #require((fixture.host as? UINavigationController)?.topViewController)

        let barIDs = ["fullscreen.viewingOptions.button", "fileViewer.previous", "fileViewer.next"]
        let onBar = await waitForMainActorCondition {
            fixture.host.view.layoutIfNeeded()
            let ids = Set((detail.navigationItem.rightBarButtonItems ?? []).compactMap(\.accessibilityIdentifier))
            return barIDs.allSatisfy(ids.contains)
        }
        #expect(onBar, "bar: \((detail.navigationItem.rightBarButtonItems ?? []).map { $0.accessibilityIdentifier ?? "?" })")
        let floating = timelineAllViews(in: detail.view).filter { view in
            barIDs.contains(view.accessibilityIdentifier ?? "") && timelineViewIsVisible(view)
        }
        #expect(floating.isEmpty, "Nothing but the stash may float over the diff")
        #expect(stashButton(in: fixture.host.view) != nil)
    }

    @Test func commitFileDiffShowsStashWhenCommentsAreStaged() async throws {
        let comments = try makeIsolatedReviewComments(stagedCount: 1)
        let router = ReviewCommentSelectionRouter(dispatch: { _ in }, stash: comments)
        let host = RouterNavigationController(rootViewController: CommitFileDiffViewController(
            configuration: .init(
                workspaceId: "w1",
                sha: "abc1234",
                file: GitCommitFileInfo(
                    path: "Sources/App.swift",
                    status: "M",
                    addedLines: 2,
                    removedLines: 1
                ),
                reviewCommentSelectionScope: .activeSession(router)
            ),
            apiClient: nil
        ))
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

    /// Cancel closes the editor without writing: the staged comment keeps the body it
    /// had, and the next open shows it unchanged.
    @Test func cancellingAnEditLeavesTheStagedCommentAsItWas() throws {
        let comments = try makeIsolatedReviewComments(stagedCount: 1)
        let comment = try #require(comments.stagedComments.first)
        let sheet = ReviewCommentStashViewController(stash: comments, editing: comment, onClose: {})
        let host = UINavigationController(rootViewController: sheet)
        host.traitOverrides.appRootEnvironment = makeTestAppRoot()
        let window = present(host)
        defer { window.isHidden = true }

        let field = try #require(timelineAllViews(in: sheet.view).compactMap { $0 as? UITextView }.first {
            $0.accessibilityLabel == "Review comment text"
        })
        // UIKit calls this from the keyboard; the sheet is hosted without an input session here.
        field.text = comment.body + " Updated"
        field.delegate?.textViewDidChange?(field)
        #expect(sheet.navigationItem.rightBarButtonItem?.isEnabled == true)

        let cancel = try #require(sheet.navigationItem.leftBarButtonItem?.primaryAction)
        cancel.performWithSender(nil, target: nil)
        host.view.layoutIfNeeded()

        #expect(comments.stagedComments.first?.body == comment.body)
    }

    /// Ending an edit hides the editor and empties its sections; the collection view must
    /// agree, or the next layout (keyboard dismissal, rotation) indexes an empty array.
    @Test func endingEditReloadsTheEditorListSoLaterLayoutDoesNotTrap() throws {
        let comments = try makeIsolatedReviewComments(stagedCount: 1)
        let comment = try #require(comments.stagedComments.first)
        let sheet = ReviewCommentStashViewController(stash: comments, editing: comment, onClose: {})
        let host = UINavigationController(rootViewController: sheet)
        host.traitOverrides.appRootEnvironment = makeTestAppRoot()
        let window = present(host)
        let editor = try #require(
            timelineAllViews(in: sheet.view).compactMap { $0 as? UICollectionView }
                .first { $0.dataSource === sheet && $0.numberOfSections > 0 }
        )
        #expect(editor.numberOfSections == 3)

        let cancel = try #require(sheet.navigationItem.leftBarButtonItem?.primaryAction)
        cancel.performWithSender(nil, target: nil)
        host.view.layoutIfNeeded()
        #expect(editor.numberOfSections == 0)

        editor.frame.size.height += 120
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        window.isHidden = true
    }
}

@MainActor
private struct ReviewDetailStashFixture {
    let host: UIViewController
    let window: UIWindow
    let comments: ChatReviewCommentsController
}

@MainActor
private func makeReviewDetailFixture(
    stagedCount: Int,
    file: WorkspaceReviewFile? = nil,
    navigationFiles: [WorkspaceReviewFile] = [],
    apiClient: APIClient? = nil
) throws -> ReviewDetailStashFixture {
    let comments = try makeIsolatedReviewComments(stagedCount: stagedCount)
    let router = ReviewCommentSelectionRouter(dispatch: { _ in }, stash: comments)
    let current = file ?? GitFileStatus(
        status: "??",
        path: "benchmarks/lib/headline.py",
        addedLines: 340,
        removedLines: 0
    ).toReviewFile()
    let detail = WorkspaceReviewFileDetailViewController(
        configuration: .init(
            workspaceId: "w1",
            selectedSessionId: "session-1",
            file: current,
            reviewCommentSelectionScope: .activeSession(router),
            navigationFiles: navigationFiles
        ),
        connection: ServerConnection(),
        apiClient: apiClient,
        navigation: SceneNavigation()
    )
    let host = UINavigationController(rootViewController: detail)
    host.traitOverrides.appRootEnvironment = makeTestAppRoot()
    let window = present(host)
    return ReviewDetailStashFixture(host: host, window: window, comments: comments)
}

@MainActor
private func present(_ host: UIViewController) -> UIWindow {
    host.loadViewIfNeeded()
    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window = makeTestWindow(frame: host.view.frame)
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

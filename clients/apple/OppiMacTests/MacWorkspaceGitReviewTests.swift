import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac workspace git status and review")
struct MacWorkspaceGitReviewTests {

    @Test func decodesWorkspaceGitStatusWithFiles() throws {
        let data = try #"""
        {
          "isGitRepo": true,
          "branch": "feat/mac-app",
          "headSha": "295b493",
          "ahead": 1,
          "behind": 0,
          "dirtyCount": 2,
          "untrackedCount": 1,
          "stagedCount": 1,
          "files": [
            {
              "status": "M ",
              "path": "Sources/App.swift",
              "addedLines": 4,
              "removedLines": 1
            },
            {
              "status": "??",
              "path": "Notes.md",
              "addedLines": null,
              "removedLines": null
            }
          ],
          "totalFiles": 2,
          "addedLines": 4,
          "removedLines": 1,
          "stashCount": 0,
          "lastCommitMessage": "wire catalogs",
          "lastCommitDate": "2026-08-28T12:00:00Z",
          "recentCommits": [
            {
              "sha": "295b493",
              "message": "wire catalogs",
              "date": "2026-08-28T12:00:00Z"
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let status = try MacWorkspaceClient.decodeGitStatus(data)

        #expect(status.isGitRepo)
        #expect(status.branch == "feat/mac-app")
        #expect(status.headSha == "295b493")
        #expect(status.ahead == 1)
        #expect(status.totalFiles == 2)
        #expect(status.files.map(\.path) == ["Sources/App.swift", "Notes.md"])
        #expect(status.files.first?.label == "Modified")
        #expect(status.files.last?.label == "Untracked")
        #expect(status.lastCommitMessage == "wire catalogs")
    }

    @Test func getGitStatusUsesOwnerUnixSocketGitStatusRoute() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"isGitRepo":true,"branch":"main","headSha":"abc1234","ahead":null,"behind":null,"dirtyCount":0,"untrackedCount":0,"stagedCount":0,"files":[],"totalFiles":0,"addedLines":0,"removedLines":0,"stashCount":0,"lastCommitMessage":null,"lastCommitDate":null,"recentCommits":[]}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let status = try await client.getGitStatus(workspaceId: "ws-1", worktreeId: "wt-2")

        #expect(status.branch == "main")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/git/status?worktreeId=wt-2")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(await client.socketPath == "/tmp/oppi-test.sock")
    }

    @Test func getWorkspaceReviewDiffUsesOwnerUnixSocketGitDiffRoute() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"workspaceId":"ws-1","path":"Sources/App.swift","baselineText":"old\n","currentText":"new\n","addedLines":1,"removedLines":1,"hunks":[{"oldStart":1,"oldCount":1,"newStart":1,"newCount":1,"lines":[{"kind":"removed","text":"old","oldLine":1,"newLine":null,"spans":null},{"kind":"added","text":"new","oldLine":null,"newLine":1,"spans":null}]}]}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let diff = try await client.getWorkspaceReviewDiff(
            workspaceId: "ws-1",
            path: "Sources/App.swift"
        )

        #expect(diff.path == "Sources/App.swift")
        #expect(diff.hunks.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/workspaces/ws-1/git/diff?"))
        #expect(request.path.contains("path=Sources/App.swift") || request.path.contains("path=Sources%2FApp.swift"))
        #expect(!request.path.contains("/sessions/"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
    }

    @Test func presentationMapsGitFilesWithoutFlatteningOrReviewComments() {
        let status = Self.gitStatus(files: [
            GitFileStatus(status: "M ", path: "Sources/A.swift", addedLines: 2, removedLines: 1),
            GitFileStatus(status: " D", path: "Sources/B.swift", addedLines: 0, removedLines: 4),
            GitFileStatus(status: "??", path: "Notes.md", addedLines: nil, removedLines: nil),
        ])

        let files = MacWorkspaceGitReviewPresentation.reviewFiles(from: status)

        #expect(files.map(\.path) == ["Sources/A.swift", "Sources/B.swift", "Notes.md"])
        #expect(files.map(\.statusLabel) == ["Modified", "Deleted", "Untracked"])
        #expect(files[0].isStaged)
        #expect(files[1].isUnstaged)
        #expect(files[2].isUntracked)
        #expect(MacWorkspaceGitReviewPresentation.summaryTitle(for: status) == "feat/mac-app")
        #expect(MacWorkspaceGitReviewPresentation.summaryCounts(for: status).contains("3 changed"))
        #expect(MacWorkspaceGitReviewPresentation.summaryCounts(for: status).contains("+2"))
        #expect(
            MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[0])?.path
                == "Sources/A.swift"
        )
        #expect(MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[1]) == nil)
        #expect(
            MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[2])?.id
                == "workspace-file:ws-1:Notes.md"
        )
        #expect(
            MacWorkspaceGitReviewPresentation.diffViewerPlan(workspaceID: "ws-1", file: files[0]).id
                == "workspace-review-diff:ws-1:Sources/A.swift"
        )
        #expect(
            MacWorkspaceGitReviewPresentation.diffViewerPlan(workspaceID: "ws-1", file: files[1]).id
                == "workspace-review-diff:ws-1:Sources/B.swift"
        )
        #expect(MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[0])?.loadsFileBytes == true)
        #expect(MacWorkspaceGitReviewPresentation.diffViewerPlan(workspaceID: "ws-1", file: files[0]).loadsFileBytes == false)
        #expect(MacWorkspaceGitReviewPresentation.emptyMessage.contains("comment") == false)
        #expect(MacWorkspaceGitReviewPresentation.emptyMessage.contains("not wired") == false)
    }

    @Test func presentationMapsFullReviewDiffIntoDocumentColumnDescriptor() {
        let diff = Self.largeDiff(path: "Sources/A.swift", hunkCount: 5, linesPerHunk: 81)
        let clipped = WorkspaceReviewDiffPreviewPlan(diff: diff)

        #expect(clipped.hunks.count == 4)
        #expect(clipped.hunks.allSatisfy { $0.lines.count == 80 })
        #expect(clipped.isTruncated)

        let descriptor = MacWorkspaceGitReviewPresentation.diffDescriptor(from: diff)
        guard case .diff(let payload) = descriptor else {
            Issue.record("Expected a document-column diff descriptor")
            return
        }
        let rows = MacToolDocumentDiffLayout.rows(from: payload)

        #expect(payload.path == "Sources/A.swift")
        #expect(payload.lines.count == 5 * 81)
        #expect(payload.lines.first?.text == "h0-l0")
        #expect(payload.lines.last?.text == "h4-l80")
        #expect(payload.lines.first?.kind == .added)
        #expect(payload.lines.first?.newLineNumber == 1)
        #expect(rows.count == 5 * 81)
        #expect(MacToolDocumentColumnPaint.surface(for: descriptor) == .diff)
        #expect(!MacToolDocumentColumnPaint.paintsDiffAsPlaintextDump)
    }

    @Test func refreshAndDeletedFileClearAStaleDocumentColumn() {
        let files = MacWorkspaceGitReviewPresentation.reviewFiles(
            from: Self.gitStatus(files: [
                GitFileStatus(status: "M ", path: "Sources/A.swift", addedLines: 2, removedLines: 1),
                GitFileStatus(status: " D", path: "Sources/B.swift", addedLines: 0, removedLines: 4),
            ])
        )
        let diffPlan = MacWorkspaceGitReviewPresentation.diffViewerPlan(workspaceID: "ws-1", file: files[0])
        let deletedDiffPlan = MacWorkspaceGitReviewPresentation.diffViewerPlan(workspaceID: "ws-1", file: files[1])
        let filePlan = MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[0])
        let deletedFilePlan = FileViewerPlan.workspaceFile(workspaceID: "ws-1", path: "Sources/B.swift")
        let otherWorkspace = FileViewerPlan.workspaceReviewDiff(workspaceID: "ws-2", path: "Sources/A.swift")
        let hostPlan = FileViewerPlan.hostFile(path: "/tmp/Notes.md")

        #expect(MacWorkspaceGitReviewPresentation.fileViewerPlan(workspaceID: "ws-1", file: files[1]) == nil)
        #expect(deletedDiffPlan.id == "workspace-review-diff:ws-1:Sources/B.swift")
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                diffPlan,
                workspaceID: "ws-1",
                reviewFiles: files
            )
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                deletedDiffPlan,
                workspaceID: "ws-1",
                reviewFiles: []
            )
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                deletedFilePlan,
                workspaceID: "ws-1",
                reviewFiles: files
            )
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                filePlan,
                workspaceID: "ws-1",
                reviewFiles: files
            ) == false
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                otherWorkspace,
                workspaceID: "ws-1",
                reviewFiles: files
            ) == false
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                hostPlan,
                workspaceID: "ws-1",
                reviewFiles: files
            ) == false
        )
        #expect(
            MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
                nil,
                workspaceID: "ws-1",
                reviewFiles: files
            ) == false
        )
    }

    @Test func presentationKeepsDisabledAndMissingRepoPhases() {
        #expect(
            MacWorkspaceGitReviewPresentation.phase(
                gitStatusEnabled: false,
                isLoading: false,
                gitStatus: nil,
                error: nil
            ) == .disabled
        )
        #expect(
            MacWorkspaceGitReviewPresentation.phase(
                gitStatusEnabled: true,
                isLoading: true,
                gitStatus: nil,
                error: nil
            ) == .loading
        )
        #expect(
            MacWorkspaceGitReviewPresentation.phase(
                gitStatusEnabled: true,
                isLoading: false,
                gitStatus: GitStatus.empty,
                error: nil
            ) == .notGitRepo
        )
        #expect(
            MacWorkspaceGitReviewPresentation.phase(
                gitStatusEnabled: true,
                isLoading: false,
                gitStatus: nil,
                error: "boom"
            ) == .unavailable("boom")
        )
    }

    @Test func storeLoadsStatusAndOpensOneFileDiffWithoutFlattening() async throws {
        let first = Self.diff(path: "Sources/A.swift", hunkStart: 1, text: "first-file")
        let second = Self.diff(path: "Sources/B.swift", hunkStart: 40, text: "second-file")
        let client = FakeMacWorkspaceGitReviewClient(
            status: Self.gitStatus(files: [
                GitFileStatus(status: "M ", path: "Sources/A.swift", addedLines: 1, removedLines: 0),
                GitFileStatus(status: "M ", path: "Sources/B.swift", addedLines: 1, removedLines: 0),
            ]),
            diffsByPath: [
                "Sources/A.swift": first,
                "Sources/B.swift": second,
            ]
        )
        let store = MacWorkspaceGitReviewStore()

        await store.loadStatus(workspaceId: "ws-1", gitStatusEnabled: true, client: client)
        #expect(store.gitStatus?.branch == "feat/mac-app")
        #expect(store.reviewFiles.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(store.selectedDiff == nil)

        await store.selectFile("Sources/A.swift", client: client)
        #expect(store.selectedPath == "Sources/A.swift")
        #expect(store.selectedDiff?.path == "Sources/A.swift")
        guard case .diff(let firstPayload) = store.selectedDiffDescriptor else {
            Issue.record("Expected the selected review diff to map into ToolContentDescriptor.Diff")
            return
        }
        #expect(firstPayload.path == "Sources/A.swift")
        #expect(firstPayload.lines.map(\.text) == ["first-file"])
        #expect(store.selectedDiffViewerPlan?.id == "workspace-review-diff:ws-1:Sources/A.swift")
        #expect(store.selectedFileViewerPlan?.id == "workspace-file:ws-1:Sources/A.swift")

        await store.selectFile("Sources/B.swift", client: client)
        guard case .diff(let secondPayload) = store.selectedDiffDescriptor else {
            Issue.record("Expected the second review diff to replace the first file")
            return
        }
        #expect(store.selectedDiff?.path == "Sources/B.swift")
        #expect(secondPayload.lines.map(\.text) == ["second-file"])
        #expect(secondPayload.lines.map(\.text).contains("first-file") == false)
        #expect(store.selectedDiffViewerPlan?.id == "workspace-review-diff:ws-1:Sources/B.swift")
        #expect(await client.requestedDiffPaths == ["Sources/A.swift", "Sources/B.swift"])
        #expect(MacWorkspaceGitReviewPresentation.keepsSingleFileDiff(
            selectedPath: "Sources/B.swift",
            diff: try #require(store.selectedDiff)
        ))

        await store.loadStatus(workspaceId: "ws-1", gitStatusEnabled: true, client: client)
        #expect(store.selectedDiff == nil)
        #expect(store.selectedDiffDescriptor == nil)
        #expect(store.selectedDiffViewerPlan == nil)
    }

    @Test func storeReloadsGitStatusAndDiffsForTheSelectedWorktree() async throws {
        let client = FakeMacWorkspaceGitReviewClient(
            status: Self.gitStatus(files: [
                GitFileStatus(status: "M ", path: "Sources/A.swift", addedLines: 1, removedLines: 0),
            ]),
            diffsByPath: [
                "Sources/A.swift": Self.diff(path: "Sources/A.swift", hunkStart: 1, text: "first-file"),
            ]
        )
        let store = MacWorkspaceGitReviewStore()

        await store.loadStatus(
            workspaceId: "ws-1",
            worktreeId: WorkspaceWorktree.mainId,
            gitStatusEnabled: true,
            client: client
        )
        await store.selectFile("Sources/A.swift", client: client)
        #expect(store.selectedPath == "Sources/A.swift")

        await store.loadStatus(
            workspaceId: "ws-1",
            worktreeId: "wt_feature",
            gitStatusEnabled: true,
            client: client
        )
        #expect(store.selectedPath == nil)
        #expect(store.selectedDiff == nil)

        await store.selectFile("Sources/A.swift", client: client)

        #expect(await client.requestedStatusWorktreeIds == [WorkspaceWorktree.mainId, "wt_feature"])
        #expect(await client.requestedDiffWorktreeIds == [WorkspaceWorktree.mainId, "wt_feature"])
        #expect(await client.requestedDiffPaths == ["Sources/A.swift", "Sources/A.swift"])
    }

    @Test func storeSkipsFetchWhenGitStatusIsDisabled() async {
        let client = FakeMacWorkspaceGitReviewClient(
            status: Self.gitStatus(files: [
                GitFileStatus(status: "M ", path: "Sources/A.swift", addedLines: 1, removedLines: 0),
            ]),
            diffsByPath: [:]
        )
        let store = MacWorkspaceGitReviewStore()

        await store.loadStatus(workspaceId: "ws-1", gitStatusEnabled: false, client: client)

        #expect(store.gitStatus == nil)
        #expect(store.statusError == nil)
        #expect(store.isLoadingStatus == false)
        #expect(await client.statusCalls == 0)
        #expect(
            MacWorkspaceGitReviewPresentation.phase(
                gitStatusEnabled: false,
                isLoading: store.isLoadingStatus,
                gitStatus: store.gitStatus,
                error: store.statusError
            ) == .disabled
        )
    }

    @Test func workspaceShellHostsGitStatusAndOpensFileOrDiff() throws {
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let view = try source(named: "OppiMac/Views/MacWorkspaceGitStatusView.swift")
        let store = try source(named: "OppiMac/Stores/MacWorkspaceGitReviewStore.swift")
        let client = try source(named: "OppiMac/Networking/MacWorkspaceClient.swift")

        #expect(shell.contains("MacWorkspaceGitStatusView("))
        #expect(shell.contains("openPlan"))
        #expect(shell.contains("openDescriptor"))
        #expect(shell.contains("loadsFileBytes"))
        #expect(!shell.contains("ReviewComment"))
        #expect(!shell.contains("Leave a comment"))

        #expect(view.contains("Open diff"))
        #expect(view.contains("Open file") || view.contains("Open File"))
        #expect(view.contains("selectedDiffDescriptor") || view.contains("diffDescriptor"))
        #expect(view.contains("diffViewerPlan") || view.contains("selectedDiffViewerPlan"))
        #expect(view.contains("shouldClearOpenPlanAfterRefresh"))
        #expect(view.contains("accessibilityIdentifier"))
        #expect(!view.contains("WorkspaceReviewDiffPreviewPlan"))
        #expect(!view.contains("MacWorkspaceGitDiffPreview"))
        #expect(!view.contains("MacDiffOutputModel"))
        #expect(!view.contains("ReviewComment"))
        #expect(!view.contains("Leave a comment"))
        #expect(!view.contains("fullScreenCover"))
        #expect(!view.contains("WindowGroup"))
        #expect(!view.contains(".sheet("))

        #expect(store.contains("ToolContentDescriptor"))
        #expect(store.contains("diffDescriptor"))
        #expect(store.contains("diffViewerPlan"))
        #expect(store.contains("getWorkspaceReviewDiff"))
        #expect(store.contains("getGitStatus"))
        #expect(store.contains("worktreeId: worktreeId") || store.contains("worktreeId: normalizedWorktreeId"))
        #expect(!store.contains("worktreeId: nil"))
        #expect(view.contains("let worktreeId: String"))
        #expect(view.contains("worktreeId: worktreeId"))
        #expect(view.contains("\\(workspace.id):\\(worktreeId)"))
        #expect(shell.contains("worktreeId: selectedWorktreeId"))
        #expect(!store.contains("WorkspaceReviewDiffPreviewPlan"))
        #expect(!store.contains("MacDiffOutputModel"))
        #expect(!store.contains("ReviewComment"))

        #expect(client.contains("/git/status"))
        #expect(client.contains("/git/diff"))
        #expect(client.contains("decodeGitStatus"))
    }

    private static func gitStatus(files: [GitFileStatus]) -> GitStatus {
        GitStatus(
            isGitRepo: true,
            branch: "feat/mac-app",
            headSha: "295b493",
            ahead: 1,
            behind: 0,
            dirtyCount: files.filter { !$0.toReviewFile().isUntracked }.count,
            untrackedCount: files.filter { $0.toReviewFile().isUntracked }.count,
            stagedCount: files.filter { $0.toReviewFile().isStaged }.count,
            files: files,
            totalFiles: files.count,
            addedLines: files.compactMap(\.addedLines).reduce(0, +),
            removedLines: files.compactMap(\.removedLines).reduce(0, +),
            stashCount: 0,
            lastCommitMessage: "wire catalogs",
            lastCommitDate: "2026-08-28T12:00:00Z",
            recentCommits: [
                GitCommitSummary(sha: "295b493", message: "wire catalogs", date: "2026-08-28T12:00:00Z"),
            ]
        )
    }

    private static func diff(path: String, hunkStart: Int, text: String) -> WorkspaceReviewDiffResponse {
        WorkspaceReviewDiffResponse(
            workspaceId: "ws-1",
            path: path,
            baselineText: "",
            currentText: text + "\n",
            addedLines: 1,
            removedLines: 0,
            hunks: [
                WorkspaceReviewDiffHunk(
                    oldStart: hunkStart,
                    oldCount: 0,
                    newStart: hunkStart,
                    newCount: 1,
                    lines: [
                        WorkspaceReviewDiffLine(
                            kind: .added,
                            text: text,
                            oldLine: nil,
                            newLine: hunkStart,
                            spans: nil
                        ),
                    ]
                ),
            ],
            revisionCount: nil,
            cacheKey: nil
        )
    }

    private static func largeDiff(path: String, hunkCount: Int, linesPerHunk: Int) -> WorkspaceReviewDiffResponse {
        WorkspaceReviewDiffResponse(
            workspaceId: "ws-1",
            path: path,
            baselineText: "",
            currentText: "",
            addedLines: hunkCount * linesPerHunk,
            removedLines: 0,
            hunks: (0..<hunkCount).map { hunkIndex in
                let start = hunkIndex * 100 + 1
                return WorkspaceReviewDiffHunk(
                    oldStart: start,
                    oldCount: 0,
                    newStart: start,
                    newCount: linesPerHunk,
                    lines: (0..<linesPerHunk).map { lineIndex in
                        WorkspaceReviewDiffLine(
                            kind: .added,
                            text: "h\(hunkIndex)-l\(lineIndex)",
                            oldLine: nil,
                            newLine: start + lineIndex,
                            spans: nil
                        )
                    }
                )
            },
            revisionCount: nil,
            cacheKey: nil
        )
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

actor FakeMacWorkspaceGitReviewClient: MacWorkspaceGitReviewing {
    var status: GitStatus
    var diffsByPath: [String: WorkspaceReviewDiffResponse]
    private(set) var statusCalls = 0
    private(set) var requestedDiffPaths: [String] = []
    private(set) var requestedStatusWorktreeIds: [String?] = []
    private(set) var requestedDiffWorktreeIds: [String?] = []

    init(status: GitStatus, diffsByPath: [String: WorkspaceReviewDiffResponse]) {
        self.status = status
        self.diffsByPath = diffsByPath
    }

    func getGitStatus(workspaceId: String, worktreeId: String?) async throws -> GitStatus {
        statusCalls += 1
        requestedStatusWorktreeIds.append(worktreeId)
        return status
    }

    func getWorkspaceReviewDiff(
        workspaceId: String,
        path: String,
        selectedSessionId: String?,
        worktreeId: String?
    ) async throws -> WorkspaceReviewDiffResponse {
        requestedDiffPaths.append(path)
        requestedDiffWorktreeIds.append(worktreeId)
        guard let diff = diffsByPath[path] else {
            throw MacWorkspaceClientError.server(status: 404, message: "missing \(path)")
        }
        return diff
    }
}

private extension Optional where Wrapped == Data {
    func unwrap() throws -> Data {
        guard let self else { throw TestDataError.invalidUTF8 }
        return self
    }
}

private enum TestDataError: Error {
    case invalidUTF8
}

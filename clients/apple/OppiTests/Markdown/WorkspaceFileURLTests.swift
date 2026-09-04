import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("WorkspaceFileURL worktree identity")
struct WorkspaceFileURLTests {
    private let baseURL = URL(string: "https://server.example.com")!

    @Test func relativePathWithoutWorktreeOmitsQuery() throws {
        let url = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png"
        ))

        #expect(url.absoluteString == "https://server.example.com/workspaces/ws-1/raw/relative.png")
        let parsed = try #require(WorkspaceFileURL.parse(url))
        #expect(parsed.workspaceID == "ws-1")
        #expect(parsed.filePath == "relative.png")
        #expect(parsed.worktreeId == nil)
    }

    @Test func worktreeIdQueryRoundTrips() throws {
        let url = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "docs/chart.png",
            worktreeId: "wt_feature"
        ))

        #expect(url.path == "/workspaces/ws-1/raw/docs/chart.png")
        let worktree = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "worktreeId" })?
            .value
        #expect(worktree == "wt_feature")

        let parsed = try #require(WorkspaceFileURL.parse(url))
        #expect(parsed.workspaceID == "ws-1")
        #expect(parsed.filePath == "docs/chart.png")
        #expect(parsed.worktreeId == "wt_feature")
    }

    @Test(arguments: [String?.none, "main", "", "   ", " main "])
    func nilMainAndBlankWorktreeOmitQuery(worktreeId: String?) throws {
        let url = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png",
            worktreeId: worktreeId
        ))

        #expect(url.query == nil)
        #expect(url.absoluteString == "https://server.example.com/workspaces/ws-1/raw/relative.png")
        let parsed = try #require(WorkspaceFileURL.parse(url))
        #expect(parsed.worktreeId == nil)
    }

    @Test func distinctWorktreesDoNotShareURLIdentity() throws {
        let urlA = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png",
            worktreeId: "wt_a"
        ))
        let urlB = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png",
            worktreeId: "wt_b"
        ))

        #expect(urlA != urlB)
        #expect((urlA as NSURL) != (urlB as NSURL))
        #expect(WorkspaceFileURL.parse(urlA)?.worktreeId == "wt_a")
        #expect(WorkspaceFileURL.parse(urlB)?.worktreeId == "wt_b")
    }

    @Test func nilAndMainShareURLIdentity() throws {
        let urlNil = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png",
            worktreeId: nil
        ))
        let urlMain = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: "ws-1",
            filePath: "relative.png",
            worktreeId: "main"
        ))

        #expect(urlNil == urlMain)
        #expect((urlNil as NSURL) == (urlMain as NSURL))
    }

    @Test func parseNormalizesMainQueryToNil() throws {
        let url = try #require(URL(string: "https://server.example.com/workspaces/ws-1/raw/relative.png?worktreeId=main"))
        let parsed = try #require(WorkspaceFileURL.parse(url))
        #expect(parsed.worktreeId == nil)
    }

    @Test func parseAcceptsLegacyFilesRouteWithoutWorktree() throws {
        let url = try #require(URL(string: "https://server.example.com/workspaces/ws-1/files/docs/chart.png"))
        let parsed = try #require(WorkspaceFileURL.parse(url))
        #expect(parsed.workspaceID == "ws-1")
        #expect(parsed.filePath == "docs/chart.png")
        #expect(parsed.worktreeId == nil)
    }
}

@Suite("FlatSegment image worktree identity")
struct FlatSegmentImageWorktreeIdentityTests {
    private let baseURL = URL(string: "https://server.example.com")!
    private let workspaceID = "ws-1"

    @Test func relativeImagesFromTwoWorktreesDoNotShareURLIdentity() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "relative.png")])
        ]
        let urlA = imageURL(
            from: FlatSegment.build(
                from: blocks,
                workspaceID: workspaceID,
                serverBaseURL: baseURL,
                worktreeId: "wt_a"
            )
        )
        let urlB = imageURL(
            from: FlatSegment.build(
                from: blocks,
                workspaceID: workspaceID,
                serverBaseURL: baseURL,
                worktreeId: "wt_b"
            )
        )

        #expect(urlA != nil)
        #expect(urlB != nil)
        #expect(urlA != urlB)
        #expect(urlA.flatMap(WorkspaceFileURL.parse)?.worktreeId == "wt_a")
        #expect(urlB.flatMap(WorkspaceFileURL.parse)?.worktreeId == "wt_b")
    }

    @Test func nilWorktreeOmitsQueryOnRelativeImage() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "relative.png")])
        ]
        let url = imageURL(
            from: FlatSegment.build(
                from: blocks,
                workspaceID: workspaceID,
                serverBaseURL: baseURL
            )
        )
        #expect(url?.query == nil)
        #expect(url.flatMap(WorkspaceFileURL.parse)?.worktreeId == nil)
    }

    @Test func slashTildeAndFileSourcesStayHostImagesWhenWorktreeIsPresent() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Abs", source: "/tmp/chart.png")]),
            .paragraph([.image(alt: "Home", source: "~/chart.png")]),
            .paragraph([.image(alt: "File", source: "file:///tmp/chart.png")]),
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            worktreeId: "wt_feature"
        )
        let urls = segments.compactMap { segment -> URL? in
            if case .image(_, let url) = segment { return url }
            return nil
        }
        #expect(urls.count == 3)
        #expect(urls.allSatisfy { WorkspaceFileURL.parse($0) == nil })
        #expect(HostFileURL.parse(urls[0]) == "/tmp/chart.png")
        #expect(HostFileURL.parse(urls[1]) == "~/chart.png")
        #expect(HostFileURL.parse(urls[2]) == "/tmp/chart.png")
    }

    private func imageURL(from segments: [FlatSegment]) -> URL? {
        for segment in segments {
            if case .image(_, let url) = segment {
                return url
            }
        }
        return nil
    }
}

@Suite("NativeMarkdownImageView worktree cache identity")
@MainActor
struct NativeMarkdownImageWorktreeCacheTests {
    @Test func sameWorkspacePathUnderTwoWorktreesDoesNotReuseCache() async throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let workspaceID = "ws-cache-\(UUID().uuidString)"
        let urlA = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: workspaceID,
            filePath: "relative.png",
            worktreeId: "wt_a"
        ))
        let urlB = try #require(WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: workspaceID,
            filePath: "relative.png",
            worktreeId: "wt_b"
        ))
        #expect(urlA != urlB)
        #expect((urlA as NSURL) != (urlB as NSURL))

        let pngA = try #require(Self.makeSolidImage(color: .red).pngData())
        let pngB = try #require(Self.makeSolidImage(color: .green).pngData())
        let fetches = FetchCounter()

        let viewA = NativeMarkdownImageView()
        viewA.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
        viewA.layoutIfNeeded()
        viewA.apply(
            url: urlA,
            alt: "A",
            fetchWorkspaceFile: { workspace, path in
                fetches.record(urlA)
                #expect(workspace == workspaceID)
                #expect(path == "relative.png")
                return pngA
            },
            fetchSessionFile: nil
        )

        let loadedA = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            timelineAllImageViews(in: viewA).contains { !$0.isHidden && $0.image != nil }
        }
        #expect(loadedA, "First worktree image should load")
        #expect(fetches.count == 1)

        let viewB = NativeMarkdownImageView()
        viewB.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
        viewB.layoutIfNeeded()
        viewB.apply(
            url: urlB,
            alt: "B",
            fetchWorkspaceFile: { workspace, path in
                fetches.record(urlB)
                #expect(workspace == workspaceID)
                #expect(path == "relative.png")
                return pngB
            },
            fetchSessionFile: nil
        )

        let loadedB = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            timelineAllImageViews(in: viewB).contains { !$0.isHidden && $0.image != nil }
        }
        #expect(loadedB, "Second worktree image should load instead of reusing the first cache entry")
        #expect(fetches.count == 2, "Distinct worktree URLs must not share NativeMarkdownImageView cache identity")
        #expect(Set(fetches.urls) == [urlA, urlB])
    }

    private static func makeSolidImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
    }
}

private final class FetchCounter: @unchecked Sendable {
    private(set) var urls: [URL] = []
    var count: Int { urls.count }

    func record(_ url: URL) {
        urls.append(url)
    }
}

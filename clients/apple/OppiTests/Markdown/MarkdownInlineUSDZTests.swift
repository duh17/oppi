import Foundation
import Testing
@testable import Oppi

@Suite("Markdown inline USDZ contract")
struct MarkdownInlineUSDZTests {
    @Test("embed syntax produces USDZ while ordinary wiki syntax stays a link")
    func syntaxAndSourcePolicy() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let segments = FlatSegment.build(
            from: parseCommonMark("![[models/scene.usdz]]\n\n[[models/scene.usdz]]\n\n![[notes/readme.md]]"),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let models = usdzEmbeds(in: segments)
        #expect(models.count == 1)
        #expect(models.first?.reference.fileCandidatePath == "models/scene.usdz")
        #expect(models.first?.reference.kind == .workspaceFile)

        let renderedText = segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let uniqueLinkTargets = Set(renderedText.flatMap { $0.runs.compactMap(\.link) })
        #expect(uniqueLinkTargets.count == 2)
        #expect(!renderedText.map { String($0.characters) }.joined().contains("!"))
        #expect(segments.allSatisfy { if case .image = $0 { return false }; return true })
        #expect(segments.allSatisfy { if case .video = $0 { return false }; return true })
        #expect(segments.allSatisfy { if case .audio = $0 { return false }; return true })
    }

    @Test("markdown bang USDZ embeds the same native node as wiki bang")
    func markdownBangUSDZEmbedsLikeWikiBang() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let wiki = build("![[scene.usdz]]", baseURL: baseURL)
        let markdown = build("![x](scene.usdz)", baseURL: baseURL)
        let hostMarkdown = build("![x](/tmp/scene.usdz)", baseURL: baseURL)

        let wikiModels = usdzEmbeds(in: wiki.segments)
        let markdownModels = usdzEmbeds(in: markdown.segments)
        let hostModels = usdzEmbeds(in: hostMarkdown.segments)
        #expect(wikiModels.count == 1)
        #expect(markdownModels.count == 1)
        #expect(hostModels.count == 1)
        #expect(wikiModels.first?.reference.fileCandidatePath == "scene.usdz")
        #expect(markdownModels.first?.reference.fileCandidatePath == "scene.usdz")
        #expect(markdownModels.first?.reference.kind == .workspaceFile)
        #expect(hostModels.first?.reference.kind == .hostFile)
        #expect(hostModels.first?.reference.fileCandidatePath == "/tmp/scene.usdz")
        #expect(markdown.segments.allSatisfy { if case .image = $0 { return false }; return true })
    }

    @Test("remote USDZ markdown bang, LAN, data, attachment, and HTML make no USDZ and no image fetch URL")
    func remoteAndUnsafeTargetsNeverBecomeUSDZOrLoadableImage() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let markdown = """
        ![x](https://example.com/a.usdz)

        ![x](http://192.168.1.20/a.usdz)

        ![x](data:model/vnd.usdz+zip;base64,AAAA)

        ![x](attachment:stored-usdz)

        ![[https://example.com/demo.usdz]]
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )
        #expect(usdzEmbeds(in: segments).isEmpty)
        #expect(segments.allSatisfy { segment in
            if case .video = segment { return false }
            if case .audio = segment { return false }
            return true
        })
        let imageURLs = segments.compactMap { segment -> URL? in
            guard case .image(_, let url) = segment else { return nil }
            return url
        }
        #expect(imageURLs.isEmpty)
    }

    @Test("host files are eligible but blend and glb never embed")
    func sourcePolicyRejectsNonUSDZAndUnsafeTargets() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let markdown = """
        ![[/tmp/demo.usdz]]

        ![[models/scene.blend]]

        ![[models/scene.glb]]
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let models = usdzEmbeds(in: segments)
        #expect(models.count == 1)
        #expect(models.first?.reference.kind == .hostFile)
        #expect(models.first?.reference.fileCandidatePath == "/tmp/demo.usdz")
    }

    private final class FetchFlag: @unchecked Sendable {
    var value = false
}

    private func usdzEmbeds(in segments: [FlatSegment]) -> [MarkdownUSDZEmbed] {
        segments.compactMap { segment in
            guard case .usdz(let embed) = segment else { return nil }
            return embed
        }
    }

    @Test("export uses a static card and does not fetch")
    @MainActor
    func exportUsesStaticCardWithoutFetching() throws {
        let embed = try makeEmbed("![[models/scene.usdz]]")
        let fetched = FetchFlag()
        let view = NativeMarkdownUSDZView()
        view.bounds = CGRect(x: 0, y: 0, width: 240, height: 10)
        view.apply(
            embed: embed,
            fileProvider: { _ in
                fetched.value = true
                throw CocoaError(.fileNoSuchFile)
            },
            renderingMode: .export,
            preferredDisplayWidth: 240
        )
        #expect(view.isStaticFallback)
        #expect(!fetched.value)
        #expect(view.reservedHeight == 240)
        view.prepareForRemoval()
    }

    @Test("prepareForRemoval cancels a pending load")
    @MainActor
    func prepareForRemovalCancelsPendingLoad() async throws {
        let embed = try makeEmbed("![[models/scene.usdz]]")
        let view = NativeMarkdownUSDZView()
        view.apply(
            embed: embed,
            fileProvider: { _ in
                try await Task.sleep(for: .seconds(30))
                throw CocoaError(.fileNoSuchFile)
            },
            renderingMode: .live,
            preferredDisplayWidth: 200
        )
        view.prepareForRemoval()
        #expect(view.debugIsInteractingForTesting == false)
    }

    @Test("reserved geometry is 1:1")
    func reservedGeometryIsSquare() {
        #expect(MarkdownInlineUSDZLayout.reservedHeight(forWidth: 180) == 180)
        #expect(MarkdownInlineUSDZLayout.reservedHeight(forWidth: 320) == 320)
    }

    private func makeEmbed(_ markdown: String) throws -> MarkdownUSDZEmbed {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let embed = usdzEmbeds(in: build(markdown, baseURL: baseURL).segments).first
        return try #require(embed)
    }

    private func build(_ markdown: String, baseURL: URL) -> FlatSegment.BuildResult {
        FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            mergeAdjacentTextSegments: false
        )
    }
}

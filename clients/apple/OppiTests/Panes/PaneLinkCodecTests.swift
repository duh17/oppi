import Foundation
import Testing
@testable import Oppi

/// `protocol/links.json`: every vector decodes to its route or error and
/// re-encodes to its canonical form, and the canonical form decodes back to
/// the same link.
@Suite("PaneLinkCodec")
struct PaneLinkCodecTests {
    struct Fixture: Decodable {
        let version: Int
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        struct Route: Decodable {
            let kind: String
            let id: String?
            let workspace: String?
            let worktree: String?
            let origin: String?
            let session: String?
            let path: String?
            let line: Int?
            let sha: String?
            let url: String?
            let project: String?
        }

        struct Failure: Decodable {
            let code: String
            let detail: String?
        }

        let name: String
        let input: String
        let server: String?
        let route: Route?
        let canonical: String?
        let error: Failure?
        let notPaneLink: Bool?
    }

    static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("links.json"))
    }

    @Test func everyVectorDecodesAndReencodes() throws {
        let fixture = try Self.fixture()
        #expect(fixture.version == 1)
        for vector in fixture.vectors {
            let url = try #require(URL(string: vector.input), "\(vector.name): input is not a URL")
            let decoded = PaneLinkCodec.decode(url)
            if vector.notPaneLink == true {
                #expect(decoded == nil, "\(vector.name)")
            } else if let failure = vector.error {
                #expect(decoded == .failure(try Self.error(failure)), "\(vector.name)")
            } else {
                let expected = PaneLink(server: vector.server, route: try Self.route(try #require(vector.route, "\(vector.name)")))
                #expect(decoded == .success(expected), "\(vector.name)")
                let canonical = try #require(vector.canonical, "\(vector.name): no canonical form")
                #expect(PaneLinkCodec.encode(expected)?.absoluteString == canonical, "\(vector.name)")
                let reparsed = try #require(URL(string: canonical))
                #expect(PaneLinkCodec.decode(reparsed) == .success(expected), "\(vector.name): canonical form decodes differently")
            }
        }
    }

    @Test func localAndUnsupportedRoutesHaveNoLink() {
        #expect(PaneLinkCodec.encode(PaneLink(server: nil, route: .local(PaneLocalToken(raw: "outline")))) == nil)
        #expect(PaneLinkCodec.encode(PaneLink(server: nil, route: .unsupported(kind: "web", raw: ["web": .string("https://example.com")]))) == nil)
    }

    // MARK: Vector shapes

    static func route(_ value: Vector.Route) throws -> PaneRoute {
        func field(_ name: String, _ field: String?) throws -> String {
            try #require(field, "route \(value.kind) needs \(name)")
        }
        switch value.kind {
        case "sessions": return .sessions(workspace: value.workspace)
        case "session": return .session(try field("id", value.id))
        case "thread": return .thread(try field("id", value.id))
        case "file":
            let origin: PaneFileOrigin = switch value.origin {
            case "workspace": .workspace(id: try field("workspace", value.workspace), worktree: value.worktree)
            case "host": .host
            case "session": .session(try field("session", value.session))
            default: throw VectorError.unknown("file origin \(value.origin ?? "nil")")
            }
            return .file(origin, path: try field("path", value.path), line: value.line)
        case "files" where value.origin == "host": return .hostFiles(path: value.path)
        case "files": return .files(workspace: try field("workspace", value.workspace), path: value.path)
        case "git": return .git(workspace: try field("workspace", value.workspace), worktree: value.worktree)
        case "commit": return .commit(workspace: try field("workspace", value.workspace), sha: try field("sha", value.sha))
        case "panel": return .panel(session: try field("session", value.session), id: try field("id", value.id))
        case "browser": return .browser(try #require(URL(string: try field("url", value.url))))
        case "godot": return .godot(project: try field("project", value.project))
        default: throw VectorError.unknown("route kind \(value.kind)")
        }
    }

    static func error(_ value: Vector.Failure) throws -> PaneLinkError {
        let detail = value.detail ?? ""
        switch value.code {
        case "missing": return .missing(detail)
        case "unknownParameter": return .unknownParameter(detail)
        case "duplicateParameter": return .duplicateParameter(detail)
        case "invalidValue": return .invalidValue(detail)
        case "unexpectedPath": return .unexpectedPath
        case "unexpectedComponent": return .unexpectedComponent(detail)
        case "conflictingOrigin": return .conflictingOrigin
        default: throw VectorError.unknown("error code \(value.code)")
        }
    }

    enum VectorError: Error {
        case unknown(String)
    }
}

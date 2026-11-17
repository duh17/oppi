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
        struct Failure: Decodable {
            let code: String
            let detail: String?
        }

        let name: String
        let input: String
        let server: String?
        let route: PaneRoute?
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
                let expected = PaneLink(server: vector.server, route: try #require(vector.route, "\(vector.name)"))
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

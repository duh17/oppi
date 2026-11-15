import Foundation
import Testing
@testable import Oppi

/// The pages a link or a layout may name (build plan §1.10): the app reads a
/// layout's `web` leaf as the server does, a host in any spelling the server
/// reads as loopback is loopback here too, and a paired server's own origin
/// is never a page.
@Suite("PaneWebAddress")
struct PaneWebAddressTests {
    private struct Fixture: Decodable {
        struct Vector: Decodable {
            struct Problem: Decodable {
                let code: String
                let path: String
            }

            let name: String
            /// Absent on vectors given as raw text.
            let input: JSONValue?
            let problems: [Problem]?
        }

        let vectors: [Vector]
    }

    /// Every `web` leaf in `protocol/layouts/vectors.json`: the app accepts
    /// the ones the server accepts, and refuses the others for the same reason.
    @Test func everyLayoutVectorsWebLeafGetsTheServersAnswer() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("layouts/vectors.json"))
        var checked = 0
        for vector in fixture.vectors {
            guard case .object(let document) = vector.input, let root = document["root"] else { continue }
            for (path, web) in Self.webLeaves(root, path: "root") {
                let problem = vector.problems?.first { $0.path == "\(path).web" }
                let result = PaneWebAddress.check(web)
                switch problem?.code {
                case nil: #expect(result == .success(try #require(URL(string: web))), "\(vector.name)")
                case "webScheme": #expect(result == .failure(.scheme), "\(vector.name)")
                case "webUserInfo": #expect(result == .failure(.userInfo), "\(vector.name)")
                case "webLoopback": #expect(result == .failure(.loopback), "\(vector.name)")
                case "tooLong": #expect(result == .failure(.tooLong), "\(vector.name)")
                case let code?: Issue.record("\(vector.name): no Swift reading of \(code)")
                }
                checked += 1
            }
        }
        #expect(checked >= 12, "the vectors hold the web cases (\(checked) found)")
    }

    /// The server reads hosts as a browser does; these reach this device's
    /// loopback, so a link naming them would open a different page per device.
    @Test func loopbackInEverySpellingIsRefused() {
        for address in [
            "http://127.1:5173/", "http://2130706433/", "http://0x7f.0.0.1/", "http://127.255.255.254/",
            "http://[0:0:0:0:0:0:0:1]/", "http://[::ffff:7f00:1]/", "http://Dev.LocalHost/",
        ] {
            #expect(PaneWebAddress.check(address) == .failure(.loopback), "\(address)")
        }
        for address in ["http://128.0.0.1/", "http://10.0.0.127/", "http://[::2]/", "http://cafe.be/", "http://localhost.example.com/"] {
            #expect(PaneWebAddress.check(address).isSuccess, "\(address) is not loopback")
        }
    }

    @Test func theLimitIsTwoKibibytesOfUTF8() {
        let prefix = "https://example.com/"
        let fits = prefix + String(repeating: "é", count: (PaneWebAddress.maximumBytes - prefix.utf8.count) / 2)
        #expect(PaneWebAddress.check(fits).isSuccess)
        #expect(PaneWebAddress.check(fits + "é") == .failure(.tooLong))
    }

    @Test func aPairedServersOwnOriginIsNoPage() throws {
        let servers = [(host: "Mac-Studio.local", port: 7749), (host: "100.64.0.7", port: 443)]
        func refused(_ address: String) throws -> Bool {
            PaneWebAddress.refusesServerPage(try #require(URL(string: address)), method: "GET", servers: servers)
        }
        #expect(try refused("https://mac-studio.local:7749/files/current"))
        #expect(try refused("http://mac-studio.local.:7749/"), "either scheme, and a trailing dot")
        #expect(try refused("https://100.64.0.7/"), "https without a port is 443")
        #expect(try !refused("http://mac-studio.local:5173/"), "a dev server on the same Mac is another origin")
        #expect(try !refused("http://100.64.0.7/"), "http without a port is 80")
    }

    /// A Godot web build's signed play link opens at a paired server's origin;
    /// nothing else there does, however much it looks like one.
    @Test func aGodotPlayLinkIsTheOnePageAtAServersOrigin() throws {
        let servers = [(host: "mac-studio.tail1234.ts.net", port: 7749)]
        let origin = "https://mac-studio.tail1234.ts.net:7749"
        let grant = "a8b5f2bbe966dbad.1794870526.RG0_x-toodG0gRNJfZn4NPB-uyBDi5gi33q9VMMrmF0"
        func refused(_ path: String, method: String = "GET") throws -> Bool {
            PaneWebAddress.refusesServerPage(try #require(URL(string: origin + path)), method: method, servers: servers)
        }
        #expect(try !refused("/godot/spark-d76024f1/play/\(grant)/"))
        #expect(try !refused("/godot/spark-d76024f1/play/\(grant)"), "before the server's redirect to the folder")
        #expect(try !refused("/godot/spark-d76024f1/play/\(grant)/index.html"))

        #expect(try refused("/godot/spark-d76024f1/play/\(grant)/", method: "POST"), "GET only")
        #expect(try refused("/godot/spark-d76024f1/web/a8b5f2bbe966dbad/"), "the paired clients' address")
        #expect(try refused("/godot/spark-d76024f1/play/\(grant)/../../../sessions"))
        #expect(try refused("/godot/spark-d76024f1/play/\(grant)/%2E%2E/%2E%2E/%2E%2E/sessions"))
        #expect(try refused("/godot/spark-d76024f1/play/\(grant)/..%2F..%2Fsessions"))
        #expect(try refused("/godot/../play/\(grant)/"))
        #expect(try refused("/godot/spark-d76024f1/play/not-a-grant/"))
        #expect(try refused("/x/godot/spark-d76024f1/play/\(grant)/"))
        #expect(try refused("/sessions"))
    }

    private static func webLeaves(_ node: JSONValue, path: String) -> [(String, String)] {
        guard case .object(let object) = node else { return [] }
        if case .string(let web)? = object["web"] { return [(path, web)] }
        guard case .array(let children)? = object["children"] else { return [] }
        return children.enumerated().flatMap { webLeaves($0.element, path: "\(path).children[\($0.offset)]") }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

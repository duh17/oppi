import Foundation
import Testing
import UIKit
@testable import Oppi

/// A `tiles` node in a drawer's cards, over a server: each tile is the Pinned screen's tile view,
/// named by its words and identified by its id, and a place the server says is gone reads as a
/// gone pin does.
@Suite("Extension surface tiles", .serialized)
@MainActor
struct ExtensionSurfaceTilesTests {
    /// The fixture's report is gone (a 404), its notes are there, its game is there by the name
    /// "Tide Pool", and its subagent's record does not answer: only a 404 says a place is gone.
    private nonisolated static func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "path" }?.value
        let (status, headers): (Int, [String: String]) = switch (url.path, path) {
        case ("/files/current", "docs/notes.md"):
            (200, ["Content-Type": "text/markdown", "Content-Length": "6", "Last-Modified": "Mon, 16 Nov 2026 18:00:00 GMT"])
        case ("/sessions/child-session-1", _):
            (500, ["Content-Type": "application/json"])
        case ("/godot/tide-3fa9c2b1", _):
            (200, ["Content-Type": "application/json"])
        default:
            (404, ["Content-Type": "application/json"])
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        let body = switch (status, url.path) {
        case (200, "/godot/tide-3fa9c2b1"):
            #"{"id":"tide-3fa9c2b1","name":"Tide Pool","engine":{"name":"godot","version":"4.7"},"release":null,"players":[],"releases":[],"logNext":0}"#
        case (200, _): request.httpMethod == "HEAD" ? "" : "# Plan"
        default: #"{"error":"Not found"}"#
        }
        return (Data(body.utf8), response)
    }

    @Test func tilesDrawAsPinnedTilesAndAGonePlaceSaysNotFound() async throws {
        let scope = TestURLProtocol.routeScope { request in try Self.answer(request) }
        let serverId = "sha256:tiles-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let window = makeAppRootWindow(root)
        defer { window.isHidden = true }
        let host = UIViewController()
        window.rootViewController = host
        let cards = ExtensionSurfaceCompositesView()
        cards.server = ExtensionSurfaceServer(id: serverId, connection: root.coordinator.connection(for: serverId))
        cards.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(cards)
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: host.view.topAnchor),
            cards.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 28),
            cards.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -28),
        ])
        let surface = try JSONDecoder().decode(
            ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/blocks-tiles.json")
        )
        cards.apply(surface: surface, pending: nil, themeID: .dark, onAction: nil)
        window.layoutIfNeeded()

        let prefix = "extension.surface.blocks_2dtiles.shelf."
        func tile(_ id: String) -> UIControl? {
            descendants(of: cards).compactMap { $0 as? UIControl }
                .first { $0.accessibilityIdentifier == prefix + ExtensionSurfaceIdentity.key(id) }
        }
        #expect(await settles(in: window) {
            tile("file:report")?.accessibilityLabel == "report.pdf, Not found"
                // A game tile without a title shows the game's own name, as the server reads it.
                && tile("game:tide")?.accessibilityLabel.map { $0.hasPrefix("Tide Pool, ") } == true
        })
        let report = try #require(tile("file:report"))
        #expect(!report.isEnabled && report.accessibilityTraits.contains(.notEnabled), "a gone place opens nothing")
        #expect(descendants(of: report).contains { $0 is PinTileView }, "the Pinned screen's own tile view")

        // A tile's own words win over the place's; a failed read that is not a 404 is not gone.
        let notes = try #require(tile("file:notes"))
        #expect(notes.accessibilityLabel == "Notes, Changed 2 times")
        #expect(notes.isEnabled)
        let review = try #require(tile("session:child"))
        #expect(review.accessibilityLabel == "Review")
        #expect(review.isEnabled)

        // Tiles share their row's width and the Pinned screen's proportions, in every group.
        window.layoutIfNeeded()
        let height = PinTileView.height(forWidth: report.bounds.width, traits: report.traitCollection)
        #expect(abs(report.bounds.width - notes.bounds.width) < 0.5)
        #expect(abs(report.bounds.width - review.bounds.width) < 0.5)
        #expect(abs(report.bounds.height - height) < 1)
        _ = await scope.settle()
        scope.end()
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Waits for `condition`, running a layout pass each time as the app's display commits do: a
    /// sleeping test runs none, so a view's property pass for an arrived preview waits otherwise.
    private func settles(in window: UIWindow, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        window.layoutIfNeeded()
        return condition()
    }
}

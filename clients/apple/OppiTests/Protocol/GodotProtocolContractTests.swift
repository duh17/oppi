import Foundation
import Testing
@testable import Oppi

/// `protocol/godot.json`: every Godot pane body and link message. Server `godot-fixtures.test.ts`
/// holds the committed bytes to `server/src/types/godot.ts`; this side decodes every example from
/// the same bytes and round-trips what the app sends.
@Suite("Godot protocol contract")
struct GodotProtocolContractTests {
    private struct Fixture: Decodable {
        struct Link: Decodable {
            struct AuthRenew: Decodable {
                let request: JSONValue
                let results: [JSONValue]
            }

            let player: [JSONValue]
            let server: [JSONValue]
            let authRenew: AuthRenew
        }

        let capability: String
        let projectList: GodotProjectList
        let projectDetail: GodotProjectDetail
        let logPage: GodotLogPage
        let commandRequests: [GodotCommandRequest]
        let commandResults: [GodotCommandResult]
        let capture: GodotCapture
        let link: Link
    }

    private static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("godot.json"))
    }

    private static func reencode<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func capabilityMatchesTheApp() throws {
        #expect(try Self.fixture().capability == ClientCapability.godotPane)
    }

    @Test func readsProjectsWithAndWithoutABuild() throws {
        let projects = try Self.fixture().projectList.projects
        let tide = try #require(projects.first)
        #expect(tide.engine.name == GodotEngine.godotName)
        #expect(tide.source?.root == "games/tide")
        #expect(tide.release?.packs.first?.format == .pck)
        #expect(tide.release?.reload == .scene)
        #expect(tide.players.first?.state.phase == .running)
        #expect(tide.players.first?.state.viewport?.scale == 2)

        #expect(projects[1].release == nil, "No build yet")
        #expect(projects[1].source?.worktreeId == "wt-feature")
        let published = projects[2]
        #expect(published.source == nil)
        #expect(published.release?.origin == "publish")
        #expect(published.release?.packs.map(\.format) == [.pck, .zip], "Base first, then the patch")
        #expect(published.release?.entry?.args == ["--level=2"])
    }

    @Test func readsTheDetailLogsAndCapture() throws {
        let fixture = try Self.fixture()
        #expect(fixture.projectDetail.project.id == "tide-3fa9c2b1")
        #expect(fixture.projectDetail.releases.map(\.seq) == [7, 6])
        #expect(fixture.projectDetail.logNext == 412)
        #expect(try Self.reencode(fixture.projectDetail) == fixture.projectDetail)

        let error = try #require(fixture.logPage.entries.last)
        #expect(error.level == .error)
        #expect(error.source == GodotSourceLocation(file: "res://player.gd", line: 42, function: "_physics_process"))
        #expect(error.backtrace?.count == 2)
        #expect(error.release == 7, "A player's line names the release it came from")
        #expect(fixture.logPage.entries.first?.origin == "server")

        #expect(fixture.capture.mimeType == "image/png")
    }

    @Test func renewsLinkAccessLikeEveryDeviceStream() throws {
        let renew = try Self.fixture().link.authRenew
        // The app sends the same frame it sends on its other streams.
        let sent = try JSONDecoder().decode(JSONValue.self, from: Data(try StreamAuthRenewal.requestFrame(token: "at_example-access-token").utf8))
        #expect(sent == renew.request)
        let results = try renew.results.map { try Self.decode(GodotLinkServerMessage.self, $0) }
        guard case .authRenewResult(let renewed) = results.first, case .authRenewResult(let refused) = results.last else {
            Issue.record("expected auth_renew_result")
            return
        }
        #expect(renewed == .renewed(expiresAt: Date(timeIntervalSince1970: 1_794_679_920)))
        #expect(refused == .refused(reason: "wrong_device"))
    }

    @Test func readsEveryCommandAnswerAsItsOutput() throws {
        let results = try Self.fixture().commandResults
        func output<T: Decodable>(_ id: String, _ type: T.Type) throws -> T {
            let result = try #require(results.first { $0.id == id })
            #expect(result.ok)
            return try Self.decode(T.self, try #require(result.output))
        }
        #expect(try output("c-11", GodotCaptureOutput.self).width == 1488)
        #expect(try output("c-12", GodotReloadOutput.self).tier == .scripts)
        #expect(try output("c-13", GodotInputOutput.self).steps == 5)
        #expect(try output("c-14", GodotPickOutput.self).node?.source?.line == 18)
        #expect(try output("c-15", GodotTreeOutput.self).root.children?.count == 1)
        #expect(try output("c-16", GodotNodeOutput.self).properties?["visible"] == .bool(true))
        #expect(try output("c-17", GodotPerfOutput.self).drawCalls == 38)
        #expect(try output("c-18", GodotStateOutput.self).state.phase == .paused)
        #expect(try output("c-19", GodotStepOutput.self).frames == 1)

        let failures = results.filter { !$0.ok }
        #expect(failures.map(\.error?.code) == [.timeout, .noPlayer, .unsupported, .notFound])
        #expect(failures.allSatisfy { $0.output == nil })
    }

    @Test func controllerRequestsRoundTrip() throws {
        let requests = try Self.fixture().commandRequests
        #expect(requests.first?.command == .capture(captureId: nil, maxSize: nil))
        guard case .input(let steps) = requests[1].command else {
            Issue.record("expected input")
            return
        }
        #expect(steps.count == 5)
        #expect(!steps.contains { if case .unsupported = $0 { true } else { false } })
        for request in requests { #expect(try Self.reencode(request) == request) }
    }

    @Test func everyServerMessageDecodesToAKnownCase() throws {
        let messages = try Self.fixture().link.server.map { try Self.decode(GodotLinkServerMessage.self, $0) }
        for message in messages {
            if case .unknown(let type) = message { Issue.record("unknown message \(type)") }
            if case .command(let command) = message, case .unsupported(let name) = command.command {
                Issue.record("unknown command \(name)")
            }
        }
        let commands = messages.compactMap { if case .command(let c) = $0 { c.command.name } else { nil } }
        #expect(Set(commands) == ["capture", "input", "reload", "run", "stop", "pause", "resume", "step", "pick", "tree", "node", "perf"])
        #expect(messages.contains { if case .command(let c) = $0 { c.command == .capture(captureId: "cap-11", maxSize: nil) } else { false } })
        #expect(messages.contains { if case .cancel(id: "c-20") = $0 { true } else { false } })
    }

    @Test func playerMessagesRoundTripThroughTheirOwnEncoding() throws {
        let messages = try Self.fixture().link.player.map { try Self.decode(GodotLinkPlayerMessage.self, $0) }
        #expect(messages.count == 7)
        guard case .attach(let attach) = messages.first else {
            Issue.record("attach must come first")
            return
        }
        #expect(attach.capabilities == [ClientCapability.godotPane])
        #expect(messages.contains { if case .state(let s) = $0 { s.phase == .error && s.tier == .restart } else { false } })
        for message in messages { #expect(try Self.reencode(message) == message) }
    }

    @Test func unknownVocabularyStillDecodes() throws {
        let json = #"{"type":"command","id":"c-1","timeoutMs":5000,"command":{"name":"teleport","to":[1,2]}}"#
        let message = try JSONDecoder().decode(GodotLinkServerMessage.self, from: Data(json.utf8))
        #expect(message == .command(.init(id: "c-1", command: .unsupported(name: "teleport"), timeoutMs: 5000)))
        let state = try JSONDecoder().decode(GodotPlayerState.self, from: Data(#"{"phase":"warming"}"#.utf8))
        #expect(state.phase.rawValue == "warming")
        let future = try JSONDecoder().decode(GodotLinkServerMessage.self, from: Data(#"{"type":"hint"}"#.utf8))
        #expect(future == .unknown(type: "hint"))
    }
}

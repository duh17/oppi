import Foundation
import Testing
@testable import Oppi

/// `protocol/screens.json`: the plugin screen vocabulary and `WS /screens/stream`, from the
/// server's real MCP pages. Server `screens-fixtures.test.ts` holds the committed bytes to
/// `server/src/types/screens.ts`; this side decodes every page and frame from the same bytes,
/// applies one watch's frames in order, and encodes what the app sends.
@Suite("Plugin screen protocol contract")
struct PluginScreenProtocolTests {
    private struct Fixture: Decodable {
        let serverInfo: JSONValue
        let pages: [String: JSONValue]
        let client: [JSONValue]
        let server: [JSONValue]
    }

    private static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("screens.json"))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func info(_ serverInfo: JSONValue) throws -> ServerInfo {
        guard case .object(var fields) = serverInfo else { throw CocoaError(.coderReadCorrupt) }
        // The rest of a real `/server/info`, which the fixture leaves out.
        let base: [String: JSONValue] = [
            "name": .string("host"), "version": .string("1.0.0"), "uptime": .number(1), "os": .string("darwin"),
            "arch": .string("arm64"), "hostname": .string("host"), "nodeVersion": .string("v24"),
            "piVersion": .string("1"), "configVersion": .number(2), "identity": .null,
            "stats": .object([
                "workspaceCount": .number(0), "activeSessionCount": .number(0), "totalSessionCount": .number(0),
                "skillCount": .number(0), "modelCount": .number(0),
            ]),
        ]
        fields.merge(base) { current, _ in current }
        return try decode(ServerInfo.self, .object(fields))
    }

    @Test func serverInfoListsTheEntriesThisAppDraws() throws {
        let info = try Self.info(try Self.fixture().serverInfo)
        #expect(info.capabilities?.screens?.v == PluginScreens.version)
        let entries = try #require(info.appCapabilities?.pluginSidebar)
        #expect(entries.map(\.id) == info.sidebar?.map(\.id))
        // An entry with a workspace scope names its switch, which Workspace Settings finds it by.
        let workspace = try #require(entries.first { $0.scopes.contains("workspace") })
        #expect(workspace.feature.flatMap(ServerFeature.init(rawValue:)) != nil)
        // The switches ride along: every feature on in the fixture.
        let capabilities = try #require(info.appCapabilities)
        #expect(ServerFeature.allCases.allSatisfy { info.features?[$0.rawValue] == true })
        #expect(ServerFeature.allCases.filter { $0 != .godotPane }.allSatisfy(capabilities.offers))

        // Another vocabulary hides them all.
        guard case .object(var fields) = try Self.fixture().serverInfo else { return }
        fields["capabilities"] = .object(["screens": .object(["v": .number(Double(PluginScreens.version + 1))])])
        let newer = try Self.info(.object(fields))
        #expect(newer.sidebar?.isEmpty == false)
        #expect(newer.appCapabilities?.pluginSidebar == nil)
    }

    @Test func everyPageDecodesWithEveryRowKind() throws {
        let pages = try Self.fixture().pages.mapValues { try Self.decode(PluginScreenPage.self, $0) }
        let kinds = Set(pages.values.flatMap { $0.sections.flatMap { $0.rows.map(\.kind) } })
        #expect(kinds == ["item", "value", "text", "toggle", "choice", "button", "field"])
        let add = try #require(pages["add"])
        #expect(add.submit?.action == "add")
        #expect(add.submit?.requires?.isEmpty == false)
        #expect(add.sections.compactMap(\.when).map(\.is).contains("stdio"))
        // A choice's options carry what each one means, for the footer.
        let choices = add.sections.flatMap(\.rows).filter { $0.kind == "choice" }
        #expect(choices.contains { $0.options?.allSatisfy { $0.footer?.isEmpty == false } == true })
        #expect(pages["loading"]?.state?.kind == "loading")
        #expect(pages["failed"]?.state?.kind == "failed")
        let toggle = try #require(pages["http"]?.sections.flatMap(\.rows).first { $0.kind == "toggle" })
        #expect(toggle.boolValue == true)
        // A searchable list whose items lead with a symbol, and file rows that open host files.
        #expect(pages.values.contains { $0.search?.prompt.isEmpty == false })
        let items = pages.values.flatMap { $0.sections.flatMap(\.rows) }.filter { $0.kind == "item" }
        #expect(items.contains { $0.symbol != nil })
        #expect(items.contains { $0.file?.hasPrefix("/") == true })
    }

    @Test func oneWatchsFramesRebuildItsPages() throws {
        let fixture = try Self.fixture()
        let messages = try fixture.server.map { try Self.decode(PluginScreenServerMessage.self, $0) }
        var replica = PluginScreenReplica()
        var shown: [PluginScreenPage] = []
        for message in messages {
            if let page = try replica.apply(message) { shown.append(page) }
        }
        let expected = try ["loading", "list", "listDuringSignIn"].map {
            try Self.decode(PluginScreenPage.self, try #require(fixture.pages[$0]))
        }
        #expect(shown == expected)

        var results: [String: PluginScreenNav?] = [:]
        var ended: [String: String] = [:]
        var refused: [String] = []
        for message in messages {
            switch message {
            case let .result(call, _, _, nav): results[call] = nav
            case let .ended(watch, reason): ended[watch] = reason
            case let .failed(_, text): refused.append(text)
            default: break
            }
        }
        #expect(results["c3"] == PluginScreenNav(kind: "pop"))
        #expect(results["c4"] == PluginScreenNav(kind: "present", page: "signin"))
        #expect(ended == ["w2": "gone", "w3": "off", "w4": "unsupported"])
        #expect(refused.count == 1)
    }

    @Test func whatTheAppSendsMatchesTheServersFrames() throws {
        let sent: [PluginScreenClientMessage] = [
            .watch(watch: "w1", entry: "oppi.mcp", scope: "server", page: "list"),
            .act(watch: "w2", call: "c1", action: "enabled", row: "enabled", values: [
                PluginScreenValue(field: "enabled", value: .bool(false)),
            ]),
            .act(watch: "w3", call: "c2", action: "add", row: nil, values: [
                PluginScreenValue(field: "name", value: .string("docs")),
                PluginScreenValue(field: "transport", value: .string("http")),
                PluginScreenValue(field: "url", value: .string("https://example.test/mcp")),
            ]),
            .unwatch(watch: "w1"),
        ]
        let encoded = try sent.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        #expect(encoded == (try Self.fixture().client))
    }
}

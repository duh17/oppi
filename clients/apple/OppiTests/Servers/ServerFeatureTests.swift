import Foundation
import Testing
@testable import Oppi

/// The server's feature switches (`features` in `/server/info`) as each surface that hides a
/// feature reads them. Plain Pi is every switch off.
@Suite("Server feature switches")
@MainActor
struct ServerFeatureTests {
    private static let plainPi = Dictionary(uniqueKeysWithValues: ServerFeature.allCases.map { ($0.rawValue, false) })

    private static func capabilities(features: [String: Bool]?) -> ServerInfo.Capabilities {
        var capabilities = ServerInfo.Capabilities(
            sessionStream: .init(version: 1), dictationStream: nil, appEventStream: .init(version: 1), extensionNativeUI: nil
        )
        capabilities.features = features
        return capabilities
    }

    @Test("A server without switches offers everything")
    func serversWithoutSwitchesOfferEverything() {
        let older = Self.capabilities(features: nil)
        #expect(ServerFeature.allCases.allSatisfy(older.offers))
        // A switch this app does not know about changes nothing it reads.
        #expect(Self.capabilities(features: ["voice": false]).offers(.terminal))
    }

    @Test("Plain Pi turns every feature off, and one switch brings back exactly that feature")
    func plainPiAndOneBack() {
        let plain = Self.capabilities(features: Self.plainPi)
        #expect(!ServerFeature.allCases.contains(where: plain.offers))
        var mcp = Self.plainPi
        mcp[ServerFeature.mcp.rawValue] = true
        let one = Self.capabilities(features: mcp)
        #expect(ServerFeature.allCases.filter(one.offers) == [.mcp])
    }

    @Test("The sidebar lists All Sessions first, then the places the server offers and its plugin entries by order")
    func sidebarFollowsTheSwitches() {
        let plugins = [
            PluginScreenSidebarEntry(id: "acme.things", title: "Things", icon: "network", order: 50, scopes: ["server", "workspace"]),
            // An entry ordered before every built-in place still comes after All Sessions.
            PluginScreenSidebarEntry(id: "acme.early", title: "Early", icon: "network", order: -5, scopes: ["server"]),
            // A workspace-only entry opens from Workspace Settings, never the sidebar.
            PluginScreenSidebarEntry(id: "acme.local", title: "Local", icon: "network", order: 15, scopes: ["workspace"]),
        ]
        let all = WorkspaceSidebarPlaces.items(plugins: plugins, pinsAvailable: true) { _ in true }
        #expect(all.map(\.place) == [
            .allSessions, .utility(.pluginScreen("acme.early")), .utility(.pinned), .utility(.agents), .utility(.schedules),
            .utility(.extensions), .utility(.pluginScreen("acme.things")), .utility(.sshTerminal), .utility(.rex),
        ])
        #expect(all.first { $0.place == .utility(.pluginScreen("acme.things")) }?.title == "Things")
        // Every switch off leaves home; a server without pins has no Pinned.
        let plain = WorkspaceSidebarPlaces.items(plugins: [], pinsAvailable: false) { _ in false }
        #expect(plain.map(\.place) == [.allSessions])
        let terminalOnly = WorkspaceSidebarPlaces.items(plugins: [], pinsAvailable: false) { $0 == .terminal }
        #expect(terminalOnly.map(\.place) == [.allSessions, .utility(.sshTerminal)])
        // Rex stands alone: a server with Terminal off and Rex on lists Rex without Terminal.
        let rexServer = Self.capabilities(features: ["terminal": false])
        let rexOnly = WorkspaceSidebarPlaces.items(plugins: [], pinsAvailable: false, offers: rexServer.offers)
        #expect(rexOnly.map(\.place) == [.allSessions, .utility(.agents), .utility(.schedules), .utility(.extensions), .utility(.rex)])
    }

    @Test("A new pane offers Terminal, Rex, Web Page and Godot only where the server does")
    func paneLauncherFollowsTheSwitches() {
        typealias Choice = PaneLauncherViewController.Choice
        #expect(Choice.offered { _ in false } == [.sessions, .files])
        #expect(Choice.offered { $0 == .terminal } == [.sessions, .files, .terminal])
        #expect(Choice.offered { $0 == .browserPane } == [.sessions, .files, .web])
        #expect(Choice.offered { $0 == .rex } == [.sessions, .files, .rex])
    }

    @Test("Open Terminal Here on a Herdr host opens a plain shell in the folder while the server turns Herdr off")
    func folderTerminalFollowsTheServersHerdrSwitch() {
        let herdr = SSHTerminalProfile(host: "mac-studio.local", username: "alex", startupCommand: "herdr")
        let session = SSHTerminalConnectSession()
        let on = SSHTerminalFolderTarget(serverHost: "mac-studio.local", folder: "/Users/alex/app", label: "app")
        SSHTerminalFolderEntry.prepare(session: session, profile: herdr, target: on)
        #expect(session.multiplexerFolder == on)
        #expect(session.folder == nil)

        let off = SSHTerminalFolderTarget(
            serverHost: "mac-studio.local", folder: "/Users/alex/app", label: "app",
            serverOffers: SSHTerminalMultiplexerAccess(rex: true, herdr: false)
        )
        SSHTerminalFolderEntry.prepare(session: session, profile: herdr, target: off)
        #expect(session.multiplexerFolder == nil)
        #expect(session.folder == "/Users/alex/app")
    }

    @Test("Plain Pi saves every switch in one request, and each row settles to what the server stored")
    func plainPiIsOneSave() async throws {
        let allOn = Dictionary(uniqueKeysWithValues: ServerFeature.allCases.map { ($0.rawValue, JSONValue.bool(true)) })
        let transport = FakeSettingsTransport(fields: allOn, revision: nil)
        let store = SettingsStore(serverId: "server-1", server: ServerAdapter { _ in transport })
        let switches = ServerFeature.allCases.map(SettingsCatalog.feature)
        _ = await store.reload(SettingsCatalog.feature(.agents))

        await store.set(switches, to: false).value

        #expect(transport.saves.count == 1)
        #expect(transport.saves.first?.fields == allOn.mapValues { _ in .bool(false) })
        #expect(switches.allSatisfy { store.read($0).current == false })
    }

    @Test("Herdr is part of Terminal and goes off with it; Rex stands alone")
    func herdrNeedsTerminalRexDoesNot() {
        let terminalOff = Self.capabilities(features: ["terminal": false])
        #expect(!terminalOff.offers(.herdr))
        #expect(terminalOff.offers(.rex))
        #expect(Self.capabilities(features: ["rex": false]).offers(.herdr))
    }

    @Test("With the server's Rex off, a Rex pane's reconnect, a Rex screen, and a Rex on the tailnet say so instead of dialing")
    func rexConnectWhileServerOffSaysSo() {
        let profile = SSHTerminalProfile(host: "mac-studio.local", username: "alex", rexTailnet: URL(string: "https://rex.tail.ts.net"))
        let pane = RexPaneTarget(sessionID: "session:1", blockID: "block:1", label: "shell")
        let off = SSHTerminalMultiplexerAccess(rex: false, herdr: true)
        for ask in ["pane", "list", "tailnet"] {
            let session = SSHTerminalConnectSession(registry: SSHTerminalRegistry(), access: { off })
            switch ask {
            case "pane": session.rexPane = pane
            case "list": session.listsRexSessions = true
            default: break
            }
            session.connect(profile: profile)
            #expect(session.failure == "Rex is off for this server in Server Settings › Features.", "\(ask)")
            #expect(!session.connecting, "\(ask) must not dial")
            #expect(session.channel == nil && session.rexSessions == nil, "\(ask)")
        }
    }

    @Test("A switch saved from this device applies to the connection's capabilities at once")
    func aSaveUpdatesTheConnection() {
        let connection = ServerConnection()
        // Before capabilities load everything reads on, so a restored pane waits for them.
        #expect(ServerFeature.allCases.allSatisfy(connection.offers))
        connection.setSplitStreamCapabilitiesForTesting()
        #expect(connection.offers(.agents))
        connection.noteFeature(.agents, on: false)
        #expect(!connection.offers(.agents))
        #expect(connection.offers(.schedules))
    }
}

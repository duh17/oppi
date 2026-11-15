import Foundation
import Testing
@testable import Oppi

/// The server's feature switches (`features` in `/server/info`) as each surface that hides a
/// feature reads them. Plain Pi is every switch off.
@Suite("Server feature switches")
@MainActor
struct ServerFeatureTests {
    private static let plainPi = Dictionary(uniqueKeysWithValues: ServerFeature.allCases.map { ($0.rawValue, false) })

    private static func capabilities(features: [String: Bool]?, godot: Bool = true) -> ServerInfo.Capabilities {
        var capabilities = ServerInfo.Capabilities(
            sessionStream: .init(version: 1), dictationStream: nil, appEventStream: .init(version: 1), extensionNativeUI: nil
        )
        capabilities.godot = godot ? .init(version: 1) : nil
        capabilities.features = features
        return capabilities
    }

    @Test("An older server without switches offers everything; Godot also needs a server that serves games")
    func olderServersOfferEverything() {
        let older = Self.capabilities(features: nil)
        #expect(ServerFeature.allCases.allSatisfy(older.offers))
        #expect(!Self.capabilities(features: nil, godot: false).offers(.godotPane))
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

    @Test("The sidebar lists only the pages the server offers")
    func sidebarFollowsTheSwitches() {
        let all = WorkspaceSidebarPrimaryUtilities.items(plugins: []) { _ in true }
        #expect(all.map(\.target) == [.agents, .schedules, .skills, .extensions, .mcpServers, .sshTerminal])
        #expect(WorkspaceSidebarPrimaryUtilities.items(plugins: []) { _ in false }.isEmpty)
        let terminalOnly = WorkspaceSidebarPrimaryUtilities.items(plugins: []) { $0 == .terminal }
        #expect(terminalOnly.map(\.target) == [.sshTerminal])
    }

    @Test("A new pane offers Terminal, Rex, Web Page and Godot only where the server does")
    func paneLauncherFollowsTheSwitches() {
        typealias Choice = PaneLauncherViewController.Choice
        #expect(Choice.offered { _ in false } == [.sessions, .files])
        #expect(Choice.offered { $0 == .terminal } == [.sessions, .files, .terminal])
        #expect(Choice.offered { $0 == .browserPane } == [.sessions, .files, .web])
        // Rex also needs this device's Rex experiment.
        let rexServer: (ServerFeature) -> Bool = { $0 == .terminal || $0 == .rex }
        #expect(Choice.offered(by: rexServer, rexExperiment: true) == [.sessions, .files, .terminal, .rex])
        #expect(Choice.offered(by: rexServer, rexExperiment: false) == [.sessions, .files, .terminal])
        #expect(Choice.offered(by: { $0 == .terminal }, rexExperiment: true) == [.sessions, .files, .terminal])
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
            serverOffers: SSHTerminalExperimentAccess(rex: true, herdr: false)
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

    @Test("Rex and Herdr are part of Terminal: off with it")
    func rexAndHerdrNeedTerminal() {
        let terminalOff = Self.capabilities(features: ["terminal": false])
        #expect(!terminalOff.offers(.rex) && !terminalOff.offers(.herdr))
        #expect(Self.capabilities(features: ["rex": false]).offers(.herdr))
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

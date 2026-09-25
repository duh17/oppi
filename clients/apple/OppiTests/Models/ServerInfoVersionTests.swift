import Foundation
import Testing
@testable import Oppi

@Suite("ServerInfo agent version")
struct ServerInfoVersionTests {
    @Test func decodesPiVersion() throws {
        let data = Data(#"""
        {
          "name":"test",
          "version":"0.45.0",
          "uptime":1,
          "os":"darwin",
          "arch":"arm64",
          "hostname":"test.local",
          "nodeVersion":"v24.0.0",
          "piVersion":"0.81.0",
          "configVersion":1,
          "identity":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)

        #expect(info.piVersion == "0.81.0")
        #expect(info.piCliVersion == nil)
    }

    @Test func decodesOptionalPiCliVersion() throws {
        let data = Data(#"""
        {
          "name":"test",
          "version":"0.45.0",
          "uptime":1,
          "os":"darwin",
          "arch":"arm64",
          "hostname":"test.local",
          "nodeVersion":"v24.0.0",
          "piVersion":"0.85.0",
          "piCliVersion":"0.84.4",
          "configVersion":1,
          "identity":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)

        #expect(info.piVersion == "0.85.0")
        #expect(info.piCliVersion == "0.84.4")
    }

    @Test func decodesPayloadsWithoutPiCliVersion() throws {
        let data = Data(#"""
        {
          "name":"test",
          "version":"0.45.0",
          "uptime":1,
          "os":"darwin",
          "arch":"arm64",
          "hostname":"test.local",
          "nodeVersion":"v24.0.0",
          "piVersion":"0.85.0",
          "configVersion":1,
          "identity":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)

        #expect(info.piVersion == "0.85.0")
        #expect(info.piCliVersion == nil)
    }

    @Test func decodesOptionalUpdateBlock() throws {
        let data = Data(#"""
        {
          "name":"test",
          "version":"0.50.0",
          "uptime":1,
          "os":"darwin",
          "arch":"arm64",
          "hostname":"test.local",
          "nodeVersion":"v24.0.0",
          "piVersion":"0.85.0",
          "configVersion":1,
          "identity":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0},
          "update":{
            "installKind":"npm-global",
            "latestVersion":"0.51.0",
            "available":true,
            "manualCommand":"npm install -g oppi-server@0.51.0",
            "status":"idle",
            "restartMode":"reexec"
          }
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        #expect(info.update?.installKind == "npm-global")
        #expect(info.update?.latestVersion == "0.51.0")
        #expect(info.update?.available == true)
        #expect(info.update?.isAppUpdatable == true)
        #expect(info.update?.manualCommand == "npm install -g oppi-server@0.51.0")
        #expect(info.update?.status == "idle")
        #expect(info.update?.restartMode == "reexec")
    }

    @Test func decodesPayloadsWithoutUpdateBlock() throws {
        let data = Data(#"""
        {
          "name":"test",
          "version":"0.45.0",
          "uptime":1,
          "os":"darwin",
          "arch":"arm64",
          "hostname":"test.local",
          "nodeVersion":"v24.0.0",
          "piVersion":"0.81.0",
          "configVersion":1,
          "identity":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        #expect(info.update == nil)
        #expect(ServerReleaseVersion.isBelowMinimum(info.version))
    }

    @Test func decodesControlSessionCapability() throws {
        let data = Data(#"{"name":"test","version":"1","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"v24","piVersion":"1","configVersion":1,"capabilities":{"controlSessions":{"version":1}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}"#.utf8)
        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        #expect(info.capabilities?.controlSessions?.version == 1)
    }
}

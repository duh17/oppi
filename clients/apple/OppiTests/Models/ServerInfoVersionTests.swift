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
    }

    @Test func decodesControlSessionCapability() throws {
        let data = Data(#"{"name":"test","version":"1","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"v24","piVersion":"1","configVersion":1,"capabilities":{"controlSessions":{"version":1}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}"#.utf8)
        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        #expect(info.capabilities?.controlSessions?.version == 1)
    }
}

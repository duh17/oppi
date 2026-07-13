import Foundation
import Testing
@testable import Oppi

@Suite("ServerInfo agent version")
struct ServerInfoVersionTests {
    @Test func usesPiVersionWhenMutableRuntimeStatusIsAbsent() throws {
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
          "runtimeUpdate":null,
          "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}
        }
        """#.utf8)

        let info = try JSONDecoder().decode(ServerInfo.self, from: data)

        #expect(info.agentVersionLabel == "0.81.0")
    }
}

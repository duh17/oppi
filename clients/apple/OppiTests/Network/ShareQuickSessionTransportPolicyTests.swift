import Foundation
import Testing
@testable import Oppi

@Suite("Share Quick Session transport policy")
struct ShareQuickSessionTransportPolicyTests {
    private func record(scheme: String) throws -> PairedServer {
        let json = Data("""
        {
          "id": "server-1",
          "name": "Studio",
          "host": "mac-studio.tail123.ts.net",
          "port": 7749,
          "scheme": "\(scheme)",
          "token": "at_leftover",
          "addedAt": 0,
          "sortOrder": 0
        }
        """.utf8)
        return try JSONDecoder().decode(PairedServer.self, from: json)
    }

    @Test func httpRecordHasNoShareEndpoint() throws {
        #expect(ShareQuickSessionCredentialStore.endpoint(of: try record(scheme: "http")) == nil)
    }

    @Test func httpsRecordSharesOverItsBaseURL() throws {
        let endpoint = ShareQuickSessionCredentialStore.endpoint(of: try record(scheme: "https"))
        #expect(endpoint == URL(string: "https://mac-studio.tail123.ts.net:7749"))
    }
}

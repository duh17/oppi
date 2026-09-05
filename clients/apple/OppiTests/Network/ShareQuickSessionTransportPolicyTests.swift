import Foundation
import Testing
@testable import Oppi

@Suite("Share Quick Session transport policy")
struct ShareQuickSessionTransportPolicyTests {
    @Test func decoderRejectsHTTPRecords() {
        let json = Data("""
        {
          "id": "server-1",
          "name": "Studio",
          "host": "mac-studio.tail123.ts.net",
          "port": 7749,
          "scheme": "http",
          "token": "at_leftover",
          "sortOrder": 0
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ShareQuickSessionServer.self, from: json)
        }
    }

    @Test func decoderAcceptsHTTPSRecords() throws {
        let json = Data("""
        {
          "id": "server-1",
          "name": "Studio",
          "host": "mac-studio.tail123.ts.net",
          "port": 7749,
          "scheme": "https",
          "token": "",
          "sortOrder": 0
        }
        """.utf8)

        let server = try JSONDecoder().decode(ShareQuickSessionServer.self, from: json)
        #expect(server.baseURL.scheme == "https")
    }

    @Test func failableInitRejectsHTTP() {
        #expect(
            ShareQuickSessionServer(
                id: "server-1",
                name: "Studio",
                baseURL: URL(string: "http://mac-studio.tail123.ts.net:7749"),
                token: "",
                tlsCertFingerprint: nil,
                sortOrder: 0
            ) == nil
        )
    }
}

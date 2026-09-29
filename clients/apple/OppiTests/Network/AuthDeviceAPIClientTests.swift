import Foundation
import Testing
@testable import Oppi

@Suite("Auth device API")
struct AuthDeviceAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: "sk_test"
        )
        return APIClient(
            environment: environment,
            configuration: config
        )
    }

    private func cleanup() {
        TestURLProtocol.handler = nil
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    @Test func listAuthDevicesDecodesServerRoster() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/auth/devices")
            return self.mockResponse(json: """
            {
              "devices": [
                {
                  "id": "dev_a",
                  "name": "Phone",
                  "scope": "device",
                  "createdAt": 1,
                  "lastUsedAt": 2,
                  "keyEnrolled": true
                },
                {
                  "id": "dev_b",
                  "name": "Old",
                  "scope": "device",
                  "createdAt": 1,
                  "revokedAt": 9
                }
              ]
            }
            """)
        }

        let devices = try await client.listAuthDevices()
        #expect(devices.map(\.id) == ["dev_a", "dev_b"])
        #expect(devices[0].name == "Phone")
        #expect(devices[0].lastUsedAt == 2)
        #expect(devices[0].keyEnrolled == true)
        #expect(devices[1].revokedAt == 9)
    }

    @Test func revokeAuthDeviceDeletesTheDevicePath() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/auth/devices/dev_a")
            return self.mockResponse(json: #"{"ok":true}"#)
        }

        try await client.revokeAuthDevice(id: "dev_a")
    }
}

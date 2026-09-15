import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("Desktop view session APIClient")
struct DesktopViewSessionAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: "at_test_device"
        )
        return APIClient(environment: environment, configuration: config)
    }

    @Test func getDesktopViewSessionRequestsPairedJSONRoute() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        let grantId = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/desktop/view/session")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at_test_device")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let body = Data(
                """
                {
                  "grantId": "\(grantId.uuidString)",
                  "capability": "view",
                  "deviceId": "phone-1",
                  "expiresAt": "2026-09-12T03:15:40.123Z",
                  "caption": "View session—not live delivery"
                }
                """.utf8
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Cache-Control": "no-store",
                ]
            )!
            return (body, response)
        }

        let session = try await client.getDesktopViewSession()
        #expect(session.grantId == grantId)
        #expect(session.capability == "view")
        #expect(session.deviceId == "phone-1")
        #expect(session.caption == "View session—not live delivery")
        #expect(session.caption.localizedCaseInsensitiveContains("not live"))
    }

    @Test func getDesktopViewSessionMapsUnavailableAndNotBound() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            let body = Data(
                #"{"error":"Desktop view session is not available","code":"view_grant_unavailable"}"#.utf8
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
        do {
            _ = try await client.getDesktopViewSession()
            Issue.record("expected 403 unavailable")
        } catch let error as APIError {
            guard case .codedServer(let status, _, let code) = error else {
                Issue.record("expected coded server error")
                return
            }
            #expect(status == 403)
            #expect(code == "view_grant_unavailable")
        }

        TestURLProtocol.handler = { request in
            let body = Data(
                #"{"error":"Desktop view session is not granted to this device","code":"view_grant_not_bound"}"#.utf8
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
        do {
            _ = try await client.getDesktopViewSession()
            Issue.record("expected 403 not bound")
        } catch let error as APIError {
            guard case .codedServer(let status, _, let code) = error else {
                Issue.record("expected coded server error")
                return
            }
            #expect(status == 403)
            #expect(code == "view_grant_not_bound")
        }
    }

    @Test func parserRejectsPNGLiveCaptionAndMissingNoStore() throws {
        let url = URL(string: "http://localhost:7749/desktop/view/session")!
        let png = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let pngResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/png",
                "Cache-Control": "no-store",
            ]
        )!
        #expect(throws: APIError.self) {
            try DesktopViewSessionParser.parse(data: png, response: pngResponse)
        }

        let live = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "Cache-Control": "no-store",
            ]
        )!
        let liveBody = Data(
            """
            {
              "grantId": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
              "capability": "view",
              "deviceId": "phone-1",
              "expiresAt": "2026-09-12T03:15:40Z",
              "caption": "Live preview"
            }
            """.utf8
        )
        #expect(throws: APIError.self) {
            try DesktopViewSessionParser.parse(data: liveBody, response: live)
        }

        let cached = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "Cache-Control": "public",
            ]
        )!
        let okBody = Data(
            """
            {
              "grantId": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
              "capability": "view",
              "deviceId": "phone-1",
              "expiresAt": "2026-09-12T03:15:40Z",
              "caption": "View session—not live delivery"
            }
            """.utf8
        )
        #expect(throws: APIError.self) {
            try DesktopViewSessionParser.parse(data: okBody, response: cached)
        }
    }
}

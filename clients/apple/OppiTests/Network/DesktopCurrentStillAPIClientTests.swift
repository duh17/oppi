import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("Desktop current still APIClient")
struct DesktopCurrentStillAPIClientTests {
    private let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: "at_test_device"
        )
        return APIClient(environment: environment, configuration: config)
    }

    @Test func getDesktopCurrentStillRequestsPairedRouteAndParsesHeaders() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        let captureID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/desktop/stills/current")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at_test_device")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Cache-Control": "no-store",
                    DesktopCurrentStillHeaders.captureID: captureID.uuidString,
                    DesktopCurrentStillHeaders.surfaceWindowID: "91",
                    DesktopCurrentStillHeaders.surfaceTitle: "Notes",
                    DesktopCurrentStillHeaders.capturedAt: "2026-09-12T03:00:40.123Z",
                    DesktopCurrentStillHeaders.width: "1",
                    DesktopCurrentStillHeaders.height: "1",
                    DesktopCurrentStillHeaders.caption: DesktopCurrentStillHeaders.stillCaption,
                ]
            )!
            return (self.png, response)
        }

        let still = try await client.getDesktopCurrentStill()
        #expect(still.captureID == captureID)
        #expect(still.surfaceWindowID == 91)
        #expect(still.surfaceTitle == "Notes")
        #expect(still.width == 1)
        #expect(still.height == 1)
        #expect(still.caption == "Still—not live")
        #expect(still.pngData == png)
    }

    @Test func getDesktopCurrentStillDecodesUTF8CaptionFromLatin1HeaderBytes() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        let captureID = UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!
        let latin1Caption = String(
            bytes: Array(DesktopCurrentStillHeaders.stillCaption.utf8),
            encoding: .isoLatin1
        )!

        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/png",
                    "Cache-Control": "no-store",
                    DesktopCurrentStillHeaders.captureID: captureID.uuidString,
                    DesktopCurrentStillHeaders.surfaceWindowID: "7",
                    DesktopCurrentStillHeaders.surfaceTitle: "Notes",
                    DesktopCurrentStillHeaders.capturedAt: "2026-09-12T03:00:40Z",
                    DesktopCurrentStillHeaders.width: "1",
                    DesktopCurrentStillHeaders.height: "1",
                    DesktopCurrentStillHeaders.caption: latin1Caption,
                ]
            )!
            return (self.png, response)
        }

        let still = try await client.getDesktopCurrentStill()
        #expect(still.caption == "Still—not live")
        #expect(still.captureID == captureID)
    }

    @Test func getDesktopCurrentStillMapsForbiddenAndMissing() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            let body = Data(#"{"error":"Desktop still sharing is disabled"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
        do {
            _ = try await client.getDesktopCurrentStill()
            Issue.record("expected 403")
        } catch let error as APIError {
            guard case .server(let status, _) = error else {
                Issue.record("expected server error")
                return
            }
            #expect(status == 403)
        }

        TestURLProtocol.handler = { request in
            let body = Data(#"{"error":"Desktop still is not available"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
        do {
            _ = try await client.getDesktopCurrentStill()
            Issue.record("expected 404")
        } catch let error as APIError {
            guard case .server(let status, _) = error else {
                Issue.record("expected server error")
                return
            }
            #expect(status == 404)
        }
    }

    @Test func parserRejectsLiveCaptionAndMissingNoStore() throws {
        let url = URL(string: "http://localhost:7749/desktop/stills/current")!
        let live = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/png",
                "Cache-Control": "no-store",
                DesktopCurrentStillHeaders.captureID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                DesktopCurrentStillHeaders.surfaceWindowID: "1",
                DesktopCurrentStillHeaders.surfaceTitle: "Notes",
                DesktopCurrentStillHeaders.capturedAt: "2026-09-12T03:00:40Z",
                DesktopCurrentStillHeaders.width: "1",
                DesktopCurrentStillHeaders.height: "1",
                DesktopCurrentStillHeaders.caption: "Live preview",
            ]
        )!
        #expect(throws: APIError.self) {
            try DesktopCurrentStillParser.parse(data: png, response: live)
        }

        let cached = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/png",
                "Cache-Control": "public",
                DesktopCurrentStillHeaders.captureID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                DesktopCurrentStillHeaders.surfaceWindowID: "1",
                DesktopCurrentStillHeaders.surfaceTitle: "Notes",
                DesktopCurrentStillHeaders.capturedAt: "2026-09-12T03:00:40Z",
                DesktopCurrentStillHeaders.width: "1",
                DesktopCurrentStillHeaders.height: "1",
                DesktopCurrentStillHeaders.caption: DesktopCurrentStillHeaders.stillCaption,
            ]
        )!
        #expect(throws: APIError.self) {
            try DesktopCurrentStillParser.parse(data: png, response: cached)
        }
    }
}

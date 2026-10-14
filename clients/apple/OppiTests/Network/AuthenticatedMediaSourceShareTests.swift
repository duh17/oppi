import Foundation
import Testing
@testable import Oppi

@Suite("Authenticated media file sharing", .serialized)
struct AuthenticatedMediaSourceShareTests {
    @Test("explicit share downloads complete authenticated bytes")
    func downloadsAuthenticatedFileData() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        let expected = Data("wave bytes".utf8)
        AudioShareURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            return (
                expected,
                (try #require(HTTPURLResponse(
                    url: testUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "audio/wav"]
                )))
            )
        }

        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/story.wav")),
            authorizationProvider: { "Bearer fresh-token" },
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/wav",
            sourceFileExtension: "wav"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]

        let data = try await source.loadFileData(configuration: configuration)
        #expect(data == expected)
    }

    @Test("share download rejects redirects")
    func rejectsRedirects() throws {
        let sourceURL = testUnwrap(URL(string: "https://server.example.com/files/story.wav"))
        let redirectedURL = testUnwrap(URL(string: "https://other.example.com/story.wav"))
        let delegate = AuthenticatedMediaFileDownloadDelegate(
            pinnedLeafFingerprint: nil,
            expectedServerName: nil
        )
        let task = URLSession.shared.dataTask(with: sourceURL)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        let capture = RedirectRequestCapture()

        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            capture.record(request)
        }

        #expect(capture.wasCalled)
        #expect(capture.request == nil)
    }

    @Test("share download rejects non-success responses")
    func rejectsFailedDownload() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        AudioShareURLProtocol.handler = { request in
            (
                Data(),
                (try #require(HTTPURLResponse(
                    url: testUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )))
            )
        }

        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/story.wav")),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/wav",
            sourceFileExtension: "wav"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]

        await #expect(throws: URLError.self) {
            _ = try await source.loadFileData(configuration: configuration)
        }
    }

    @Test("clip length comes from the media-info route, not audio bytes")
    func loadsDurationFromMediaInfo() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        let mediaInfoURL = testUnwrap(URL(string: "https://server.example.com/files/current/media-info?origin=host&path=~/a.wav"))
        nonisolated(unsafe) var body = #"{"durationSeconds":4.32}"#
        AudioShareURLProtocol.handler = { request in
            #expect(request.url == mediaInfoURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
            return (
                Data(body.utf8),
                (try #require(HTTPURLResponse(
                    url: testUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )))
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]
        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/current?origin=host&path=~/a.wav")),
            authorizationProvider: { "Bearer fresh-token" },
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/wav",
            sourceFileExtension: "wav",
            mediaInfoURL: mediaInfoURL
        )

        #expect(try await source.loadDurationSeconds(configuration: configuration) == 4.32)

        // The server could not read a length: no label, no error.
        body = "{}"
        #expect(try await source.loadDurationSeconds(configuration: configuration) == nil)

        // Attachment sources have no media-info route and make no request.
        AudioShareURLProtocol.handler = { _ in throw URLError(.badURL) }
        let attachment = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/sessions/s1/attachments/a1")),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/wav",
            sourceFileExtension: "wav"
        )
        #expect(try await attachment.loadDurationSeconds(configuration: configuration) == nil)
    }
}

private final class RedirectRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?
    private var called = false

    var request: URLRequest? {
        lock.withLock { capturedRequest }
    }

    var wasCalled: Bool {
        lock.withLock { called }
    }

    func record(_ request: URLRequest?) {
        lock.withLock {
            capturedRequest = request
            called = true
        }
    }
}

private final class AudioShareURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

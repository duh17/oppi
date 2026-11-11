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

    private func shareDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-share-download-tests/\(UUID().uuidString)/clip.mp4")
    }

    @Test("a row's share downloads the raw file to a temporary file, reporting progress")
    @MainActor
    func sharesAWorkspaceFileThroughTheRawFileRoute() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        let expected = Data(repeating: 0x5A, count: 300_000)
        AudioShareURLProtocol.handler = { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(request.httpMethod == "GET")
            #expect(url.path == "/files/current")
            #expect(query.contains(URLQueryItem(name: "origin", value: "workspace")))
            #expect(query.contains(URLQueryItem(name: "workspaceId", value: "w1")))
            #expect(query.contains(URLQueryItem(name: "path", value: "media/clip.mp4")))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer share-token")
            return (
                expected,
                (try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "video/mp4", "Content-Length": String(expected.count)]
                )))
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]
        let api = APIClient(
            baseURL: testUnwrap(URL(string: "https://server.example.com")),
            token: "share-token",
            configuration: configuration
        )
        let access = FileViewerViewController.Configuration(
            workspaceId: "w1", filePath: "media/clip.mp4", fileName: "clip.mp4"
        ).fileAccess
        let share = access.remoteFileShare(api: api, path: "media/clip.mp4", fileName: "clip.mp4", size: expected.count)
        #expect(share.fileName == "clip.mp4")
        #expect(share.expectedBytes == Int64(expected.count))

        let destination = shareDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let reported = ProgressCapture()
        try await share.download(destination) { reported.record($0) }

        #expect(try Data(contentsOf: destination) == expected)
        #expect(reported.last == FileDownloadProgress(received: Int64(expected.count), expected: Int64(expected.count)))
    }

    @Test("a file over the server's size limit is refused with the server's reason")
    func reportsAFileOverTheSizeLimit() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        AudioShareURLProtocol.handler = { request in
            (
                Data(#"{"error":"File too large (max 10MB)"}"#.utf8),
                (try #require(HTTPURLResponse(
                    url: testUnwrap(request.url),
                    statusCode: 413,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )))
            )
        }
        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/current?path=big.log")),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: nil,
            sourceFileExtension: "log"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]
        let destination = shareDestination()
        let reported = ProgressCapture()

        let refusal = await #expect(throws: FileDownloadError.self) {
            try await source.downloadFile(to: destination, configuration: configuration) { reported.record($0) }
        }
        #expect(refusal == .rejected(status: 413, message: "File too large (max 10MB)"))
        #expect(!FileManager.default.fileExists(atPath: destination.path), "an error body is not the file")
        #expect(reported.last == nil, "an error body is not progress")
    }

    @Test("cancelling a share download stops it and leaves no file")
    func cancelsADownload() async throws {
        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/current?path=long.mov")),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: nil,
            sourceFileExtension: "mov"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledDownloadURLProtocol.self]
        let destination = shareDestination()
        let started = ProgressCapture()
        let download = Task {
            try await source.downloadFile(to: destination, configuration: configuration) { started.record($0) }
        }
        // The first bytes arrive and the rest never will: wait for the transfer
        // to be under way, without requiring a progress report to say so.
        for _ in 0..<200 where started.last == nil { try await Task.sleep(for: .milliseconds(10)) }
        download.cancel()

        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
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

    @Test("clip length survives a format or tags section the app cannot decode")
    func keepsDurationWhenTheRestDoesNotDecode() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        let mediaInfoURL = testUnwrap(URL(string: "https://server.example.com/files/current/media-info?origin=host&path=~/a.m4a"))
        // A newer server naming a codec as a number, and a tag value as one: the
        // whole body fails to decode as `MediaInfo` and still states the length.
        let body = #"{"durationSeconds":2712.4,"format":{"codec":6},"tags":{"title":12}}"#
        AudioShareURLProtocol.handler = { _ in
            (
                Data(body.utf8),
                (try #require(HTTPURLResponse(
                    url: mediaInfoURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )))
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]
        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/current?origin=host&path=~/a.m4a")),
            authorizationProvider: { "Bearer fresh-token" },
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/mp4",
            sourceFileExtension: "m4a",
            mediaInfoURL: mediaInfoURL
        )

        #expect(try await source.loadDurationSeconds(configuration: configuration) == 2712.4)
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

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: FileDownloadProgress?

    var last: FileDownloadProgress? { lock.withLock { latest } }

    func record(_ progress: FileDownloadProgress) {
        lock.withLock { latest = progress }
    }
}

/// Answers with the head and first bytes of a large file, then nothing.
private final class StalledDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "50000000"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 200_000))
    }

    override func stopLoading() {}
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

import CryptoKit
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
            // A ranged read: the server caps only whole reads, which a viewer holds in memory.
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-")
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

    @Test("an empty file, which has no byte to range over, downloads as an empty file")
    func downloadsAnEmptyFile() async throws {
        defer { AudioShareURLProtocol.handler = nil }
        AudioShareURLProtocol.handler = { request in
            (
                Data(),
                (try #require(HTTPURLResponse(
                    url: testUnwrap(request.url),
                    statusCode: 416,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Range": "bytes */0", "Content-Length": "0"]
                )))
            )
        }
        let source = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: "https://server.example.com/files/current?path=empty.bin")),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: nil,
            sourceFileExtension: "bin"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioShareURLProtocol.self]
        let destination = shareDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try await source.downloadFile(to: destination, configuration: configuration) { _ in }

        #expect(try Data(contentsOf: destination).isEmpty)
    }

    private func scriptedDownload(_ url: String) -> ResumableFileDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDownloadURLProtocol.self]
        var download = AuthenticatedMediaSource(
            url: testUnwrap(URL(string: url)),
            authorizationProvider: { "Bearer token-\(UUID().uuidString.prefix(4))" },
            tlsCertFingerprint: nil,
            contentTypeHint: nil,
            sourceFileExtension: "zip"
        ).resumableDownload(configuration: configuration)
        download.retryDelays = [.zero, .zero]
        download.waitUntilActive = {}
        return download
    }

    private static func digest(_ data: Data) -> String {
        "sha-256=:\(Data(SHA256.hash(data: data)).base64EncodedString()):"
    }

    @Test("a dropped download resumes from the bytes it has, while the file is unchanged")
    func resumesAfterADrop() async throws {
        defer { ScriptedDownloadURLProtocol.script = nil }
        let file = Data((0..<400_000).map { UInt8($0 % 251) })
        let half = 150_000
        let requests = RequestLog()
        ScriptedDownloadURLProtocol.script = { request, index in
            requests.record(request)
            let url = try #require(request.url)
            let start = index == 0 ? 0 : half
            let response = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)",
                "Content-Length": String(file.count - start),
                "ETag": "\"v1\"",
                "X-Oppi-File-Digest": Self.digest(file),
            ]))
            // The first answer drops after half the file.
            return index == 0
                ? (response, file.prefix(half), URLError(.networkConnectionLost))
                : (response, file.suffix(from: half), nil)
        }
        let destination = shareDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let reported = ProgressCapture()

        try await scriptedDownload("https://server.example.com/files/current?path=archive-sample.zip")
            .run(to: destination) { reported.record($0) }

        #expect(try Data(contentsOf: destination) == file)
        let sent = requests.all
        #expect(sent.count == 2)
        #expect(sent.first?.value(forHTTPHeaderField: "Range") == "bytes=0-")
        #expect(sent.first?.value(forHTTPHeaderField: "If-Range") == nil)
        #expect(sent.last?.value(forHTTPHeaderField: "Range") == "bytes=\(half)-")
        #expect(sent.last?.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-Oppi-Want-File-Digest") == "sha-256" })
        #expect(reported.last == FileDownloadProgress(received: Int64(file.count), expected: Int64(file.count)))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }

    @Test("a file that changed while the download was down starts over with the new file")
    func restartsWhenTheFileChanged() async throws {
        defer { ScriptedDownloadURLProtocol.script = nil }
        let old = Data(repeating: 1, count: 200_000)
        let new = Data(repeating: 2, count: 120_000)
        let requests = RequestLog()
        ScriptedDownloadURLProtocol.script = { request, index in
            requests.record(request)
            let url = try #require(request.url)
            if index == 0 {
                let response = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Range": "bytes 0-\(old.count - 1)/\(old.count)",
                    "Content-Length": String(old.count),
                    "ETag": "\"v1\"",
                    "X-Oppi-File-Digest": Self.digest(old),
                ]))
                return (response, old.prefix(90_000), URLError(.networkConnectionLost))
            }
            // If-Range no longer holds: the server sends the whole new file.
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Length": String(new.count),
                "ETag": "\"v2\"",
                "X-Oppi-File-Digest": Self.digest(new),
            ]))
            return (response, new, nil)
        }
        let destination = shareDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try await scriptedDownload("https://server.example.com/files/current?path=archive-sample.zip")
            .run(to: destination) { _ in }

        #expect(requests.all.last?.value(forHTTPHeaderField: "If-Range") == "\"v1\"", "the resume named the old version")
        #expect(try Data(contentsOf: destination) == new)
    }

    @Test("a file whose bytes do not match the server's digest is not kept")
    func refusesADigestMismatch() async throws {
        defer { ScriptedDownloadURLProtocol.script = nil }
        let file = Data(repeating: 3, count: 50_000)
        ScriptedDownloadURLProtocol.script = { request, _ in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes 0-\(file.count - 1)/\(file.count)",
                "Content-Length": String(file.count),
                "ETag": "\"v1\"",
                "X-Oppi-File-Digest": Self.digest(Data(repeating: 4, count: 50_000)),
            ]))
            return (response, file, nil)
        }
        let destination = shareDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let error = await #expect(throws: FileDownloadError.self) {
            try await scriptedDownload("https://server.example.com/files/current?path=archive-sample.zip")
                .run(to: destination) { _ in }
        }
        #expect(error == .digestMismatch)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
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

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var all: [URLRequest] { lock.withLock { requests } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

/// Answers the nth request with a response, its bytes, and then either the
/// end of the body or a failure, as `script` says.
private final class ScriptedDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    /// Setting a script starts its request count over.
    nonisolated(unsafe) static var script: ((URLRequest, Int) throws -> (HTTPURLResponse, Data, URLError?))? {
        didSet { count = 0 }
    }
    nonisolated(unsafe) private static var count = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.count
        Self.count += 1
        guard let script = Self.script, let (response, body, failure) = try? script(request, index) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        guard let failure else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // The connection drops a moment after the bytes arrived, as a real
        // one does; a failure in the same turn discards the bytes undelivered.
        let loader = self
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            loader.client?.urlProtocol(loader, didFailWithError: failure)
        }
    }

    override func stopLoading() {}
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

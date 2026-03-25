import Testing
import Foundation
@testable import Oppi

@Suite("MacAPIClient")
struct MacAPIClientTests {

    private let client = MacAPIClient(
        baseURL: URL(string: "https://localhost:7749")!,
        token: "test-token"
    )

    // MARK: - readOwnerToken

    /// Helper: write JSON to a temp config.json, return the data dir path.
    private func writeTempConfig(_ json: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("config.json")
        try json.write(to: configPath, atomically: true, encoding: .utf8)
        return dir.path
    }

    @Test func readOwnerTokenFromTokenField() throws {
        let dir = try writeTempConfig(#"{"token": "sk_abc123"}"#)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == "sk_abc123")
    }

    @Test func readOwnerTokenFromOwnerTokenField() throws {
        let dir = try writeTempConfig(#"{"ownerToken": "sk_owner456"}"#)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == "sk_owner456")
    }

    @Test func readOwnerTokenPrefersTokenOverOwnerToken() throws {
        let dir = try writeTempConfig(#"{"token": "preferred", "ownerToken": "fallback"}"#)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == "preferred")
    }

    @Test("readOwnerToken returns nil for bad inputs",
          arguments: [
            "/nonexistent/dir/that/does/not/exist",
          ])
    func readOwnerTokenMissingDir(dir: String) {
        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == nil)
    }

    @Test func readOwnerTokenReturnsNilForMalformedJSON() throws {
        let dir = try writeTempConfig("not json {{{")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == nil)
    }

    @Test func readOwnerTokenReturnsNilWhenBothFieldsMissing() throws {
        let dir = try writeTempConfig(#"{"version": "1.0"}"#)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(MacAPIClient.readOwnerToken(dataDir: dir) == nil)
    }

    // MARK: - parseServerInfo — uptime formatting

    @Test("uptime formatting",
          arguments: [
            (300.0, "5m"),               // 5 minutes
            (3600.0, "1h 0m"),           // 1 hour exactly
            (5400.0, "1h 30m"),          // 1.5 hours
            (86400.0, "1d 0h"),          // exactly 24h → 1d 0h
            (90000.0, "1d 1h"),          // 25 hours → 1d 1h
            (172800.0, "2d 0h"),         // 48 hours → 2d 0h
            (0.0, "0m"),                 // zero
            (59.0, "0m"),               // under a minute → 0m
          ])
    func uptimeFormatting(uptime: Double, expected: String) {
        let json = """
        {"version":"1.0","serverUrl":"https://localhost:7749","uptime":\(uptime)}
        """
        let data = Data(json.utf8)
        let info = client.parseServerInfo(data)

        #expect(info?.uptime == expected)
    }

    @Test func parseServerInfoNilUptime() {
        let json = #"{"version":"1.0","serverUrl":"https://localhost:7749"}"#
        let info = client.parseServerInfo(Data(json.utf8))

        #expect(info?.uptime == nil)
    }

    // MARK: - parseServerInfo — field fallbacks

    @Test func parseServerInfoAllFields() {
        let json = #"{"version":"2.1.0","serverUrl":"https://my.server:443","uptime":7200,"name":"prod"}"#
        let info = client.parseServerInfo(Data(json.utf8))

        #expect(info?.version == "2.1.0")
        #expect(info?.serverURL == "https://my.server:443")
        #expect(info?.uptime == "2h 0m")
        #expect(info?.name == "prod")
    }

    @Test func parseServerInfoDefaultsForMissingFields() {
        let json = #"{}"#
        let info = client.parseServerInfo(Data(json.utf8))

        #expect(info?.version == "unknown")
        #expect(info?.serverURL == "https://localhost:7749") // falls back to baseURL
        #expect(info?.uptime == nil)
        #expect(info?.name == nil)
    }

    @Test func parseServerInfoReturnsNilForInvalidJSON() {
        let info = client.parseServerInfo(Data("not json".utf8))
        #expect(info == nil)
    }

    // MARK: - URL construction

    @Test func baseURLPreserved() {
        #expect(client.baseURL.absoluteString == "https://localhost:7749")
    }

    // MARK: - checkHealth / fetchServerInfo (integration, live server)

    @Test func checkHealthAgainstLiveServer() async {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else {
            return // skip if no config
        }

        let liveClient = MacAPIClient(
            baseURL: URL(string: "https://localhost:7749")!,
            token: token
        )

        let healthy = await liveClient.checkHealth()
        #expect(healthy)
    }

    @Test func checkHealthReturnsFalseForDeadServer() async {
        let deadClient = MacAPIClient(
            baseURL: URL(string: "https://localhost:1")!,
            token: "bogus"
        )

        let healthy = await deadClient.checkHealth()
        #expect(!healthy)
    }

    @Test func fetchServerInfoFromLiveServer() async {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else {
            return // skip if no config
        }

        let liveClient = MacAPIClient(
            baseURL: URL(string: "https://localhost:7749")!,
            token: token
        )

        let info = await liveClient.fetchServerInfo()
        #expect(info != nil)
        if let info {
            #expect(!info.version.isEmpty)
            #expect(info.serverURL.contains("7749"))
        }
    }
}

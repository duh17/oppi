import Foundation
import Testing
@testable import Oppi

@Suite("ServerInfo presentation helpers")
struct ServerInfoTests {
    @Test func uptimeLabelFormatsDaysHoursMinutesAndSeconds() {
        let daySample = makeServerInfo(uptime: 2 * 86_400 + 3 * 3_600 + 12 * 60 + 9)
        #expect(daySample.uptimeLabel == "2d 3h")

        let hourSample = makeServerInfo(uptime: 5 * 3_600 + 27 * 60 + 4)
        #expect(hourSample.uptimeLabel == "5h 27m")

        let minuteSample = makeServerInfo(uptime: 8 * 60 + 6)
        #expect(minuteSample.uptimeLabel == "8m 6s")

        let secondSample = makeServerInfo(uptime: 42)
        #expect(secondSample.uptimeLabel == "42s")
    }

    @Test func platformLabelMapsKnownPlatformsAndFallsBack() {
        #expect(makeServerInfo(os: "darwin", arch: "arm64").platformLabel == "macOS arm64")
        #expect(makeServerInfo(os: "linux", arch: "x64").platformLabel == "Linux x64")
        #expect(makeServerInfo(os: "win32", arch: "x64").platformLabel == "Windows x64")
        #expect(makeServerInfo(os: "freebsd", arch: "arm64").platformLabel == "freebsd arm64")
    }

    @Test func decodeServerInfoWithOptionalSections() throws {
        let json = Data("""
        {
          "name": "oppi",
          "version": "1.2.3",
          "uptime": 3661,
          "os": "darwin",
          "arch": "arm64",
          "hostname": "mac-studio",
          "nodeVersion": "v24.1.0",
          "piVersion": "0.7.1",
          "configVersion": 5,
          "identity": {
            "fingerprint": "abc123",
            "keyId": "main",
            "algorithm": "ed25519"
          },
          "runtimeUpdate": {
            "packageName": "@mariozechner/pi-coding-agent",
            "currentVersion": "1.0.0",
            "latestVersion": "1.1.0",
            "pendingVersion": null,
            "updateAvailable": true,
            "canUpdate": true,
            "checking": false,
            "updateInProgress": false,
            "restartRequired": false,
            "lastCheckedAt": 123,
            "checkError": null,
            "lastUpdatedAt": null,
            "lastUpdateError": null
          },
          "stats": {
            "workspaceCount": 3,
            "activeSessionCount": 2,
            "totalSessionCount": 9,
            "skillCount": 12,
            "modelCount": 6
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ServerInfo.self, from: json)
        #expect(decoded.name == "oppi")
        #expect(decoded.identity?.fingerprint == "abc123")
        #expect(decoded.runtimeUpdate?.updateAvailable == true)
        #expect(decoded.stats.workspaceCount == 3)
    }

    private func makeServerInfo(uptime: Int = 0, os: String = "darwin", arch: String = "arm64") -> ServerInfo {
        ServerInfo(
            name: "oppi",
            version: "1.0.0",
            uptime: uptime,
            os: os,
            arch: arch,
            hostname: "host",
            nodeVersion: "v24",
            piVersion: "0.1.0",
            configVersion: 1,
            identity: nil,
            runtimeUpdate: nil,
            stats: .init(workspaceCount: 0, activeSessionCount: 0, totalSessionCount: 0, skillCount: 0, modelCount: 0)
        )
    }
}

@Suite("GitStatus and ExtensionInfo helpers")
struct GitStatusTests {
    @Test func emptyStatusIsCleanAndHasZeroCounts() {
        #expect(GitStatus.empty.isGitRepo == false)
        #expect(GitStatus.empty.uncommittedCount == 0)
        #expect(GitStatus.empty.isClean == true)
    }

    @Test func uncommittedCountTracksTotalFiles() {
        let status = GitStatus(
            isGitRepo: true,
            branch: "main",
            headSha: "abc123",
            ahead: 1,
            behind: 0,
            dirtyCount: 2,
            untrackedCount: 1,
            stagedCount: 1,
            files: [],
            totalFiles: 4,
            addedLines: 10,
            removedLines: 3,
            stashCount: 0,
            lastCommitMessage: "feat: test",
            lastCommitDate: "2026-03-05T00:00:00Z",
            recentCommits: []
        )

        #expect(status.uncommittedCount == 4)
        #expect(status.isClean == false)
    }

    @Test(arguments: [
        (" M", "Modified"),
        ("A ", "Added"),
        ("D ", "Deleted"),
        ("R ", "Renamed"),
        ("C ", "Copied"),
        ("??", "Untracked"),
        ("!!", "Ignored"),
        ("UU", "Conflict"),
        ("AA", "Conflict"),
        ("DD", "Conflict"),
        ("XY", "Changed"),
    ])
    func fileStatusLabelMapping(status: String, expected: String) {
        let file = GitFileStatus(status: status, path: "README.md", addedLines: nil, removedLines: nil)
        #expect(file.label == expected)
        #expect(file.id == "README.md")
    }

    @Test func extensionInfoIdUsesName() {
        let ext = ExtensionInfo(name: "search", path: "~/.pi/agent/extensions/search", kind: "directory")
        #expect(ext.id == "search")
    }
}

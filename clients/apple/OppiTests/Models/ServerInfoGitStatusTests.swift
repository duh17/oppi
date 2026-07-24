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
            "packageName": "@earendil-works/pi-coding-agent",
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
        #expect(decoded.capabilities == nil)
        #expect(decoded.stats.workspaceCount == 3)
    }

    @Test func decodeServerInfoStreamCapabilities() throws {
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
          "capabilities": {
            "sessionStream": { "version": 1 },
            "dictationStream": { "version": 1 },
            "appEventStream": { "version": 1 },
            "extensionNativeUI": {
              "version": 1,
              "capabilities": [
                "extension-native-ui:v1:text-fallback",
                "extension-native-ui:v1:prompt-native",
                "extension-native-ui:v1:surface-native",
                "extension-native-ui:v1:osc8-links"
              ]
            }
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
        #expect(decoded.capabilities?.sessionStream?.version == 1)
        #expect(decoded.capabilities?.dictationStream?.version == 1)
        #expect(decoded.capabilities?.appEventStream?.version == 1)
        #expect(decoded.capabilities?.extensionNativeUI?.version == 1)
        #expect(decoded.capabilities?.extensionNativeUI?.capabilities == [
            "extension-native-ui:v1:text-fallback",
            "extension-native-ui:v1:prompt-native",
            "extension-native-ui:v1:surface-native",
            "extension-native-ui:v1:osc8-links",
        ])
        #expect(decoded.capabilities?.hasRequiredSplitStreamCapabilities == true)
    }

    @Test func requiredSplitStreamCapabilitiesIgnoreOptionalAudio() {
        let capabilities = ServerInfo.Capabilities(
            sessionStream: .init(version: 1),
            dictationStream: nil,
            appEventStream: nil,
            extensionNativeUI: nil
        )

        #expect(capabilities.hasRequiredSplitStreamCapabilities)
        #expect(capabilities.missingRequiredSplitStreamCapabilities.isEmpty)
    }

    @Test func requiredSplitStreamCapabilitiesReportMissingServerUpdatePieces() {
        let capabilities = ServerInfo.Capabilities(
            sessionStream: nil,
            dictationStream: nil,
            appEventStream: nil,
            extensionNativeUI: nil
        )

        #expect(capabilities.missingRequiredSplitStreamCapabilities == [
            "sessionStream",
        ])
        #expect(!capabilities.hasRequiredSplitStreamCapabilities)
        #expect(ServerInfo.Capabilities.missingRequiredSplitStreamCapabilities(in: nil) == [
            "sessionStream",
        ])
    }

    @Test func providerQuotaSectionPresentationRequiresAuthUsageOrError() {
        #expect(makeProviderQuota().shouldPresentSection == false)
        #expect(makeProviderQuota(authenticated: true).shouldPresentSection)
        #expect(makeProviderQuota(error: "network timeout").shouldPresentSection)
        #expect(makeProviderQuota(windows: [makeQuotaWindow(remainingPercent: 75)]).shouldPresentSection)
    }

    @Test func providerQuotaBadgesOnlyAppearForAuthenticatedMatchingProvider() {
        let quotas = ProviderQuotasInfo(
            providers: [
                makeProviderQuota(
                    providerId: "openai-codex",
                    displayName: "Codex",
                    authenticated: true,
                    windows: [
                        makeQuotaWindow(key: "five_hour", shortLabel: "5h", remainingPercent: 62),
                        makeQuotaWindow(
                            key: "weekly",
                            shortLabel: "7d",
                            limitWindowSeconds: 7 * 24 * 60 * 60,
                            remainingPercent: 18,
                            includeWeekdayInReset: true
                        ),
                    ]
                ),
                makeProviderQuota(
                    providerId: "xai",
                    displayName: "xAI",
                    authenticated: true,
                    windows: [
                        makeQuotaWindow(
                            key: "weekly",
                            shortLabel: "7d",
                            limitWindowSeconds: 7 * 24 * 60 * 60,
                            remainingPercent: 76,
                            includeWeekdayInReset: true
                        ),
                    ]
                ),
            ],
            fetchedAt: 0
        )

        #expect(quotas.providerBadges(for: "anthropic").isEmpty)
        #expect(makeProviderQuota(authenticated: false).providerBadges.isEmpty)
        #expect(quotas.providerBadges(for: "openai-codex") == [
            .init(label: "5h 62%", tone: .green),
            .init(label: "7d 18%", tone: .red),
        ])
        #expect(quotas.providerBadges(for: "xai") == [
            .init(label: "7d 76%", tone: .green),
        ])
    }

    @Test func providerQuotaBadgeToneThresholdsMatchUiColors() {
        #expect(ProviderQuota.badgeTone(for: 80) == .green)
        #expect(ProviderQuota.badgeTone(for: 50) == .orange)
        #expect(ProviderQuota.badgeTone(for: 20) == .red)
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
            uploadProtocol: nil,
            images: nil,
            capabilities: nil,
            stats: .init(workspaceCount: 0, activeSessionCount: 0, totalSessionCount: 0, skillCount: 0, modelCount: 0)
        )
    }

    private func makeProviderQuota(
        providerId: String = "openai-codex",
        displayName: String = "Codex",
        authenticated: Bool = false,
        windows: [ProviderQuota.Window] = [],
        error: String? = nil
    ) -> ProviderQuota {
        ProviderQuota(
            providerId: providerId,
            displayName: displayName,
            authenticated: authenticated,
            planType: nil,
            windows: windows,
            credits: nil,
            prepaidBalanceCents: nil,
            fetchedAt: 0,
            error: error
        )
    }

    private func makeQuotaWindow(
        key: String = "five_hour",
        shortLabel: String = "5h",
        title: String? = nil,
        limitWindowSeconds: Int? = 5 * 60 * 60,
        remainingPercent: Double,
        includeWeekdayInReset: Bool = false
    ) -> ProviderQuota.Window {
        ProviderQuota.Window(
            key: key,
            shortLabel: shortLabel,
            title: title ?? shortLabel,
            usedPercent: 100 - remainingPercent,
            remainingPercent: remainingPercent,
            limitWindowSeconds: limitWindowSeconds,
            resetAt: 1_700_000_000,
            includeWeekdayInReset: includeWeekdayInReset
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
        let ext = ExtensionInfo(name: "search", path: "~/.pi/agent/extensions/search", kind: "directory", source: "pi")
        #expect(ext.id == "search")
    }

    @Test func extensionInfoSubtitleShowsLocation() {
        let global = ExtensionInfo(name: "search", path: "/Users/me/.pi/agent/extensions/search", kind: "directory", source: "pi")
        let project = ExtensionInfo(name: "local", path: "/Users/me/workspace/oppi/.pi/extensions/local.ts", kind: "file", source: "pi")

        #expect(global.locationLabel == "~/.pi/agent/extensions")
        #expect(project.locationLabel == ".pi/extensions")
        #expect(project.subtitle == ".pi/extensions · file")
    }

    @Test func extensionInfoOppiSource() {
        let oppi = ExtensionInfo(name: "ask", path: "oppi-server", kind: "built-in", source: "oppi")
        #expect(oppi.isOppi)
        #expect(oppi.locationLabel == "oppi")
        #expect(oppi.subtitle == "built-in")

        let pi = ExtensionInfo(name: "memory", path: "~/.pi/agent/extensions/memory.ts", kind: "file", source: "pi")
        #expect(!pi.isOppi)
    }

    @Test func extensionInfoRequiresSourceWhenDecoding() {
        let json = #"{"name":"legacy","path":"~/.pi/agent/extensions/legacy.ts","kind":"file"}"#
        #expect((try? JSONDecoder().decode(ExtensionInfo.self, from: Data(json.utf8))) == nil)
    }
}

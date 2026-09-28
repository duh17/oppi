import Foundation
import Testing
@testable import Oppi

// Fixture keys from `ssh-keygen -t ed25519` / `-t ecdsa -b 256`; fingerprints
// are what `ssh-keygen -lf` prints for them.
private let ed25519Key = SSHHostKey(
    openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICEmPT4AwDDNF/jRkCvAZ/TxlKB3mSudmbMh+spP47nX"
)
private let ecdsaKey = SSHHostKey(
    openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGNC/9YZFMBtoEc2XPfKa/"
        + "IEllbZDt0a1jsgNwg3W7Uq9EbEvDeybBPRF88UJlDrlE7XnxW5YTsytCs72RG+fpc="
)

@Suite("SSH host key trust on first use")
struct SSHKnownHostsTests {
    private let defaults: UserDefaults
    private let knownHosts: SSHKnownHosts

    init() throws {
        let suite = "SSHKnownHostsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        knownHosts = SSHKnownHosts(defaults: defaults)
    }

    @Test func firstKeyIsUnknownUntilTrustedThenAccepted() {
        let host = "mac-studio.tail1234.ts.net"
        #expect(knownHosts.verdict(host: host, port: 22, presented: ed25519Key) == .unknown)

        knownHosts.trust(ed25519Key, host: host, port: 22)
        #expect(knownHosts.verdict(host: host, port: 22, presented: ed25519Key) == .trusted)
    }

    @Test func changedKeyIsRejectedAgainstTheTrustedOne() {
        let host = "mac-studio.tail1234.ts.net"
        knownHosts.trust(ed25519Key, host: host, port: 22)

        #expect(knownHosts.verdict(host: host, port: 22, presented: ecdsaKey) == .mismatch(saved: ed25519Key))
        // A mismatch never replaces the trusted key.
        #expect(knownHosts.savedKey(host: host, port: 22) == ed25519Key)
    }

    @Test func dnsCaseAndRootDotNameTheSameHost() {
        knownHosts.trust(ed25519Key, host: "Mac-Studio.tail1234.ts.net.", port: 22)
        #expect(knownHosts.verdict(host: "mac-studio.tail1234.ts.net", port: 22, presented: ecdsaKey)
            == .mismatch(saved: ed25519Key))
    }

    @Test func hostsAndPortsAreTrustedSeparately() {
        knownHosts.trust(ed25519Key, host: "mac-studio", port: 22)
        #expect(knownHosts.verdict(host: "mac-mini", port: 22, presented: ed25519Key) == .unknown)
        #expect(knownHosts.verdict(host: "mac-studio", port: 2222, presented: ed25519Key) == .unknown)
    }

    @Test func forgettingTheKeyRequiresTrustAgain() {
        knownHosts.trust(ed25519Key, host: "mac-studio", port: 22)
        knownHosts.forget(host: "mac-studio", port: 22)
        #expect(knownHosts.verdict(host: "mac-studio", port: 22, presented: ecdsaKey) == .unknown)
    }

    @Test func fingerprintMatchesSSHKeygen() {
        #expect(ed25519Key.fingerprint == "SHA256:KngS8BrErNUxDUfE/4Re399CQhR6IQ+VhK+gZXyJS0w")
        #expect(ecdsaKey.fingerprint == "SHA256:Aq+GFp0XROK1YmQN+TBTJsStzYumXWuuXZH7anJhcxk")
        #expect(ecdsaKey.algorithm == "ecdsa-sha2-nistp256")
    }
}

@Suite("SSH setup probe parsing")
struct SSHPreflightProbeTests {
    private static func output(
        node: String = "/opt/homebrew/bin/node",
        nodeVersion: String = "v22.19.0",
        npm: String = "/opt/homebrew/bin/npm",
        git: String = "/opt/homebrew/bin/git",
        oppi: String = "",
        clt: String = "1",
        end: Bool = true
    ) -> String {
        """
        user=chen
        kernel=Darwin
        release=25.1.0
        arch=arm64
        macos=26.1
        node=\(node)
        npm=\(npm)
        git=\(git)
        oppi=\(oppi)
        node_version=\(nodeVersion)
        clt=\(clt)
        \(end ? "end=1" : "")
        """
    }

    private func statuses(_ report: SSHPreflightReport) -> [String: SSHPreflightCheck.Status] {
        Dictionary(uniqueKeysWithValues: report.checks.map { ($0.title, $0.status) })
    }

    @Test func readyMacReportsEveryPrerequisite() throws {
        let report = try SSHPreflightProbe.parse(Self.output())
        #expect(report.user == "chen")
        #expect(report.isMacOS)
        #expect(statuses(report) == [
            "System": .ok, "Node.js": .ok, "npm": .ok, "git": .ok, "Oppi": .info,
        ])
        #expect(report.checks.first { $0.title == "System" }?.detail == "macOS 26.1 (arm64)")
    }

    @Test func installedOppiIsReported() throws {
        let report = try SSHPreflightProbe.parse(Self.output(oppi: "/opt/homebrew/bin/oppi"))
        #expect(report.oppiPath == "/opt/homebrew/bin/oppi")
        #expect(statuses(report)["Oppi"] == .ok)
    }

    @Test func freshMacLacksNodeNpmAndRealGit() throws {
        // sshd PATH on a new Mac: only the /usr/bin/git stub, no Command Line Tools.
        let report = try SSHPreflightProbe.parse(
            Self.output(node: "", nodeVersion: "", npm: "", git: "/usr/bin/git", clt: "0")
        )
        #expect(statuses(report) == [
            "System": .ok, "Node.js": .missing, "npm": .missing, "git": .missing, "Oppi": .info,
        ])
    }

    @Test func systemGitCountsOnceCommandLineToolsAreInstalled() throws {
        let report = try SSHPreflightProbe.parse(Self.output(git: "/usr/bin/git", clt: "1"))
        #expect(statuses(report)["git"] == .ok)
    }

    @Test(arguments: [
        ("v22.18.9", SSHPreflightCheck.Status.missing),
        ("v22.19.0", .ok),
        ("v22.19.0-nightly2025", .ok),
        ("v23.0.0", .ok),
        ("v20.19.4", .missing),
        ("garbage", .missing),
    ])
    func nodeVersionMustMeetServerEngines(version: String, expected: SSHPreflightCheck.Status) throws {
        let report = try SSHPreflightProbe.parse(Self.output(nodeVersion: version))
        #expect(statuses(report)["Node.js"] == expected)
    }

    @Test func loginShellNoiseAndCRLFAreIgnored() throws {
        let noisy = "Last login: Mon\r\nwelcome=to zsh\r\n" + Self.output().replacingOccurrences(of: "\n", with: "\r\n")
        let report = try SSHPreflightProbe.parse(noisy)
        #expect(report.user == "chen")
        #expect(report.nodeVersion == "v22.19.0")
    }

    @Test func outputWithoutEndMarkerIsNotTrusted() {
        #expect(throws: SSHPreflightFailure.probeIncomplete) {
            try SSHPreflightProbe.parse(Self.output(end: false))
        }
        #expect(throws: SSHPreflightFailure.probeIncomplete) {
            try SSHPreflightProbe.parse("")
        }
    }

    @Test func nonMacHostIsFlagged() throws {
        let linux = """
        user=chen
        kernel=Linux
        release=6.8.0
        arch=x86_64
        macos=
        node=/usr/bin/node
        npm=/usr/bin/npm
        git=/usr/bin/git
        oppi=
        node_version=v22.20.0
        clt=0
        end=1
        """
        let report = try SSHPreflightProbe.parse(linux)
        #expect(!report.isMacOS)
        #expect(statuses(report)["System"] == .missing)
        // The Command Line Tools rule only applies to the macOS stub.
        #expect(statuses(report)["git"] == .ok)
    }
}

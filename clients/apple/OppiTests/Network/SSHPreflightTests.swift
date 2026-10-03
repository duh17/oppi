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
    private let knownHosts = SSHKnownHosts(keychain: SSHKeychain(service: "SSHKnownHostsTests.\(UUID().uuidString)"))

    @Test func firstKeyIsUnknownUntilTrustedThenAccepted() throws {
        let host = "mac-studio.tail1234.ts.net"
        #expect(try knownHosts.verdict(host: host, port: 22, presented: ed25519Key) == .unknown)
        try knownHosts.trust(ed25519Key, host: host, port: 22)
        defer { try? knownHosts.forget(host: host, port: 22) }
        #expect(try knownHosts.verdict(host: host, port: 22, presented: ed25519Key) == .trusted)
        // A fresh Keychain lookup reads the persisted trusted key.
        #expect(try knownHosts.savedKey(host: host, port: 22) == ed25519Key)
    }

    @Test func changedKeyIsRejectedAgainstTheTrustedOne() throws {
        let host = "mac-studio.tail1234.ts.net"
        try knownHosts.trust(ed25519Key, host: host, port: 22)
        defer { try? knownHosts.forget(host: host, port: 22) }
        #expect(try knownHosts.verdict(host: host, port: 22, presented: ecdsaKey) == .mismatch(saved: ed25519Key))
        // A mismatch never replaces the trusted key.
        #expect(try knownHosts.savedKey(host: host, port: 22) == ed25519Key)
    }

    @Test func dnsCaseAndRootDotNameTheSameHost() throws {
        try knownHosts.trust(ed25519Key, host: "Mac-Studio.tail1234.ts.net.", port: 22)
        defer { try? knownHosts.forget(host: "mac-studio.tail1234.ts.net", port: 22) }
        #expect(try knownHosts.verdict(host: "mac-studio.tail1234.ts.net", port: 22, presented: ecdsaKey)
            == .mismatch(saved: ed25519Key))
    }

    @Test func hostsAndPortsAreTrustedSeparately() throws {
        try knownHosts.trust(ed25519Key, host: "mac-studio", port: 22)
        defer { try? knownHosts.forget(host: "mac-studio", port: 22) }
        #expect(try knownHosts.verdict(host: "mac-mini", port: 22, presented: ed25519Key) == .unknown)
        #expect(try knownHosts.verdict(host: "mac-studio", port: 2222, presented: ed25519Key) == .unknown)
    }

    @Test func forgettingTheKeyRequiresTrustAgain() throws {
        try knownHosts.trust(ed25519Key, host: "mac-studio", port: 22)
        try knownHosts.forget(host: "mac-studio", port: 22)
        #expect(try knownHosts.verdict(host: "mac-studio", port: 22, presented: ecdsaKey) == .unknown)
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
        tailscale: String = "/usr/local/bin/tailscale",
        oppiStatus: String? = nil,
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
        tailscale=\(tailscale)
        node_version=\(nodeVersion)
        clt=\(clt)
        \(oppiStatus.map { "oppi_status=\($0)" } ?? "")
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
            "System": .ok, "Node.js": .ok, "npm": .ok, "git": .ok, "Tailscale CLI": .ok,
            "Oppi": .info, "Tailscale HTTPS": .info,
        ])
        #expect(!report.isReadyToPair)
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
            "System": .ok, "Node.js": .missing, "npm": .missing, "git": .missing, "Tailscale CLI": .ok,
            "Oppi": .info, "Tailscale HTTPS": .info,
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

    // `oppi status --json` as the server prints it: pretty-printed, wrapped in `{ok, data}`.
    private static let oppiStatusLine = #"{ "ok": true, "data": { "status": { "paired": true, "dataDir": "/Users/chen/.config/oppi", "#
        + #""server": { "host": "0.0.0.0", "port": 7749, "transport": "https", "tlsMode": "tailscale", "trustedPeers": [] } } } }"#

    @Test func macServingTailscaleHTTPSIsReadyToPair() throws {
        let report = try SSHPreflightProbe.parse(
            Self.output(oppi: "/opt/homebrew/bin/oppi", oppiStatus: Self.oppiStatusLine)
        )
        #expect(report.oppiStatus == SSHOppiStatus(json: Self.oppiStatusLine))
        #expect(report.oppiStatus?.paired == true)
        #expect(report.oppiStatus?.port == 7749)
        #expect(statuses(report)["Tailscale HTTPS"] == .ok)
        #expect(statuses(report)["Tailscale CLI"] == .ok)
        #expect(report.isReadyToPair)
    }

    @Test(arguments: [
        #"{"ok":true,"data":{"status":{"paired":true,"server":{"port":7749,"transport":"http","tlsMode":"disabled"}}}}"#,
        #"{"ok":true,"data":{"status":{"paired":true,"server":{"port":7749,"transport":"https","tlsMode":"self-signed"}}}}"#,
    ])
    func serverWithoutTailscaleCertificateFailsTheHTTPSCheck(json: String) throws {
        let report = try SSHPreflightProbe.parse(Self.output(oppi: "/opt/homebrew/bin/oppi", oppiStatus: json))
        #expect(statuses(report)["Tailscale HTTPS"] == .missing)
        #expect(!report.isReadyToPair)
    }

    @Test func missingTailscaleCLIBlocksReadiness() throws {
        let report = try SSHPreflightProbe.parse(
            Self.output(oppi: "/opt/homebrew/bin/oppi", tailscale: "", oppiStatus: Self.oppiStatusLine)
        )
        #expect(statuses(report)["Tailscale CLI"] == .missing)
        #expect(!report.isReadyToPair)
    }

    @Test(arguments: [
        "not json", "{\"ok\":true,\"data\":", "[1,2]", "null",
        #"{"paired":true,"server":{"port":7749,"transport":"https","tlsMode":"tailscale"}}"#,
    ])
    func unreadableOppiStatusIsInformationalNotFatal(json: String) throws {
        let report = try SSHPreflightProbe.parse(Self.output(oppi: "/opt/homebrew/bin/oppi", oppiStatus: json))
        #expect(report.oppiStatus == nil)
        #expect(statuses(report)["Tailscale HTTPS"] == .info)
        #expect(statuses(report)["Oppi"] == .ok)
        #expect(!report.isReadyToPair)
    }

    @Test func missingCheckBlocksReadinessEvenWhenOppiServesTailscaleHTTPS() throws {
        let report = try SSHPreflightProbe.parse(
            Self.output(npm: "", oppi: "/opt/homebrew/bin/oppi", oppiStatus: Self.oppiStatusLine)
        )
        #expect(!report.isReadyToPair)
    }

    @Test func statusWithoutEndMarkerIsNotTrusted() {
        #expect(throws: SSHPreflightFailure.probeIncomplete) {
            try SSHPreflightProbe.parse(
                Self.output(oppi: "/opt/homebrew/bin/oppi", oppiStatus: Self.oppiStatusLine, end: false)
            )
        }
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
        tailscale=
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

@Suite("SSH pair invite mint")
struct SSHPairMintTests {
    private static let httpsStatus = #"{"ok":true,"data":{"status":{"paired":true,"server":{"port":7749,"transport":"https","tlsMode":"self-signed"}}}}"#
    private static let httpStatus = #"{"ok":true,"data":{"status":{"paired":true,"server":{"port":7749,"transport":"http","tlsMode":"disabled"}}}}"#

    private static func statusOutput(_ json: String, end: Bool = true) -> String {
        "oppi_status=\(json)\n" + (end ? "end=1\n" : "")
    }

    private static let inviteJSON = """
    {"name":"studio","pairingToken":"pt","fingerprint":"sha256:abc","host":"studio.local","port":7749,"scheme":"https","inviteURL":"oppi://connect?host=studio.local"}
    """

    @Test func httpsStatusAllowsMintAndHTTPDoesNot() {
        #expect(SSHPairMint.servesHTTPS(Self.statusOutput(Self.httpsStatus)))
        #expect(!SSHPairMint.servesHTTPS(Self.statusOutput(Self.httpStatus)))
        #expect(!SSHPairMint.servesHTTPS(Self.statusOutput(Self.httpsStatus, end: false)))
        #expect(!SSHPairMint.servesHTTPS("oppi_status=not json\nend=1\n"))
    }

    @Test func selfSignedHTTPSCanPairWithoutTailscale() throws {
        let report = try SSHPreflightProbe.parse("""
        user=chen
        kernel=Darwin
        release=25.1.0
        arch=arm64
        macos=26.1
        node=/opt/homebrew/bin/node
        node_version=v22.19.0
        npm=/opt/homebrew/bin/npm
        git=/usr/bin/git
        oppi=/usr/local/bin/oppi
        tailscale=
        clt=1
        oppi_status=\(Self.httpsStatus)
        end=1
        """)
        #expect(report.canPairOverSSH)
        #expect(!report.isReadyToPair)
    }

    @Test func pairScriptIsFixedAndDoesNotTakeSecrets() {
        #expect(SSHPairMint.pairScript.contains("exec oppi pair --json"))
        #expect(!SSHPairMint.pairScript.contains("--ttl"))
        #expect(!SSHPairMint.pairScript.contains("--show-token"))
        #expect(!SSHPairMint.pairScript.contains("--host"))
        #expect(!SSHPairMint.statusScript.contains("oppi pair"))
        #expect(SSHPairMint.statusScript.contains("https://127.0.0.1:${port}/health"))
        #expect(SSHPairMint.statusScript.contains("curl -sk --max-time 5"))
    }

    @Test func tailscaleNameDoesNotDialTheSystemNetwork() {
        #expect(SSHPairDial.route(host: "studio.local", tailnetRunning: false) == .direct)
        #expect(SSHPairDial.route(host: "oppi.example.com", tailnetRunning: true) == .direct)
        #expect(SSHPairDial.route(host: "studio.tail1234.ts.net", tailnetRunning: true) == .tailnet)
        #expect(SSHPairDial.route(host: "studio.tail1234.ts.net", tailnetRunning: false) == .tailnetRequired)
    }

    @Test func inviteJSONDecodesAndRejectsUnsafeOutput() throws {
        let invite = try SSHPairMint.invite(from: "\n" + Self.inviteJSON + "\n")
        #expect(invite.inviteURL == "oppi://connect?host=studio.local")
        #expect(invite.scheme == "https")
        #expect(throws: SSHPreflightFailure.inviteInvalid) {
            try SSHPairMint.invite(from: Self.inviteJSON.replacingOccurrences(of: "https", with: "http"))
        }
        #expect(throws: SSHPreflightFailure.inviteInvalid) {
            try SSHPairMint.invite(from: "notice\n" + Self.inviteJSON)
        }
        #expect(throws: SSHPreflightFailure.inviteInvalid) {
            try SSHPairMint.invite(from: "")
        }
        let evil = Self.inviteJSON.replacingOccurrences(
            of: "oppi://connect?host=studio.local",
            with: "oppi://evil"
        )
        let web = Self.inviteJSON.replacingOccurrences(
            of: "oppi://connect?host=studio.local",
            with: "https://connect"
        )
        #expect(throws: SSHPreflightFailure.inviteInvalid) {
            try SSHPairMint.invite(from: evil)
        }
        #expect(throws: SSHPreflightFailure.inviteInvalid) {
            try SSHPairMint.invite(from: web)
        }
    }
}

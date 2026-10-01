import CryptoKit
import Foundation

// Transport-free parts of the Mac setup check: SSH host-key trust on first use,
// the read-only probe script, and its parsed report. `SSHPreflightClient` runs
// them over a tailnet socket.

/// An SSH server host key in OpenSSH public-key form (`ssh-ed25519 AAAA…`).
struct SSHHostKey: Equatable, Sendable {
    let openSSH: String

    var algorithm: String {
        String(openSSH.split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// `SHA256:<base64, no padding>`, the format `ssh-keygen -lf` and macOS's
    /// `ssh` first-connection prompt print, so the user can compare them.
    var fingerprint: String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return openSSH
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

enum SSHHostKeyVerdict: Equatable, Sendable {
    case trusted
    /// No key saved for this host yet; the user must confirm the fingerprint.
    case unknown
    /// The host presented a different key than the one the user trusted.
    case mismatch(saved: SSHHostKey)

    static func evaluate(saved: SSHHostKey?, presented: SSHHostKey) -> Self {
        guard let saved else { return .unknown }
        return saved == presented ? .trusted : .mismatch(saved: saved)
    }
}

/// Host keys the user trusted, keyed by dial host and port. This is the only
/// thing the setup check stores; usernames and passwords stay in memory.
struct SSHKnownHosts {
    static let storageKey = "\(AppIdentifiers.subsystem).ssh.knownHosts"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func savedKey(host: String, port: UInt16) -> SSHHostKey? {
        entries[Self.entryKey(host: host, port: port)].map(SSHHostKey.init(openSSH:))
    }

    func verdict(host: String, port: UInt16, presented: SSHHostKey) -> SSHHostKeyVerdict {
        SSHHostKeyVerdict.evaluate(saved: savedKey(host: host, port: port), presented: presented)
    }

    func trust(_ key: SSHHostKey, host: String, port: UInt16) {
        var entries = entries
        entries[Self.entryKey(host: host, port: port)] = key.openSSH
        defaults.set(entries, forKey: Self.storageKey)
    }

    func forget(host: String, port: UInt16) {
        var entries = entries
        entries.removeValue(forKey: Self.entryKey(host: host, port: port))
        defaults.set(entries, forKey: Self.storageKey)
    }

    private var entries: [String: String] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    /// DNS names are case-insensitive and may carry the root dot.
    static func entryKey(host: String, port: UInt16) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return "\(name):\(port)"
    }
}

// MARK: - Probe

/// Read-only facts about the Mac, gathered with one non-interactive exec.
///
/// The exec command is `/bin/sh -s` with `script` on stdin, so the user's login
/// shell (zsh, bash, or fish) only has to start `sh`. sshd's non-interactive PATH
/// lacks Homebrew and similar, so the script adopts the login shell's PATH: the
/// one a Terminal install would see from `~/.zprofile` and friends.
enum SSHPreflightProbe {
    static let command = "/bin/sh -s"

    static let script = """
    login_path=$("${SHELL:-/bin/sh}" -lc 'printf "\\nOPPI_PATH=%s\\n" "$PATH"' </dev/null 2>/dev/null | sed -n 's/^OPPI_PATH=//p' | tail -n 1)
    [ -n "$login_path" ] && PATH=$login_path
    echo "user=$(id -un)"
    echo "kernel=$(uname -s)"
    echo "release=$(uname -r)"
    echo "arch=$(uname -m)"
    echo "macos=$(sw_vers -productVersion 2>/dev/null)"
    for tool in node npm git oppi tailscale; do echo "$tool=$(command -v "$tool" 2>/dev/null)"; done
    echo "node_version=$(node --version 2>/dev/null)"
    if xcode-select -p >/dev/null 2>&1; then echo clt=1; else echo clt=0; fi
    if command -v oppi >/dev/null 2>&1; then echo "oppi_status=$(oppi status --json </dev/null 2>/dev/null | tr -d '\\r\\n')"; fi
    echo end=1

    """

    /// `server/package.json` `engines.node`.
    static let minimumNode = (major: 22, minor: 19, patch: 0)

    /// Parses probe stdout. Output without the final `end=1` line means the
    /// script did not finish, so nothing in it is trusted.
    static func parse(_ output: String) throws(SSHPreflightFailure) -> SSHPreflightReport {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        guard values["end"] == "1", let user = nonEmpty(values["user"]),
              let kernel = nonEmpty(values["kernel"]) else {
            throw .probeIncomplete
        }
        return SSHPreflightReport(
            user: user,
            kernel: kernel,
            release: values["release"] ?? "",
            arch: values["arch"] ?? "",
            macOSVersion: nonEmpty(values["macos"]),
            nodePath: nonEmpty(values["node"]),
            nodeVersion: nonEmpty(values["node_version"]),
            npmPath: nonEmpty(values["npm"]),
            gitPath: nonEmpty(values["git"]),
            oppiPath: nonEmpty(values["oppi"]),
            tailscalePath: nonEmpty(values["tailscale"]),
            oppiStatus: nonEmpty(values["oppi_status"]).flatMap(SSHOppiStatus.init(json:)),
            hasCommandLineTools: values["clt"] == "1"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// The few fields of `oppi status --json` the setup check reads, from the
/// server's `{ok, data: {status}}` envelope.
struct SSHOppiStatus: Equatable, Sendable {
    let paired: Bool?
    let transport: String?
    let tlsMode: String?
    let port: Int?

    /// Nil for anything but the envelope, so a garbled line never fails the report.
    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let envelope = object as? [String: Any],
              let data = envelope["data"] as? [String: Any],
              let status = data["status"] as? [String: Any] else { return nil }
        let server = status["server"] as? [String: Any]
        paired = status["paired"] as? Bool
        transport = server?["transport"] as? String
        tlsMode = server?["tlsMode"] as? String
        port = server?["port"] as? Int
    }

    /// Oppi serves HTTPS with a Tailscale certificate, which the iPhone's
    /// same-account pairing and `*.ts.net` connection both need.
    var servesTailscaleHTTPS: Bool {
        transport?.lowercased() == "https" && tlsMode?.lowercased() == "tailscale"
    }
}

struct SSHPreflightReport: Equatable, Sendable {
    let user: String
    /// `uname -s`: `Darwin` on macOS.
    let kernel: String
    let release: String
    let arch: String
    let macOSVersion: String?
    let nodePath: String?
    let nodeVersion: String?
    let npmPath: String?
    let gitPath: String?
    let oppiPath: String?
    let tailscalePath: String?
    /// Nil when Oppi is not installed or its status was unreadable.
    let oppiStatus: SSHOppiStatus?
    let hasCommandLineTools: Bool

    var isMacOS: Bool { kernel == "Darwin" }

    var checks: [SSHPreflightCheck] {
        [systemCheck, nodeCheck, npmCheck, gitCheck, tailscaleCheck, oppiCheck, tailscaleHTTPSCheck]
    }

    /// Everything passes: the iPhone's Pair button should work.
    var isReadyToPair: Bool {
        checks.allSatisfy { $0.status == .ok }
    }

    private var systemCheck: SSHPreflightCheck {
        let arch = arch.isEmpty ? "" : " (\(arch))"
        if isMacOS {
            return SSHPreflightCheck(title: "System", detail: "macOS \(macOSVersion ?? release)\(arch)", status: .ok)
        }
        return SSHPreflightCheck(
            title: "System",
            detail: "\(kernel) \(release)\(arch). This setup guide is for macOS.",
            status: .missing
        )
    }

    private var nodeCheck: SSHPreflightCheck {
        let minimum = SSHPreflightProbe.minimumNode
        let required = "\(minimum.major).\(minimum.minor)"
        guard nodePath != nil else {
            return SSHPreflightCheck(title: "Node.js", detail: "Not found. Needs \(required) or later.", status: .missing)
        }
        guard let nodeVersion, let version = Self.semver(nodeVersion) else {
            return SSHPreflightCheck(title: "Node.js", detail: "Found, but its version is unreadable.", status: .missing)
        }
        guard !version.lexicographicallyPrecedes([minimum.major, minimum.minor, minimum.patch]) else {
            return SSHPreflightCheck(
                title: "Node.js",
                detail: "\(nodeVersion) is too old. Needs \(required) or later.",
                status: .missing
            )
        }
        return SSHPreflightCheck(title: "Node.js", detail: nodeVersion, status: .ok)
    }

    private var npmCheck: SSHPreflightCheck {
        guard let npmPath else {
            return SSHPreflightCheck(title: "npm", detail: "Not found.", status: .missing)
        }
        return SSHPreflightCheck(title: "npm", detail: npmPath, status: .ok)
    }

    /// macOS ships `/usr/bin/git` as a stub that only offers to install the
    /// Command Line Tools, so it counts only when they are installed.
    private var gitCheck: SSHPreflightCheck {
        guard let gitPath else {
            return SSHPreflightCheck(title: "git", detail: "Not found.", status: .missing)
        }
        if isMacOS, gitPath == "/usr/bin/git", !hasCommandLineTools {
            return SSHPreflightCheck(
                title: "git",
                detail: "Needs the Xcode Command Line Tools (xcode-select --install).",
                status: .missing
            )
        }
        return SSHPreflightCheck(title: "git", detail: gitPath, status: .ok)
    }

    private var oppiCheck: SSHPreflightCheck {
        guard let oppiPath else {
            return SSHPreflightCheck(title: "Oppi", detail: "Not installed yet.", status: .info)
        }
        var detail = "Installed at \(oppiPath)"
        if let paired = oppiStatus?.paired {
            detail += paired ? ". A device is paired." : ". No device is paired yet."
        }
        return SSHPreflightCheck(title: "Oppi", detail: detail, status: .ok)
    }

    /// Same-account pairing asks `tailscale whois` who is calling.
    private var tailscaleCheck: SSHPreflightCheck {
        guard let tailscalePath else {
            return SSHPreflightCheck(
                title: "Tailscale CLI",
                detail: "Not found. Oppi uses it to confirm a pairing request comes from your account.",
                status: .missing
            )
        }
        return SSHPreflightCheck(title: "Tailscale CLI", detail: tailscalePath, status: .ok)
    }

    private var tailscaleHTTPSCheck: SSHPreflightCheck {
        let title = "Tailscale HTTPS"
        guard oppiPath != nil else {
            return SSHPreflightCheck(title: title, detail: "Checked once Oppi is installed.", status: .info)
        }
        guard let oppiStatus, oppiStatus.transport != nil else {
            return SSHPreflightCheck(
                title: title,
                detail: "Could not read the server's settings from `oppi status --json`.",
                status: .info
            )
        }
        if oppiStatus.servesTailscaleHTTPS {
            let port = oppiStatus.port.map { " on port \($0)" } ?? ""
            return SSHPreflightCheck(title: title, detail: "Serving HTTPS with a Tailscale certificate\(port).", status: .ok)
        }
        let transport = oppiStatus.transport?.uppercased() ?? "unknown"
        let tlsMode = oppiStatus.tlsMode ?? "unknown"
        return SSHPreflightCheck(
            title: title,
            detail: "The server is set to \(transport) with \(tlsMode) TLS. Pairing from this iPhone needs HTTPS with a Tailscale certificate.",
            status: .missing
        )
    }

    /// `v22.19.0` → `[22, 19, 0]`; missing components count as 0.
    private static func semver(_ value: String) -> [Int]? {
        let trimmed = value.hasPrefix("v") ? value.dropFirst() : Substring(value)
        let core = trimmed.split(separator: "-").first ?? trimmed
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        let minor = parts.count > 1 ? parts[1] ?? 0 : 0
        let patch = parts.count > 2 ? parts[2] ?? 0 : 0
        return [major, minor, patch]
    }
}

struct SSHPreflightCheck: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case ok
        /// A prerequisite the Mac lacks.
        case missing
        /// Neither good nor bad, e.g. Oppi not installed yet.
        case info
    }

    let title: String
    let detail: String
    let status: Status

    var id: String { title }
}

// MARK: - Failures

/// Why a setup check stopped. Each case maps to one inline message.
enum SSHPreflightFailure: Error, Equatable, Sendable {
    case tailnetNotRunning
    case dialFailed(String)
    case dialTimedOut
    /// First connection: the user must confirm the fingerprint before a password is sent.
    case unknownHostKey(SSHHostKey)
    case hostKeyMismatch(saved: SSHHostKey, presented: SSHHostKey)
    /// The server does not accept password sign-in.
    case passwordNotAllowed
    case authenticationFailed
    case signInTimedOut
    case handshakeFailed(String)
    case probeRefused
    case probeTimedOut
    case probeIncomplete

    var message: String {
        switch self {
        case .tailnetNotRunning:
            "Tailscale is not connected."
        case .dialFailed(let reason):
            "Could not reach port 22: \(reason). Check that Remote Login is on "
                + "(System Settings → General → Sharing)."
        case .dialTimedOut:
            "Port 22 did not answer. Check that the Mac is awake and Remote Login is on "
                + "(System Settings → General → Sharing)."
        case .unknownHostKey:
            "Oppi has not seen this Mac's SSH key before. Compare the fingerprint "
                + "before you trust it; your password is not sent until you do."
        case .hostKeyMismatch:
            "This Mac's SSH key changed since you trusted it. That can mean macOS "
                + "was reinstalled, or that another machine is answering. Your password was not sent."
        case .passwordNotAllowed:
            "This Mac does not accept password sign-in over SSH."
        case .authenticationFailed:
            "The username or password was not accepted."
        case .signInTimedOut:
            "The Mac did not finish SSH sign-in in time."
        case .handshakeFailed(let reason):
            "SSH sign-in failed: \(reason)"
        case .probeRefused:
            "The Mac refused to run the check command."
        case .probeTimedOut:
            "The check command did not finish in time."
        case .probeIncomplete:
            "The check command ended before reporting all results."
        }
    }
}

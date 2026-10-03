import Foundation

// Transport-free parts of the read-only Mac setup check. Host trust is shared
// with interactive SSH and lives in SSHHostTrust.swift; probe concerns stay here.

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

    /// Any HTTPS Oppi, including self-signed LAN and a public origin.
    /// SSH pairing uses this. Same-account Tailscale pairing still requires
    /// `servesTailscaleHTTPS`.
    var servesHTTPS: Bool {
        transport?.lowercased() == "https"
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

    /// Everything passes: same-account Tailscale pairing should work.
    var isReadyToPair: Bool {
        checks.allSatisfy { $0.status == .ok }
    }

    /// Oppi is installed and already serving HTTPS. SSH pairing does not
    /// require the Tailscale CLI or a Tailscale certificate.
    var canPairOverSSH: Bool {
        oppiPath != nil && oppiStatus?.servesHTTPS == true
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
            detail: "The server is set to \(transport) with \(tlsMode) TLS. Same-account Tailscale pairing needs a Tailscale certificate. SSH pairing can use any HTTPS Oppi is already serving.",
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
    /// Status did not show HTTPS, so no invite command was sent.
    case serverNotServingHTTPS
    /// `oppi pair --json` failed. The invite text is not included.
    case inviteRefused
    /// Stdout was not a usable HTTPS invite. The body is not included.
    case inviteInvalid

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
        case .serverNotServingHTTPS:
            "Oppi is not serving HTTPS on this Mac. Start `oppi serve`, then try again."
        case .inviteRefused:
            "The server did not issue a pairing invite. Start `oppi serve`, then try again."
        case .inviteInvalid:
            "The server's pairing invite was not usable. Request a fresh one and try again."
        }
    }
}

// MARK: - SSH invite mint

/// Where an SSH setup or pair connection is dialed.
enum SSHPairDial {
    enum Route: Equatable, Sendable {
        case tailnet
        case direct
        /// A `*.ts.net` name while Oppi's Tailscale node is stopped.
        case tailnetRequired
    }

    static func route(host: String, tailnetRunning: Bool) -> Route {
        guard ServerTLSTrustPolicy.isTailscaleHostname(host) else { return .direct }
        return tailnetRunning ? .tailnet : .tailnetRequired
    }
}

/// Fixed remote commands for pairing over SSH. Nothing here is built from
/// the username, host, or password. The client runs the status script first
/// and sends the pair script only when that status says HTTPS and loopback
/// health answered.
enum SSHPairMint {
    static let maxInviteOutput = 16 * 1024

    /// Login-shell PATH, matching the setup probe. sshd's own PATH misses Homebrew.
    static let loginPathPreamble = """
    login_path=$("${SHELL:-/bin/sh}" -lc 'printf "\\nOPPI_PATH=%s\\n" "$PATH"' </dev/null 2>/dev/null | sed -n 's/^OPPI_PATH=//p' | tail -n 1)
    [ -n "$login_path" ] && PATH=$login_path
    """

    /// Prints `end=1` only after loopback `/health` answers. Config that says
    /// HTTPS while `oppi serve` is stopped does not.
    static let statusScript = loginPathPreamble + """

    status=$(oppi status --json </dev/null 2>/dev/null | tr -d '\\r\\n')
    echo "oppi_status=$status"
    transport=$(printf '%s' "$status" | sed -n 's/.*"transport"[[:space:]]*:[[:space:]]*"\\([^\"]*\\)".*/\\1/p' | head -n 1)
    port=$(printf '%s' "$status" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
    case "$port" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    [ "$transport" = "https" ] || exit 0
    body=$(curl -sk --max-time 5 "https://127.0.0.1:${port}/health" || true)
    case "$body" in
      *'"ok":true'*'"protocol":2'*|*'"ok": true'*'"protocol": 2'*) echo end=1 ;;
    esac

    """

    /// Default 90s single-use invite. No `--ttl`, no `--show-token`, no extra arguments.
    static let pairScript = loginPathPreamble + """

    exec oppi pair --json

    """

    static func servesHTTPS(_ output: String) -> Bool {
        guard let status = status(from: output) else { return false }
        return status.servesHTTPS
    }

    /// Nil when the script did not finish or status JSON is missing or garbled.
    static func status(from output: String) -> SSHOppiStatus? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        guard values["end"] == "1" else { return nil }
        return values["oppi_status"].flatMap(SSHOppiStatus.init(json:))
    }

    /// Decodes `oppi pair --json`. Rejects anything that is not a single HTTPS invite.
    /// Does not include the body in the error.
    static func invite(from output: String) throws(SSHPreflightFailure) -> TailscalePairingInvite {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxInviteOutput,
              trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let invite = try? JSONDecoder().decode(TailscalePairingInvite.self, from: Data(trimmed.utf8)),
              !invite.inviteURL.isEmpty,
              invite.scheme.lowercased() == "https",
              let url = URL(string: invite.inviteURL),
              url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "connect" else {
            throw SSHPreflightFailure.inviteInvalid
        }
        return invite
    }
}

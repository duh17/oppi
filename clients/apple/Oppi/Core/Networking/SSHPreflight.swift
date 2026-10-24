import Foundation

// Transport-free parts of the read-only setup check. Host trust is shared
// with interactive SSH and lives in SSHHostTrust.swift; probe concerns stay here.
// The same script runs on macOS and Linux; nothing here is Mac-only.

// MARK: - Probe

/// Read-only facts about a macOS or Linux host, gathered with one non-interactive exec.
///
/// The exec command is `/bin/sh -s` with `script` on stdin, so the user's login
/// shell (zsh, bash, or fish) only has to start `sh`. sshd's non-interactive PATH
/// lacks Homebrew, nvm, and similar, so the script adopts the login shell's PATH:
/// the one a Terminal install would see from `~/.zprofile` or `~/.profile`.
enum SSHPreflightProbe {
    static let command = "/bin/sh -s"

    /// Login-shell PATH, then the installer's own places. Install & Start puts
    /// its `oppi` launcher in `~/.oppi/bin`, which a fresh Mac's PATH lacks,
    /// and that launcher is the one its service runs, so it comes first. The
    /// Node.js it downloads goes last: a Node the user installed still wins.
    static let loginPathPreamble = """
    login_path=$("${SHELL:-/bin/sh}" -lc 'printf "\\nOPPI_PATH=%s\\n" "$PATH"' </dev/null 2>/dev/null | sed -n 's/^OPPI_PATH=//p' | tail -n 1)
    [ -n "$login_path" ] && PATH=$login_path
    [ -d "$HOME/.oppi/bin" ] && PATH="$HOME/.oppi/bin:$PATH"
    [ -d "$HOME/.oppi/runtime/node/bin" ] && PATH="$PATH:$HOME/.oppi/runtime/node/bin"
    """

    /// Sets `healthy=1` when `$status` (`oppi status --json`) says HTTPS and
    /// loopback `/health` answers as Oppi. Config that says HTTPS while the
    /// server is stopped does not. curl is tried first; Node (which Oppi
    /// already needs) and wget cover a Linux host without curl.
    static let healthCheck = """
    healthy=0
    transport=$(printf '%s' "$status" | sed -n 's/.*"transport"[[:space:]]*:[[:space:]]*"\\([^\"]*\\)".*/\\1/p' | head -n 1)
    port=$(printf '%s' "$status" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
    case "$port" in
      ''|*[!0-9]*) port= ;;
    esac
    if [ "$transport" = "https" ] && [ -n "$port" ]; then
      body=
      if command -v curl >/dev/null 2>&1; then
        body=$(curl -sk --max-time 5 "https://127.0.0.1:${port}/health" || true)
      fi
      if [ -z "$body" ] && command -v node >/dev/null 2>&1; then
        body=$(OPPI_PORT="$port" NODE_TLS_REJECT_UNAUTHORIZED=0 node -e 'const h=require("https");const p=process.env.OPPI_PORT;const r=h.get({hostname:"127.0.0.1",port:p,path:"/health",timeout:5000},s=>{let b="";s.on("data",c=>b+=c);s.on("end",()=>process.stdout.write(b));});r.on("error",()=>{});r.on("timeout",()=>r.destroy());' 2>/dev/null || true)
      fi
      if [ -z "$body" ] && command -v wget >/dev/null 2>&1; then
        body=$(wget -qO- --max-redirect=0 --no-proxy --no-hsts --no-check-certificate --timeout=5 "https://127.0.0.1:${port}/health" || true)
      fi
      case "$body" in
        *'"ok":true'*'"protocol":2'*|*'"ok": true'*'"protocol": 2'*) healthy=1 ;;
      esac
    fi
    """

    static let script = loginPathPreamble + """

    echo "user=$(id -un)"
    echo "kernel=$(uname -s)"
    echo "release=$(uname -r)"
    echo "arch=$(uname -m)"
    echo "macos=$(sw_vers -productVersion 2>/dev/null)"
    os=
    if [ -r /etc/os-release ]; then
      os=$(sed -n 's/^PRETTY_NAME="\\(.*\\)"$/\\1/p' /etc/os-release | head -n 1)
      if [ -z "$os" ]; then
        os=$(sed -n 's/^PRETTY_NAME=\\(.*\\)$/\\1/p' /etc/os-release | head -n 1)
      fi
    fi
    echo "os=$os"
    for tool in node git oppi tailscale; do echo "$tool=$(command -v "$tool" 2>/dev/null)"; done
    echo "node_version=$(node --version 2>/dev/null)"
    echo "oppi_node_version=$("$HOME/.oppi/runtime/node/bin/node" --version 2>/dev/null)"
    if xcode-select -p >/dev/null 2>&1; then echo clt=1; else echo clt=0; fi
    if command -v oppi >/dev/null 2>&1; then
      status=$(oppi status --json </dev/null 2>/dev/null | tr -d '\\r\\n')
      echo "oppi_status=$status"
    """ + "\n" + healthCheck + """

      echo "oppi_health=$healthy"
    fi
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
            osRelease: nonEmpty(values["os"]).map(unquote),
            nodePath: nonEmpty(values["node"]),
            nodeVersion: nonEmpty(values["node_version"]),
            oppiNodeVersion: nonEmpty(values["oppi_node_version"]),
            gitPath: nonEmpty(values["git"]),
            oppiPath: nonEmpty(values["oppi"]),
            tailscalePath: nonEmpty(values["tailscale"]),
            oppiStatus: nonEmpty(values["oppi_status"]).flatMap(SSHOppiStatus.init(json:)),
            oppiAnswers: values["oppi_health"] == "1",
            hasCommandLineTools: values["clt"] == "1"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// os-release values are quoted. A sed miss that keeps the quotes still displays the name.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
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
    /// `PRETTY_NAME` from `/etc/os-release` on Linux. Nil on macOS.
    let osRelease: String?
    /// The first `node` on the login PATH (Install & Start's own copy last).
    let nodePath: String?
    let nodeVersion: String?
    /// The Node.js Install & Start downloaded into `~/.oppi/runtime/node`.
    let oppiNodeVersion: String?
    let gitPath: String?
    let oppiPath: String?
    let tailscalePath: String?
    /// Nil when Oppi is not installed or its status was unreadable.
    let oppiStatus: SSHOppiStatus?
    /// Status says HTTPS and loopback `/health` answered as Oppi.
    let oppiAnswers: Bool
    let hasCommandLineTools: Bool

    var isMacOS: Bool { kernel == "Darwin" }
    var isLinux: Bool { kernel == "Linux" }
    /// Oppi's installer and this check support these two. Other kernels stay listed
    /// so the row can say why, instead of pretending the Mac steps apply.
    var isSupportedHost: Bool { isMacOS || isLinux }

    /// What the setup screen offers after a check.
    enum NextStep: Equatable, Sendable {
        /// Oppi answers over HTTPS: pair over SSH.
        case pair
        /// A Mac or Linux machine without a running Oppi: Install & Start.
        /// Node.js, git, and the Tailscale CLI do not block it; the installer
        /// brings its own Node.js and needs neither of the others.
        case install
        /// Neither macOS nor Linux.
        case unsupported
    }

    var nextStep: NextStep {
        guard isSupportedHost else { return .unsupported }
        return canPairOverSSH ? .pair : .install
    }

    var checks: [SSHPreflightCheck] {
        var checks = [systemCheck, nodeCheck, oppiCheck, gitCheck, tailscaleCheck]
        if let tailscaleHTTPSCheck { checks.append(tailscaleHTTPSCheck) }
        // Install & Start is not offered on other systems, so nothing there
        // is something it would take care of.
        guard isSupportedHost else {
            return checks.map { $0.status == .installs ? $0.with(status: .info) : $0 }
        }
        return checks
    }

    /// Oppi is installed and answering over HTTPS. SSH pairing does not
    /// require the Tailscale CLI or a Tailscale certificate.
    var canPairOverSSH: Bool {
        oppiPath != nil && oppiStatus?.servesHTTPS == true && oppiAnswers
    }

    private var systemCheck: SSHPreflightCheck {
        let archSuffix = arch.isEmpty ? "" : " (\(arch))"
        if isMacOS {
            return SSHPreflightCheck(title: "System", detail: "macOS \(macOSVersion ?? release)\(archSuffix)", status: .ok)
        }
        if isLinux {
            let name = osRelease ?? "Linux \(release)"
            return SSHPreflightCheck(title: "System", detail: "\(name)\(archSuffix)", status: .ok)
        }
        return SSHPreflightCheck(
            title: "System",
            detail: "\(kernel) \(release)\(archSuffix). This check supports macOS and Linux.",
            status: .missing
        )
    }

    /// Node.js is what Oppi runs on. A missing or old one never blocks:
    /// Install & Start downloads its own copy and leaves the user's alone.
    private var nodeCheck: SSHPreflightCheck {
        let title = "Node.js"
        if let nodeVersion, Self.meetsMinimumNode(nodeVersion) {
            let ours = nodePath?.hasSuffix("/.oppi/runtime/node/bin/node") == true
            return SSHPreflightCheck(title: title, detail: ours ? "\(nodeVersion), installed by Oppi" : nodeVersion, status: .ok)
        }
        if let oppiNodeVersion, Self.meetsMinimumNode(oppiNodeVersion) {
            return SSHPreflightCheck(title: title, detail: "\(oppiNodeVersion), installed by Oppi", status: .ok)
        }
        let minimum = SSHPreflightProbe.minimumNode
        let detail: String
        if nodePath == nil {
            detail = "Not installed. Install & Start downloads a copy for Oppi to use."
        } else if let nodeVersion, Self.semver(nodeVersion) != nil {
            detail = "\(nodeVersion) is older than Oppi needs (\(minimum.major).\(minimum.minor)). "
                + "Install & Start downloads a separate copy for Oppi and leaves yours alone."
        } else {
            detail = "Found, but its version is unreadable. Install & Start downloads a separate copy for Oppi."
        }
        return SSHPreflightCheck(title: title, detail: detail, status: .installs)
    }

    /// Oppi answers over HTTPS, or Install & Start installs and starts it.
    private var oppiCheck: SSHPreflightCheck {
        let title = "Oppi"
        guard oppiPath != nil else {
            return SSHPreflightCheck(title: title, detail: "Not installed. Install & Start installs it for your account.", status: .installs)
        }
        guard canPairOverSSH else {
            return SSHPreflightCheck(
                title: title,
                detail: "Installed, but not running. Install & Start starts it and keeps it running.",
                status: .installs
            )
        }
        var detail = oppiStatus?.port.map { "Running on port \($0)." } ?? "Running."
        if let paired = oppiStatus?.paired {
            detail += paired ? " A device is paired." : " No device is paired yet."
        }
        return SSHPreflightCheck(title: title, detail: detail, status: .ok)
    }

    /// Optional: neither the installer nor pairing needs git. macOS ships
    /// `/usr/bin/git` as a stub that only offers to install the Command Line
    /// Tools, so it counts only when they are installed.
    private var gitCheck: SSHPreflightCheck {
        guard let gitPath else {
            return SSHPreflightCheck(title: "git", detail: "Not found. Optional: Oppi's Git features use it.", status: .info)
        }
        if isMacOS, gitPath == "/usr/bin/git", !hasCommandLineTools {
            return SSHPreflightCheck(
                title: "git",
                detail: "Optional: Oppi's Git features need the Xcode Command Line Tools (xcode-select --install).",
                status: .info
            )
        }
        return SSHPreflightCheck(title: "git", detail: gitPath, status: .ok)
    }

    /// Optional: only pairing from the Online Machines list asks `tailscale
    /// whois` who is calling. Pairing over SSH does not.
    private var tailscaleCheck: SSHPreflightCheck {
        guard let tailscalePath else {
            return SSHPreflightCheck(
                title: "Tailscale CLI",
                detail: "Not found. Optional: only pairing from Tailscale's Online Machines list needs it.",
                status: .info
            )
        }
        return SSHPreflightCheck(title: "Tailscale CLI", detail: tailscalePath, status: .ok)
    }

    /// Shown once Oppi answers. Pairing over SSH takes any HTTPS; the Online
    /// Machines list needs a Tailscale certificate.
    private var tailscaleHTTPSCheck: SSHPreflightCheck? {
        guard canPairOverSSH, let oppiStatus else { return nil }
        let title = "Tailscale HTTPS"
        if oppiStatus.servesTailscaleHTTPS {
            return SSHPreflightCheck(title: title, detail: "Uses a Tailscale certificate.", status: .ok)
        }
        return SSHPreflightCheck(
            title: title,
            detail: "Uses its own certificate. Pairing here works; pairing from the Online Machines list needs a Tailscale certificate.",
            status: .info
        )
    }

    private static func meetsMinimumNode(_ version: String) -> Bool {
        let minimum = SSHPreflightProbe.minimumNode
        guard let parts = semver(version) else { return false }
        return !parts.lexicographicallyPrecedes([minimum.major, minimum.minor, minimum.patch])
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
        /// Install & Start takes care of it.
        case installs
        /// Something the machine lacks that setup cannot fix (an unsupported system).
        case missing
        /// Neither good nor bad, e.g. an optional tool.
        case info
    }

    let title: String
    let detail: String
    let status: Status

    var id: String { title }

    func with(status: Status) -> SSHPreflightCheck {
        SSHPreflightCheck(title: title, detail: detail, status: status)
    }
}

// MARK: - Address

/// A machine typed into Set Up a Machine: a hostname or IP address, with
/// `:port` when SSH is not on 22 (`[address]:port` for IPv6). A bare IPv6
/// address uses port 22.
struct SSHSetupAddress: Equatable, Sendable {
    static let defaultPort: UInt16 = 22

    let host: String
    let port: UInt16

    init(host: String, port: UInt16 = defaultPort) {
        self.host = host
        self.port = port
    }

    /// Nil for empty text, an empty host, or a port outside 1...65535.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = Substring(trimmed)
        var portText: Substring?
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.firstIndex(of: ":") {
            host = trimmed[..<colon]
            portText = trimmed[trimmed.index(after: colon)...]
        }
        guard !host.isEmpty else { return nil }
        var port = Self.defaultPort
        if let portText {
            guard let parsed = UInt16(portText), parsed != 0 else { return nil }
            port = parsed
        }
        self.init(host: String(host), port: port)
    }

    /// How the address is shown: the host, plus the port when it is not 22.
    var label: String {
        guard port != Self.defaultPort else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
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
    /// This build has no `install.sh` resource.
    case installerMissing
    /// The installer printed `oppi-install: error code=… detail=…`.
    case installFailed(code: String, detail: String)
    /// The installer ended without `done` and exit 0, and without an error line.
    case installIncomplete(exitStatus: Int?)
    case installTimedOut
    /// The connection dropped while the installer ran.
    case installInterrupted

    var message: String {
        switch self {
        case .tailnetNotRunning:
            "Tailscale is not connected."
        case .dialFailed(let reason):
            "Could not reach the machine's SSH port: \(reason). \(Self.sshHint)"
        case .dialTimedOut:
            "The machine's SSH port did not answer. Check that the machine is awake. \(Self.sshHint)"
        case .unknownHostKey:
            "Oppi has not seen this machine's SSH key before. Compare the fingerprint "
                + "before you trust it; your password is not sent until you do."
        case .hostKeyMismatch:
            "This machine's SSH key changed since you trusted it. That can mean the system "
                + "was reinstalled, or that another machine is answering. Your password was not sent."
        case .passwordNotAllowed:
            "This machine does not accept password sign-in over SSH."
        case .authenticationFailed:
            "The username or password was not accepted."
        case .signInTimedOut:
            "The machine did not finish SSH sign-in in time."
        case .handshakeFailed(let reason):
            "SSH sign-in failed: \(reason)"
        case .probeRefused:
            "The machine refused to run the check command."
        case .probeTimedOut:
            "The check command did not finish in time."
        case .probeIncomplete:
            "The check command ended before reporting all results."
        case .serverNotServingHTTPS:
            "Oppi is not running with HTTPS on this machine. Check again, then use Install & Start."
        case .inviteRefused:
            "Oppi on this machine did not issue a pairing invite. Check the machine again, then try again."
        case .inviteInvalid:
            "The server's pairing invite was not usable. Request a fresh one and try again."
        case .installerMissing:
            "This copy of Oppi is missing its installer."
        case .installFailed(let code, let detail):
            detail.isEmpty ? Self.installFailureSummary(code) : "\(Self.installFailureSummary(code)) \(detail)"
        case .installIncomplete(let exitStatus):
            (exitStatus.map { "Setup ended before it finished (exit status \($0))." } ?? "Setup ended before it finished.")
                + " \(Self.retryHint)"
        case .installTimedOut:
            "Setup took longer than \(Self.installTimeoutMinutes) minutes and was stopped. \(Self.retryHint)"
        case .installInterrupted:
            "The connection closed before setup finished. Keep Oppi open while setup runs. \(Self.retryHint)"
        }
    }

    /// What `SSHPreflightClient.installTimeout` allows, for the message.
    static let installTimeoutMinutes = 20

    /// The installer is idempotent: a rerun repairs and finishes.
    private static let retryHint = "Try again; setup picks up where it stopped."

    /// Plain words for the installer's error codes (`install.sh` contract).
    /// An unknown code still says setup stopped and shows the code.
    private static func installFailureSummary(_ code: String) -> String {
        switch code {
        case "node_download": "Could not download Node.js."
        case "checksum": "The Node.js download did not match its published checksum, so it was not used."
        case "npm": "Could not download and install Oppi."
        case "service": "Could not set Oppi up to run in the background."
        case "start_timeout": "Oppi was installed but did not start in time."
        case "unsupported_platform": "Oppi cannot be installed on this kind of computer yet."
        case "busy": "Setup is already running on this machine. Wait for it to finish, then try again."
        case "usage": "The installer did not accept how Oppi started it. Update Oppi on this device and try again."
        default: "Setup stopped (\(code))."
        }
    }

    /// macOS Remote Login and Linux sshd are the same port. The hint names both
    /// so a Linux host is not told to open System Settings.
    private static let sshHint =
        "Turn on SSH: on a Mac, Remote Login in System Settings → General → Sharing; on Linux, the SSH server (sshd)."
}

// MARK: - SSH invite mint

/// Fixed remote commands for pairing over SSH. Nothing here is built from
/// the username, host, or password. The client runs the status script first
/// and sends the pair script only when that status says HTTPS and loopback
/// health answered.
enum SSHPairMint {
    static let maxInviteOutput = 16 * 1024

    /// Prints `end=1` only after loopback `/health` answers
    /// (`SSHPreflightProbe.healthCheck`). Config that says HTTPS while the
    /// server is stopped does not.
    static let statusScript = SSHPreflightProbe.loginPathPreamble + """

    status=$(oppi status --json </dev/null 2>/dev/null | tr -d '\\r\\n')
    echo "oppi_status=$status"
    """ + "\n" + SSHPreflightProbe.healthCheck + """

    [ "$healthy" = 1 ] && echo end=1
    exit 0

    """

    /// Default 90s single-use invite. No `--ttl`, no `--show-token`, no extra arguments.
    static let pairScript = SSHPreflightProbe.loginPathPreamble + """

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

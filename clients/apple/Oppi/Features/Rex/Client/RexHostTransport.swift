import Foundation
import Synchronization

/// How Oppi reaches the host's Rex server: a command on the SSH connection
/// whose stdin and stdout are Rex's local socket. Rex trusts a caller on that
/// socket as the account it runs as, which is the SSH user, so it needs no
/// sign-in or network access of its own. The fallback when Rex is not
/// reached over Tailscale (`RexRoutePlan`).
///
/// As Rex's own apps do over SSH, it runs Rex's bridge, `rex __internal
/// dial-stdio`, after `rex __internal autostart-status`, which starts the
/// account's Rex server first when none runs (unless the host turns
/// autostart off with `REX_AUTOSTART=0`). `rex` is looked for where the
/// official client looks over SSH, in `~/.local/bin` and on the `PATH` that
/// non-interactive SSH commands see, then in the Rex Mac app's managed server
/// (`candidates`). A `rex` too old to have
/// `dial-stdio` (it does not list it in `rex __internal --help`) is skipped,
/// and the bridge falls back to `nc -U` to Rex's socket: in the app's
/// Application Support folder on macOS, in `$XDG_RUNTIME_DIR/rex` or
/// `~/.local/state/rex/run` elsewhere.
///
/// The command says why it failed in its exit status, from the same one exec
/// (nothing extra is asked while Rex runs): 5 when there is no `rex` at all,
/// 4 when no Rex server is listening and none was started, 126 when only
/// `nc` could reach Rex and it is missing or cannot speak Unix sockets
/// (Debian's `netcat-traditional` and BusyBox reject `-U` with exit 1, which
/// would read as a closed connection, so `nc -h` must list `-U` first).
enum RexBridge {
    /// The bridge, starting Rex when it is not running.
    static let command = command(autostart: true)
    /// The bridge to a Rex that runs already: a list or a terminal reading the
    /// host's Rex (`RexMonitor`) must not start one.
    static let commandWithoutAutostart = command(autostart: false)

    /// Either bridge, as a stand-in host recognises it.
    static func isBridge(_ command: String) -> Bool {
        command == Self.command || command == commandWithoutAutostart
    }

    /// The starting bridge passes no `--autostart`, so `rex` decides from the
    /// host's own `REX_AUTOSTART`, as the official client's does; the
    /// background one says `--autostart=false`.
    private static func command(autostart: Bool) -> String {
        let flag = autostart ? "" : " --autostart=false"
        return SSHTerminalRemoteShell.word(
            "f=; for r in \(candidates); do "
                + "[ -x \"$r\" ] || continue; f=1; "
                + "\"$r\" __internal --help 2>&1 | grep -q dial-stdio || continue; "
                + "\"$r\" __internal autostart-status\(flag) >/dev/null 2>&1 || exit 4; "
                + "exec \"$r\" __internal dial-stdio\(flag); done; "
                + "for s in \"$HOME/Library/Application Support/rex/server.sock\" "
                + "\"${XDG_RUNTIME_DIR:-/nonexistent}/rex/server.sock\" \"$HOME/.local/state/rex/run/server.sock\"; do "
                + "[ -S \"$s\" ] && { nc -h 2>&1 | grep -q -e -U || exit 126; exec nc -U \"$s\"; }; done; "
                + "[ -n \"$f\" ] || exit 5; exit 4"
        )
    }

    /// Where `rex` is looked for, in order, as `sh` words. The last is the Rex
    /// Mac app's managed server: of the folders in `RexServer/Versions` named
    /// only by digits, the numerically highest whose `rex` is executable (the
    /// app stages a new build there beside an older `Current`), else
    /// `Current`. No other folder name is ever run. The `case` pattern opens
    /// with `(`: inside `$(…)`, bash's `sh` reads a bare `)` as the end of the
    /// substitution.
    static let candidates: String = {
        let versions = "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions"
        let rex = "Rex Server.app/Contents/MacOS/rex"
        let newest = "d=\"\(versions)\"; n=; for v in \"$d\"/*; do v=${v##*/}; "
            + "case $v in (\"\"|*[!0-9]*) continue ;; esac; "
            + "[ -x \"$d/$v/\(rex)\" ] || continue; "
            + "if [ -z \"$n\" ] || [ \"$v\" -gt \"$n\" ]; then n=$v; fi; done; "
            + "echo \"$d/${n:-Current}/\(rex)\""
        return "\"$HOME/.local/bin/rex\" \"$(command -v rex)\" \"$(\(newest))\""
    }()

    static func failure(exitStatus: Int?) -> RexClientError {
        switch exitStatus {
        case 4: .notRunning
        case 5: .notInstalled
        case 126: .bridgeMissing
        default: .connectionClosed
        }
    }
}

/// A Rex terminal's link to its saved SSH host's Rex: Rex's control
/// connection and each pane's data connection go over its `RexLink`, and side
/// commands (uploads, the theme, keybindings) run on the host's SSH connection
/// beside them, which runs no shell and is probed as a shell's connection is
/// (`SSHConnection.startKeepalive`).
///
/// Over the SSH bridge, Rex rides on that connection, so its end is Rex's end.
/// Over Tailscale, Rex admits this device by its Tailscale identity, as Rex's
/// own apps are admitted, and SSH carries only side commands: the terminal
/// opens with no SSH sign-in (`openOverTailnet`), signs in the first time a
/// side command needs it (`signIn`, which may ask for Face ID or the passcode,
/// as Reconnect does), and an SSH connection that drops is only signed in
/// again by the next side command. It never ends the terminal.
final class RexHostTransport: RexTransport {
    /// Signs in a new SSH connection to the host, for side commands.
    typealias SignIn = @Sendable () async throws -> SSHConnection

    private struct SSH {
        var connection: SSHConnection?
        var signing: Task<SSHConnection, any Error>?
        var closed = false
    }

    let link: RexLink
    var route: RexRoute { link.route }
    private let control: RexControl
    private let signIn: SignIn?
    private let ssh = Mutex(SSH())

    private init(link: RexLink, control: RexControl, connection: SSHConnection?, signIn: SignIn?) {
        self.link = link
        self.control = control
        self.signIn = signIn
        if let connection { adopt(connection) }
    }

    /// Opens Rex's control connection by `plan`'s route (the bridge on
    /// `connection` without one) and says hello. `signIn` signs in again for
    /// side commands should `connection` drop while Rex is reached over
    /// Tailscale.
    static func open(
        connection: SSHConnection,
        plan: RexRoutePlan? = nil,
        signIn: SignIn? = nil,
        reconnectToken: String? = nil,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (RexHostTransport, RexControl) {
        let (link, control) = try await RexLink.connect(
            plan: plan,
            openStream: { try await connection.openStream(command: $0, inboundFlow: $1, sink: $2) },
            run: { try await connection.run($0, maximumOutputBytes: 64 * 1024, timeout: .seconds(10)) },
            // A pane the person opened on this host starts its Rex, as Rex's own client does.
            autostart: true,
            reconnectToken: reconnectToken,
            onWritable: onWritable
        )
        return (RexHostTransport(link: link, control: control, connection: connection, signIn: signIn), control)
    }

    /// Rex over Tailscale with no SSH sign-in, when `plan` has a route there
    /// and Rex welcomes this device; nil otherwise (the caller signs in over
    /// SSH, as before). Side commands sign in with `signIn` when first needed.
    static func openOverTailnet(
        plan: RexRoutePlan,
        signIn: @escaping SignIn,
        reconnectToken: String? = nil,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (RexHostTransport, RexControl)? {
        guard let (link, control) = try await plan.attemptDirect(
            openStream: RexTailnetTransport.noBridge, onWritable: onWritable, reconnectToken: reconnectToken
        ) else {
            return nil
        }
        return (RexHostTransport(link: link, control: control, connection: nil, signIn: signIn), control)
    }

    /// Keeps `connection` probed, and decides what its end means: Rex's end
    /// over the bridge, else only that the next side command signs in again.
    private func adopt(_ connection: SSHConnection) {
        ssh.withLock { $0.connection = connection }
        connection.startKeepalive()
        let channel = connection.channel
        if case .ssh = route {
            channel.closeFuture.whenComplete { [control] _ in control.close() }
        } else {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.ssh.withLock { state in
                    if state.connection?.channel === channel { state.connection = nil }
                }
            }
        }
    }

    /// The SSH connection for a side command: the open one, else one signed in
    /// now (one sign-in at a time, shared by every command that waits on it).
    private func sshConnection() async throws -> SSHConnection {
        enum Next { case ready(SSHConnection), wait(Task<SSHConnection, any Error>) }
        let next = try ssh.withLock { state -> Next in
            guard !state.closed else { throw RexClientError.connectionClosed }
            if let connection = state.connection, connection.channel.isActive { return .ready(connection) }
            if let signing = state.signing { return .wait(signing) }
            guard let signIn else { throw SSHConnectionError.notConnected }
            let signing = Task { try await signIn() }
            state.signing = signing
            return .wait(signing)
        }
        switch next {
        case .ready(let connection):
            return connection
        case .wait(let signing):
            do {
                let connection = try await signing.value
                let closed = ssh.withLock { state -> Bool in
                    state.signing = nil
                    return state.closed
                }
                guard !closed else {
                    connection.close()
                    throw RexClientError.connectionClosed
                }
                if ssh.withLock({ $0.connection?.channel !== connection.channel }) { adopt(connection) }
                return connection
            } catch {
                ssh.withLock { $0.signing = nil }
                throw error
            }
        }
    }

    /// Side commands would sign in first: Rex is reached over Tailscale and no
    /// SSH connection is open. Automatic reads (the theme, keybindings, Herdr)
    /// wait for one rather than ask for Face ID on their own.
    var sideCommandsSignInPending: Bool {
        guard case .tailscale = route else { return false }
        return ssh.withLock { $0.connection?.channel.isActive != true }
    }

    func openData(
        inboundFlow: SSHPTYInboundFlow?, onEvent: @escaping @Sendable (RexSocketEvent) -> Void
    ) async throws -> any RexSocket {
        try await link.open(.data, inboundFlow: inboundFlow, onEvent: onEvent)
    }

    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        try await sshConnection().openStream(command: command, inboundFlow: inboundFlow, sink: sink)
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        // An upload over a slow link needs longer than an API call.
        try await sshConnection().run(
            command, input: input, maximumOutputBytes: 2 * 1024 * 1024,
            timeout: input.count > 64 * 1024 ? .seconds(120) : .seconds(10)
        )
    }

    /// One round trip on what carries Rex: SSH over the bridge, Rex itself
    /// over Tailscale. Either failing closes the connection, as a failed probe
    /// does.
    func checkAlive() async throws {
        switch route {
        case .ssh:
            guard let connection = ssh.withLock({ $0.connection }) else { throw SSHConnectionError.notConnected }
            try await connection.checkAlive()
        case .tailscale:
            do {
                _ = try await control.call("server.status", [:])
            } catch {
                close()
                throw error
            }
        }
    }

    func close() {
        control.close()
        let (connection, signing) = ssh.withLock { state in
            state.closed = true
            defer { state.connection = nil; state.signing = nil }
            return (state.connection, state.signing)
        }
        signing?.cancel()
        connection?.close()
    }

    func cancel() async {
        let channel = ssh.withLock { $0.connection?.channel }
        close()
        _ = try? await channel?.closeFuture.get()
    }
}

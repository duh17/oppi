import Foundation

extension RexTailnetHost {
    /// The stand-in profile a terminal of this Rex is registered and shown
    /// under (`SSHTerminalRegistry`, the switcher, Reconnect). It names the
    /// node and carries `rexTailnet`, which routes its connect to Rex over
    /// Tailscale with no SSH; it is never saved in the SSH host list.
    var profile: SSHTerminalProfile {
        SSHTerminalProfile(id: id, host: dnsName, port: 443, opensRexSessions: true, rexTailnet: url)
    }
}

/// What to say when a Rex reached over Tailscale alone does not let this
/// device in. Rex admits a caller by Tailscale identity: the account that
/// signed its node in, or with `allow_tailnet_members` its tailnet's members.
/// Its documented answer to anyone else is `403` with `{"error": "…"}` on
/// every request; any status but 101 is a refusal, and a 401 or 403 is about
/// who this device is.
@MainActor
enum RexTailnetAccess {
    /// The account Oppi is on Tailscale as, when Oppi's own node carries the
    /// connection; nil through the Tailscale app's VPN, whose account Oppi
    /// cannot read.
    static var signedInAs: String? {
        TailnetTransportRoute.proxy == nil ? nil : TailnetNodeController.shared.snapshot?.selfLoginName
    }

    static func refusal(_ error: any Error, host: RexTailnetHost) -> String? {
        refusal(error, host: host, signedInAs: signedInAs)
    }

    /// Nil for an error that is not a refusal (timed out, no route, closed).
    nonisolated static func refusal(_ error: any Error, host: RexTailnetHost, signedInAs: String?) -> String? {
        guard case .upgradeRefused(let answer)? = error as? RexWebSocketCodec.Failure else { return nil }
        let words = answer.split(separator: " ", maxSplits: 2)
        let status = words.count > 1 ? Int(words[1]) : nil
        guard status == 401 || status == 403 else {
            let line = answer.split(separator: "{", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? answer
            return "\(host.dnsName) did not open Rex: it answered \(line). Check that this is a Rex's Tailscale name."
        }
        var message = "This Rex only lets in the Tailscale account that signed it in. "
        if let signedInAs {
            message += "Oppi is on Tailscale as \(signedInAs)."
        } else {
            message += "Oppi is on Tailscale through this device's Tailscale app; check which account it is signed in to."
        }
        if let reason = rexReason(answer) { message += " Rex said: \(reason)" }
        return message
    }

    /// The `error` of the JSON body Rex sends with a refusal.
    nonisolated private static func rexReason(_ answer: String) -> String? {
        guard let brace = answer.firstIndex(of: "{"),
              let body = try? JSONSerialization.jsonObject(with: Data(answer[brace...].utf8)) as? [String: Any],
              let reason = body["error"] as? String, !reason.isEmpty else { return nil }
        return reason
    }
}

/// A Rex terminal's link to a Rex reached over Tailscale alone: its control
/// connection and each pane's data connection go straight to Rex's Tailscale
/// serving (`RexTLSStream`), with no SSH connection beside them. So there are
/// no side commands (`sideCommandsUnavailable`): photo and file uploads, the
/// host's Ghostty colors, keybinding files, and Herdr are not offered. Its
/// liveness probe is one Rex round trip.
final class RexTailnetTransport: RexTransport {
    static let sideCommandsReason = "Oppi reaches this Rex over Tailscale alone, without SSH, so it cannot save files on that computer or run commands there."
    /// The bridge a `.tailscale` link never opens.
    static let noBridge: RexLink.OpenStream = { _, _, _ in throw RexClientError.bridgeMissing }

    let link: RexLink
    var route: RexRoute { link.route }
    var sideCommandsUnavailable: String? { Self.sideCommandsReason }
    private let control: RexControl

    private init(link: RexLink, control: RexControl) {
        self.link = link
        self.control = control
    }

    /// Opens Rex's control connection at `host` and says hello.
    /// `onWritable` hears the control socket's writability, which typing waits on.
    static func open(
        host: RexTailnetHost,
        openDirect: @escaping RexLink.OpenDirect = RexTLSStream.open,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (RexTailnetTransport, RexControl) {
        let link = RexLink(route: .tailscale(host.url), openStream: noBridge, openDirect: openDirect)
        let started = ContinuousClock.now
        do {
            let control = try await link.connect(timeout: RexTailnetHost.connectTimeout, onWritable: onWritable)
            RexRouteLog.chosen(link.route, directMs: Int((ContinuousClock.now - started) / .milliseconds(1)))
            return (RexTailnetTransport(link: link, control: control), control)
        } catch {
            RexRouteLog.directFailed(error, milliseconds: Int((ContinuousClock.now - started) / .milliseconds(1)))
            throw error
        }
    }

    func openData(
        inboundFlow: SSHPTYInboundFlow?, onEvent: @escaping @Sendable (RexSocketEvent) -> Void
    ) async throws -> any RexSocket {
        try await link.open(.data, inboundFlow: inboundFlow, onEvent: onEvent)
    }

    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        throw SSHTerminalSideCommandsUnavailable(reason: Self.sideCommandsReason)
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        throw SSHTerminalSideCommandsUnavailable(reason: Self.sideCommandsReason)
    }

    /// One Rex round trip; failing closes the connection, as a failed SSH probe does.
    func checkAlive() async throws {
        do {
            _ = try await control.call("server.status", [:])
        } catch {
            close()
            throw error
        }
    }

    func close() { control.close() }

    func cancel() async { close() }
}

import Darwin
import Foundation

/// Phone-wire contract for experimental `WSS /desktop/view/stream`.
/// Control is JSON; media is a 24-byte header plus AVCC H.264.
enum DesktopViewStream {
    static let path = "/desktop/view/stream"
    static let wireVersion: UInt8 = 1
    static let featureAvcc = "h264-avcc"
    static let mediaHeaderBytes = 24
    static let flagKeyframe: UInt8 = 1 << 0
    static let fatalErrorMin = 4100
    static let fatalErrorMax = 4109
    static let staleInterval: TimeInterval = 2

    enum ErrorCode {
        static let protocolFatal = 4100
        static let grantUnavailable = 4102
        static let grantNotBound = 4103
        static let grantRevoked = 4104
        static let grantExpired = 4105
        static let surfaceGone = 4106
        static let deviceRevoked = 4107
        static let flagOff = 4108
        static let backpressureCap = 4109
        /// Application JSON code (WebSocket close stays 4000). Reconnectable.
        static let alreadyStreaming = 4001
        /// Application JSON code (WebSocket close stays 4000). Reconnectable.
        static let companionUnavailable = 4002
    }

    static func isFatalErrorCode(_ code: Int) -> Bool {
        (fatalErrorMin...fatalErrorMax).contains(code)
    }
}

/// Settings → Experiments → Live Remote Screen, plus the server capability.
enum DesktopLiveViewPlayground {
    static func isAvailable(experimentEnabled: Bool, serverOffers: Bool) -> Bool {
        experimentEnabled && serverOffers
    }
}

struct DesktopViewSurface: Codable, Equatable, Sendable {
    var windowId: Int
    var title: String
}

struct DesktopViewHello: Codable, Equatable, Sendable {
    var version: Int
    var features: [String]
    var grantId: String
    var deviceId: String
    var surface: DesktopViewSurface
    var expiresAt: String?
}

struct DesktopViewPing: Codable, Equatable, Sendable {
    var t: Int64
}

struct DesktopViewErrorMessage: Codable, Equatable, Sendable {
    var code: Int
    var message: String
    var fatal: Bool?
}

/// Inbound phone control. Unknown `type` values are skipped.
enum DesktopViewPhoneInbound: Equatable, Sendable {
    case hello(DesktopViewHello)
    case ping(DesktopViewPing)
    case error(DesktopViewErrorMessage)
    case ignored(type: String)

    static func parse(_ data: Data) -> DesktopViewPhoneInbound? {
        struct Envelope: Decodable {
            var type: String
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        switch envelope.type {
        case "hello":
            guard let hello = try? decoder.decode(DesktopViewHello.self, from: data) else {
                return nil
            }
            return .hello(hello)
        case "ping":
            guard let ping = try? decoder.decode(DesktopViewPing.self, from: data) else {
                return nil
            }
            return .ping(ping)
        case "error":
            guard let error = try? decoder.decode(DesktopViewErrorMessage.self, from: data) else {
                return nil
            }
            return .error(error)
        default:
            return .ignored(type: envelope.type)
        }
    }
}

enum DesktopViewPhoneOutbound: Equatable, Sendable {
    case pong(t: Int64)
    case ack(frameId: UInt32, receivedAt: Int64)

    func encode() -> Data {
        switch self {
        case .pong(let t):
            Data("{\"type\":\"pong\",\"t\":\(t)}".utf8)
        case .ack(let frameId, let receivedAt):
            Data("{\"type\":\"ack\",\"frameId\":\(frameId),\"receivedAt\":\(receivedAt)}".utf8)
        }
    }
}

struct DesktopViewMediaHeader: Equatable, Sendable {
    var version: UInt8
    var keyframe: Bool
    var frameId: UInt32
    var capturedAtMs: UInt64
    var width: UInt16
    var height: UInt16
    var payloadBytes: UInt32
}

enum DesktopViewMediaParseError: Error, Equatable {
    case truncated
    case unsupportedVersion(UInt8)
}

enum DesktopViewMediaCodec {
    static func parseHeader(_ data: Data) throws -> DesktopViewMediaHeader {
        guard data.count >= DesktopViewStream.mediaHeaderBytes else {
            throw DesktopViewMediaParseError.truncated
        }
        let version = data[0]
        guard version == DesktopViewStream.wireVersion else {
            throw DesktopViewMediaParseError.unsupportedVersion(version)
        }
        let header = DesktopViewMediaHeader(
            version: version,
            keyframe: (data[1] & DesktopViewStream.flagKeyframe) != 0,
            frameId: readUInt32BE(data, at: 4),
            capturedAtMs: readUInt64BE(data, at: 8),
            width: readUInt16BE(data, at: 16),
            height: readUInt16BE(data, at: 18),
            payloadBytes: readUInt32BE(data, at: 20)
        )
        let end = DesktopViewStream.mediaHeaderBytes + Int(header.payloadBytes)
        guard data.count >= end else {
            throw DesktopViewMediaParseError.truncated
        }
        return header
    }

    static func parseFrame(_ data: Data) throws -> (header: DesktopViewMediaHeader, payload: Data) {
        let header = try parseHeader(data)
        let end = DesktopViewStream.mediaHeaderBytes + Int(header.payloadBytes)
        return (header, data.subdata(in: DesktopViewStream.mediaHeaderBytes..<end))
    }

    static func encodeFrame(header: DesktopViewMediaHeader, payload: Data) -> Data {
        var out = Data(count: DesktopViewStream.mediaHeaderBytes)
        out[0] = DesktopViewStream.wireVersion
        out[1] = header.keyframe ? DesktopViewStream.flagKeyframe : 0 as UInt8
        out[2] = UInt8(truncatingIfNeeded: DesktopViewStream.mediaHeaderBytes)
        out[3] = 0
        writeUInt32BE(header.frameId, into: &out, at: 4)
        writeUInt64BE(header.capturedAtMs, into: &out, at: 8)
        writeUInt16BE(header.width, into: &out, at: 16)
        writeUInt16BE(header.height, into: &out, at: 18)
        writeUInt32BE(UInt32(payload.count), into: &out, at: 20)
        out.append(payload)
        return out
    }
}

struct DesktopViewAVCCNAL: Equatable, Sendable {
    var type: UInt8
    var bytes: Data

    var isSPS: Bool { type == 7 }
    var isPPS: Bool { type == 8 }
    var isIDR: Bool { type == 5 }
    var isSlice: Bool { type == 1 || type == 5 }
}

enum DesktopViewAVCC {
    struct Span: Equatable, Sendable {
        var type: UInt8
        var start: Int
        var length: Int

        var isSPS: Bool { type == 7 }
        var isPPS: Bool { type == 8 }
        var isIDR: Bool { type == 5 }
        var isSlice: Bool { type == 1 || type == 5 }
    }

    static func spans(in payload: Data, offset: Int = 0, count: Int? = nil) -> [Span]? {
        var index = offset
        let end = offset + (count ?? (payload.count - offset))
        guard end <= payload.count else { return nil }
        var nals: [Span] = []
        while index < end {
            guard index + 4 <= end else { return nil }
            let length = Int(readUInt32BE(payload, at: index))
            let nalStart = index + 4
            guard length > 0, nalStart + length <= end else { return nil }
            nals.append(Span(type: payload[nalStart] & 0x1f, start: nalStart, length: length))
            index = nalStart + length
        }
        return nals
    }

    static func nalus(in payload: Data) -> [DesktopViewAVCCNAL]? {
        guard let spans = spans(in: payload) else { return nil }
        return spans.map { span in
            DesktopViewAVCCNAL(
                type: span.type,
                bytes: payload.subdata(in: span.start..<(span.start + span.length))
            )
        }
    }

    static func parameterSets(in payload: Data, offset: Int = 0, count: Int? = nil) -> (sps: Span, pps: Span)? {
        guard let nals = spans(in: payload, offset: offset, count: count),
              let sps = nals.first(where: \.isSPS),
              let pps = nals.first(where: \.isPPS)
        else {
            return nil
        }
        return (sps, pps)
    }
}

enum DesktopLiveReconnectPolicy {
    static let maxDelay: TimeInterval = 8

    static func isFatal(code: Int?, reason: String?) -> Bool {
        if let code, DesktopViewStream.isFatalErrorCode(code) {
            return true
        }
        guard let token = reasonToken(reason) else { return false }
        if token.hasPrefix("grant_") { return true }
        return fatalReasonTokens.contains(token)
    }

    static func delay(attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1: 0.5
        case 2: 1
        case 3: 2
        case 4: 4
        default: maxDelay
        }
    }

    static func message(code: Int?, reason: String?, serverMessage: String?) -> String {
        let token = reasonToken(reason)
        let resolved = code ?? errorCode(forReason: token)
        switch resolved {
        case DesktopViewStream.ErrorCode.grantUnavailable,
             DesktopViewStream.ErrorCode.grantNotBound,
             DesktopViewStream.ErrorCode.grantRevoked,
             DesktopViewStream.ErrorCode.grantExpired:
            return Self.grantMessage
        case DesktopViewStream.ErrorCode.surfaceGone:
            return "That Mac window is no longer available."
        case DesktopViewStream.ErrorCode.deviceRevoked:
            return "This device can no longer view the remote screen."
        case DesktopViewStream.ErrorCode.flagOff:
            return "Live Remote Screen is off on the server."
        case DesktopViewStream.ErrorCode.alreadyStreaming:
            return "Remote Screen is already being viewed."
        case DesktopViewStream.ErrorCode.companionUnavailable:
            return "Oppi on the host is not sharing a remote screen. Open Oppi on the host, then retry."
        default:
            if let serverMessage, !serverMessage.isEmpty { return serverMessage }
            return "Couldn't show the live remote screen."
        }
    }

    static func isGrant(_ code: Int?, reason: String?) -> Bool {
        let token = reasonToken(reason)
        if token?.hasPrefix("grant_") == true { return true }
        switch code ?? errorCode(forReason: token) {
        case DesktopViewStream.ErrorCode.grantUnavailable,
             DesktopViewStream.ErrorCode.grantNotBound,
             DesktopViewStream.ErrorCode.grantRevoked,
             DesktopViewStream.ErrorCode.grantExpired:
            return true
        default:
            return false
        }
    }

    static let grantMessage = "Grant this iPhone in Oppi on your Mac"

    private static let fatalReasonTokens: Set<String> = [
        "protocol_fatal",
        "grant_unavailable",
        "grant_not_bound",
        "grant_revoked",
        "grant_expired",
        "surface_gone",
        "device_revoked",
        "flag_off",
        "backpressure_cap",
    ]

    private static func reasonToken(_ reason: String?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        return reason.split(whereSeparator: { $0 == " " || $0 == "\0" }).first.map(String.init)
    }

    private static func errorCode(forReason token: String?) -> Int? {
        switch token {
        case "protocol_fatal": DesktopViewStream.ErrorCode.protocolFatal
        case "grant_unavailable": DesktopViewStream.ErrorCode.grantUnavailable
        case "grant_not_bound": DesktopViewStream.ErrorCode.grantNotBound
        case "grant_revoked": DesktopViewStream.ErrorCode.grantRevoked
        case "grant_expired": DesktopViewStream.ErrorCode.grantExpired
        case "surface_gone": DesktopViewStream.ErrorCode.surfaceGone
        case "device_revoked": DesktopViewStream.ErrorCode.deviceRevoked
        case "flag_off": DesktopViewStream.ErrorCode.flagOff
        case "backpressure_cap": DesktopViewStream.ErrorCode.backpressureCap
        case "already_streaming": DesktopViewStream.ErrorCode.alreadyStreaming
        case "companion_unavailable": DesktopViewStream.ErrorCode.companionUnavailable
        default: nil
        }
    }
}

enum DesktopLivePresentation: Equatable, Sendable {
    case connecting
    case waitingForGrant(message: String)
    case live(title: String)
    case paused(title: String, lastFrameAge: TimeInterval)
    case reconnecting(title: String?, lastFrameAge: TimeInterval?)
    case failed(message: String)

    var statusText: String {
        switch self {
        case .connecting:
            "Connecting"
        case .waitingForGrant:
            "Waiting for grant"
        case .live:
            "Live"
        case .paused:
            "Paused"
        case .reconnecting:
            "Reconnecting"
        case .failed:
            "Can't show Remote Screen"
        }
    }

    var detailText: String? {
        switch self {
        case .connecting, .live:
            nil
        case .waitingForGrant(let message), .failed(let message):
            message
        case .paused(_, let age), .reconnecting(_, .some(let age)):
            Self.ageText(age)
        case .reconnecting(_, .none):
            nil
        }
    }

    var windowTitle: String? {
        switch self {
        case .live(let title), .paused(let title, _):
            title
        case .reconnecting(let title, _):
            title
        default:
            nil
        }
    }

    static func ageText(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age.rounded()))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

/// Live/stale chrome. "Live" is frame arrival, not the socket being open.
struct DesktopLiveArrivalMachine: Equatable, Sendable {
    private(set) var presentation: DesktopLivePresentation = .connecting
    private(set) var windowTitle: String?
    private(set) var lastFrameAt: TimeInterval?
    private(set) var isSocketOpen = false
    private(set) var isReconnecting = false

    mutating func resetConnecting() {
        presentation = .connecting
        isSocketOpen = false
        isReconnecting = false
    }

    mutating func onHello(title: String, now: TimeInterval) {
        windowTitle = title
        isSocketOpen = true
        isReconnecting = false
        refresh(now: now)
    }

    mutating func onFrame(now: TimeInterval) {
        lastFrameAt = now
        isSocketOpen = true
        isReconnecting = false
        presentation = .live(title: displayTitle)
    }

    mutating func onTick(now: TimeInterval) {
        refresh(now: now)
    }

    mutating func onDisconnect(now: TimeInterval, willReconnect: Bool) {
        isSocketOpen = false
        isReconnecting = willReconnect
        if willReconnect {
            presentation = .reconnecting(title: windowTitle, lastFrameAge: lastFrameAt.map { now - $0 })
        }
    }

    mutating func onWaitingForGrant(message: String = DesktopLiveReconnectPolicy.grantMessage) {
        isSocketOpen = false
        isReconnecting = false
        presentation = .waitingForGrant(message: message)
    }

    mutating func onFatal(message: String) {
        isSocketOpen = false
        isReconnecting = false
        presentation = .failed(message: message)
    }

    private mutating func refresh(now: TimeInterval) {
        guard lastFrameAt != nil || windowTitle != nil else {
            if case .failed = presentation { return }
            if case .waitingForGrant = presentation { return }
            presentation = .connecting
            return
        }
        guard let lastFrameAt else {
            presentation = .connecting
            return
        }
        let age = now - lastFrameAt
        if age <= DesktopViewStream.staleInterval {
            presentation = .live(title: displayTitle)
            return
        }
        if isReconnecting || !isSocketOpen {
            presentation = .reconnecting(title: windowTitle, lastFrameAge: age)
        } else {
            presentation = .paused(title: displayTitle, lastFrameAge: age)
        }
    }

    private var displayTitle: String {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Remote Screen" : title
    }
}

// Shared by OppiCore and OppiMac (OppiCore is compiled into the OppiMac module).
func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(readUInt32BE(data, at: offset)) << 32 | UInt64(readUInt32BE(data, at: offset + 4))
}

func writeUInt16BE(_ value: UInt16, to base: UnsafeMutableRawPointer, at offset: Int) {
    var be = value.bigEndian
    memcpy(base.advanced(by: offset), &be, 2)
}

func writeUInt32BE(_ value: UInt32, to base: UnsafeMutableRawPointer, at offset: Int) {
    var be = value.bigEndian
    memcpy(base.advanced(by: offset), &be, 4)
}

func writeUInt64BE(_ value: UInt64, to base: UnsafeMutableRawPointer, at offset: Int) {
    var be = value.bigEndian
    memcpy(base.advanced(by: offset), &be, 8)
}

func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt16BE(value, to: base, at: offset)
    }
}

func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt32BE(value, to: base, at: offset)
    }
}

func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt64BE(value, to: base, at: offset)
    }
}

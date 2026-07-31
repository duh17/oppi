import Foundation

/// Pairing-frame adapter backed by the same persistent per-server endpoint
/// manager later used by the transparent HTTP/WebSocket tunnel.
struct IrohLibFrameTransport: IrohFrameTransport {
    func exchange(
        iroh: IrohServerTransport,
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data {
        let manager = try await IrohTransportRegistry.shared.manager(for: iroh)
        return try await manager.exchange(
            alpn: alpn,
            requestFrame: requestFrame,
            maxResponseBytes: maxResponseBytes
        )
    }
}

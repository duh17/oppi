import Foundation

protocol IrohFrameTransport: Sendable {
    func exchange(
        iroh: IrohServerTransport,
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data
}

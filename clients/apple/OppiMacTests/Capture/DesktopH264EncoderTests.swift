import CoreVideo
import Foundation
import Testing
@testable import Oppi

@Suite("Desktop H.264 encoder")
struct DesktopH264EncoderTests {
    @Test func createsASessionAndAppliesBitrateWithoutRebuild() throws {
        let encoder = DesktopH264Encoder()
        defer { encoder.invalidate() }
        let buffer = try makeNV12(width: 128, height: 96, seed: 3)
        encoder.encode(
            buffer: buffer,
            capturedAt: Date(),
            command: DesktopH264EncodeCommand(frameId: 1, bitrate: 400_000, fps: 10, scale: 1, keyframe: true)
        ) { _ in }
        #expect(encoder.sessionEpoch >= 1)
        let epoch = encoder.sessionEpoch
        encoder.encode(
            buffer: buffer,
            capturedAt: Date(),
            command: DesktopH264EncodeCommand(frameId: 2, bitrate: 1_200_000, fps: 24, scale: 1, keyframe: false)
        ) { _ in }
        #expect(encoder.sessionEpoch == epoch)
    }
}

private enum EncoderTestError: Error {
    case pixelBuffer
}

private func makeNV12(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { throw EncoderTestError.pixelBuffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height
        memset(y, Int32(seed), bytes)
    }
    if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2)
        memset(uv, 128, bytes)
    }
    return buffer
}

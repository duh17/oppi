import AVFoundation
import CoreVideo
import Foundation

/// Disposable H.264 MP4 generated at test runtime. Not a committed binary.
enum GeneratedH264Fixture {
    struct Artifact: Sendable {
        let url: URL
        let data: Data
        let duration: TimeInterval
        let frameCount: Int
        let width: Int
        let height: Int

        var byteSize: Int { data.count }
    }

    static func make(
        duration: TimeInterval,
        frameDuration: TimeInterval,
        width: Int,
        height: Int,
        averageBitRate: Int?,
        noisyFrames: Bool
    ) async throws -> Artifact {
        let frameCount = max(1, Int((duration / frameDuration).rounded(.towardZero)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-h264-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        var compression: [String: Any] = [
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: noisyFrames ? 1 : 8,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if let averageBitRate {
            compression[AVVideoAverageBitRateKey] = averageBitRate
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let frameTime = CMTime(seconds: frameDuration, preferredTimescale: timescale)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let buffer = try makePixelBuffer(
                width: width,
                height: height,
                frameIndex: index,
                noisy: noisyFrames
            )
            let presentation = CMTimeMultiply(frameTime, multiplier: Int32(index))
            guard adaptor.append(buffer, withPresentationTime: presentation) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        let endTime = CMTimeMultiply(frameTime, multiplier: Int32(frameCount))
        writer.endSession(atSourceTime: endTime)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
        let data = try Data(contentsOf: url)
        return Artifact(
            url: url,
            data: data,
            duration: CMTimeGetSeconds(endTime),
            frameCount: frameCount,
            width: width,
            height: height
        )
    }

    static func makeLargerThan(_ minimumByteCount: Int) async throws -> Artifact {
        var frameCount = 48
        var last: Artifact?
        while frameCount <= 360 {
            let duration = TimeInterval(frameCount) / 15
            let artifact = try await make(
                duration: duration,
                frameDuration: 1.0 / 15.0,
                width: 320,
                height: 180,
                averageBitRate: 12_000_000,
                noisyFrames: true
            )
            last = artifact
            if artifact.byteSize > minimumByteCount {
                return artifact
            }
            frameCount += 48
        }
        throw CocoaError(.fileWriteUnknown)
    }

    static func makeLongDuration(duration: TimeInterval = 3_600) async throws -> Artifact {
        let frames = 8
        return try await make(
            duration: duration,
            frameDuration: duration / TimeInterval(frames),
            width: 16,
            height: 16,
            averageBitRate: 32_000,
            noisyFrames: false
        )
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        noisy: Bool
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowPointer = pointer.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                let offset = column * 4
                if noisy {
                    let mixed = UInt8(truncatingIfNeeded: (row &* 31) &+ (column &* 17) &+ (frameIndex &* 13))
                    rowPointer[offset] = mixed
                    rowPointer[offset + 1] = mixed &+ 40
                    rowPointer[offset + 2] = mixed &+ 80
                    rowPointer[offset + 3] = 255
                } else {
                    rowPointer[offset] = 32
                    rowPointer[offset + 1] = 64
                    rowPointer[offset + 2] = UInt8(truncatingIfNeeded: 96 &+ frameIndex &* 8)
                    rowPointer[offset + 3] = 255
                }
            }
        }
        return buffer
    }
}

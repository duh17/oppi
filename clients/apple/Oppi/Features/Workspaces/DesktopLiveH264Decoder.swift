import CoreMedia
import Foundation

/// Builds `CMSampleBuffer`s from AVCC phone-wire payloads for `AVSampleBufferDisplayLayer`.
/// Format description is replaced on every IDR. Slice bytes are copied once into the block buffer.
final class DesktopLiveH264Decoder: @unchecked Sendable {
    private let lock = NSLock()
    private var format: CMFormatDescription?
    private var waitingForIDR = true

    func reset() {
        lock.lock()
        format = nil
        waitingForIDR = true
        lock.unlock()
    }

    /// P-frame chain is broken; skip until the next IDR.
    func noteBrokenChain() {
        lock.lock()
        waitingForIDR = true
        lock.unlock()
    }

    func sampleBuffer(
        payload: Data,
        header: DesktopViewMediaHeader
    ) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let avccCount = Int(header.payloadBytes)
        let avccOffset: Int
        if payload.count == avccCount {
            avccOffset = 0
        } else if payload.count >= DesktopViewStream.mediaHeaderBytes + avccCount {
            avccOffset = DesktopViewStream.mediaHeaderBytes
        } else {
            waitingForIDR = true
            return nil
        }
        guard let nals = DesktopViewAVCC.spans(in: payload, offset: avccOffset, count: avccCount) else {
            waitingForIDR = true
            return nil
        }

        if header.keyframe {
            guard let sps = nals.first(where: \.isSPS),
                  let pps = nals.first(where: \.isPPS),
                  let next = Self.makeFormatDescription(payload: payload, sps: sps, pps: pps)
            else {
                waitingForIDR = true
                return nil
            }
            format = next
            waitingForIDR = false
        } else if waitingForIDR || format == nil {
            return nil
        }

        let slices = nals.filter(\.isSlice)
        guard let format, !slices.isEmpty else {
            waitingForIDR = true
            return nil
        }
        return Self.makeSampleBuffer(payload: payload, slices: slices, format: format)
    }

    private static func makeFormatDescription(
        payload: Data,
        sps: DesktopViewAVCC.Span,
        pps: DesktopViewAVCC.Span
    ) -> CMFormatDescription? {
        var format: CMFormatDescription?
        let status = payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCMFormatDescriptionError_InvalidParameter)
            }
            let pointers: [UnsafePointer<UInt8>] = [base + sps.start, base + pps.start]
            let sizes: [Int] = [sps.length, pps.length]
            return pointers.withUnsafeBufferPointer { pointerBuf in
                sizes.withUnsafeBufferPointer { sizeBuf in
                    guard let pointerBase = pointerBuf.baseAddress,
                          let sizeBase = sizeBuf.baseAddress
                    else {
                        return Int32(kCMFormatDescriptionError_InvalidParameter)
                    }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        guard status == noErr else { return nil }
        return format
    }

    private static func makeSampleBuffer(
        payload: Data,
        slices: [DesktopViewAVCC.Span],
        format: CMFormatDescription
    ) -> CMSampleBuffer? {
        let length = slices.reduce(0) { $0 + 4 + $1.length }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { return nil }
        status = payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCMBlockBufferBadLengthParameterErr)
            }
            var dest = 0
            for nal in slices {
                let copy = CMBlockBufferReplaceDataBytes(
                    with: base + nal.start - 4,
                    blockBuffer: block,
                    offsetIntoDestination: dest,
                    dataLength: 4 + nal.length
                )
                if copy != noErr { return copy }
                dest += 4 + nal.length
            }
            return noErr
        }
        guard status == noErr else { return nil }

        var sample = CMSampleBuffer?.none
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

import CoreMedia
import Foundation

/// Builds `CMSampleBuffer`s from AVCC phone-wire payloads for `AVSampleBufferDisplayLayer`.
/// Format description is created on each IDR and replaced when the coded size changes.
final class DesktopLiveH264Decoder: @unchecked Sendable {
    private let lock = NSLock()
    private var format: CMFormatDescription?
    private var formatWidth: Int = 0
    private var formatHeight: Int = 0
    private var waitingForIDR = true

    func reset() {
        lock.lock()
        format = nil
        formatWidth = 0
        formatHeight = 0
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

        if header.keyframe {
            guard let sets = DesktopViewAVCC.parameterSets(in: payload),
                  let next = Self.makeFormatDescription(sps: sets.sps, pps: sets.pps)
            else {
                waitingForIDR = true
                return nil
            }
            let width = Int(header.width)
            let height = Int(header.height)
            if format == nil || width != formatWidth || height != formatHeight {
                format = next
                formatWidth = width
                formatHeight = height
            } else {
                format = next
            }
            waitingForIDR = false
        } else if waitingForIDR || format == nil {
            return nil
        }

        guard let format,
              let picture = DesktopViewAVCC.picturePayload(from: payload)
        else {
            waitingForIDR = true
            return nil
        }
        return Self.makeSampleBuffer(avcc: picture, format: format)
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else {
                    return Int32(kCMFormatDescriptionError_InvalidParameter)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
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
        }
        guard status == noErr else { return nil }
        return format
    }

    private static func makeSampleBuffer(
        avcc: Data,
        format: CMFormatDescription
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = avcc.count
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
        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return Int32(kCMBlockBufferBadLengthParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: length
            )
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

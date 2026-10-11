import CoreMedia
import Foundation
import Testing
@testable import Oppi

@Suite("Desktop live view media")
struct DesktopLiveViewMediaTests {
    @Test func avccParserReadsSPSAndPPSFromRealIDR() throws {
        let idr = try loadFixture().frame(id: 1)
        let nals = try #require(DesktopViewAVCC.nalus(in: idr.avcc))
        #expect(nals.contains { $0.isSPS })
        #expect(nals.contains { $0.isPPS })
        #expect(nals.contains { $0.isIDR })
        let sets = try #require(DesktopViewAVCC.parameterSets(in: idr.avcc))
        #expect((sets.sps[0] & 0x1f) == 7)
        #expect((sets.pps[0] & 0x1f) == 8)
        let picture = try #require(DesktopViewAVCC.picturePayload(from: idr.avcc))
        let pictureNals = try #require(DesktopViewAVCC.nalus(in: picture))
        #expect(pictureNals.allSatisfy { $0.isSlice })
        #expect(!pictureNals.contains { $0.isSPS })
    }

    @Test func formatDescriptionAndSampleBufferComeFromRealH264() throws {
        let fixture = try loadFixture()
        let idr = try fixture.frame(id: 1)
        let p = try fixture.frame(id: 2)
        let decoder = DesktopLiveH264Decoder()

        let idrSample = try #require(decoder.sampleBuffer(payload: idr.avcc, header: idr.header))
        #expect(CMSampleBufferIsValid(idrSample))
        let idrFormat = try #require(CMSampleBufferGetFormatDescription(idrSample))
        let idrDimensions = CMVideoFormatDescriptionGetDimensions(idrFormat)
        #expect(idrDimensions.width == 320)
        #expect(idrDimensions.height == 180)
        #expect(displayImmediately(idrSample))

        let pSample = try #require(decoder.sampleBuffer(payload: p.avcc, header: p.header))
        #expect(CMSampleBufferIsValid(pSample))
        #expect(displayImmediately(pSample))
    }

    @Test func pFrameWithoutIDRWaitsAndSizeChangeReplacesFormat() throws {
        let fixture = try loadFixture()
        let decoder = DesktopLiveH264Decoder()
        let p = try fixture.frame(id: 2)
        #expect(decoder.sampleBuffer(payload: p.avcc, header: p.header) == nil)

        let idr = try fixture.frame(id: 1)
        _ = try #require(decoder.sampleBuffer(payload: idr.avcc, header: idr.header))
        decoder.noteBrokenChain()
        #expect(decoder.sampleBuffer(payload: p.avcc, header: p.header) == nil)

        let nextIDR = try fixture.frame(id: 3)
        let recovered = try #require(decoder.sampleBuffer(payload: nextIDR.avcc, header: nextIDR.header))
        #expect(CMSampleBufferIsValid(recovered))

        let alt = try fixture.frame(id: 4)
        let resized = try #require(decoder.sampleBuffer(payload: alt.avcc, header: alt.header))
        let format = try #require(CMSampleBufferGetFormatDescription(resized))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 160)
        #expect(dimensions.height == 90)
    }

    @Test func phoneWireFrameParsesCommittedFixture() throws {
        let idr = try loadFixture().frame(id: 1)
        let wire = DesktopViewMediaCodec.encodeFrame(header: idr.header, payload: idr.avcc)
        let parsed = try DesktopViewMediaCodec.parseFrame(wire)
        #expect(parsed.header.keyframe)
        #expect(parsed.header.frameId == 1)
        #expect(parsed.header.width == 320)
        #expect(parsed.payload == idr.avcc)
    }

    private func displayImmediately(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else {
            return false
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let value = CFDictionaryGetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        ) else {
            return false
        }
        return value == Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
    }

    private func loadFixture() throws -> AVCCFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/desktop-live-view-avcc.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AVCCFixture.self, from: data)
    }
}

private struct AVCCFixture: Decodable {
    var frames: [Frame]

    struct Frame: Decodable {
        var frameId: UInt32
        var keyframe: Bool
        var width: UInt16
        var height: UInt16
        var avccHex: String

        var avcc: Data { Data(hex: avccHex) }

        var header: DesktopViewMediaHeader {
            DesktopViewMediaHeader(
                version: 1,
                keyframe: keyframe,
                frameId: frameId,
                capturedAtMs: 1_770_000_000_000 + UInt64(frameId),
                width: width,
                height: height,
                payloadBytes: UInt32(avcc.count)
            )
        }
    }

    func frame(id: UInt32) throws -> Frame {
        try #require(frames.first { $0.frameId == id })
    }
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        self = data
    }
}

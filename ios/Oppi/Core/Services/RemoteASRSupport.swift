import Accelerate
import Foundation

enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let bytesPerSample = Int(bitsPerSample) / 8
        let dataSize = samples.count * bytesPerSample
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(fileSize))
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(numChannels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * Int(numChannels) * bytesPerSample))
        data.appendLittleEndian(UInt16(numChannels * Int16(bytesPerSample)))
        data.appendLittleEndian(UInt16(bitsPerSample))

        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataSize))

        var int16Samples = [Int16](repeating: 0, count: samples.count)
        var scale = Float(Int16.max)
        samples.withUnsafeBufferPointer { srcPtr in
            int16Samples.withUnsafeMutableBufferPointer { dstPtr in
                guard let src = srcPtr.baseAddress, let dst = dstPtr.baseAddress else { return }
                var clipped = [Float](repeating: 0, count: samples.count)
                var low: Float = -1.0
                var high: Float = 1.0
                vDSP_vclip(src, 1, &low, &high, &clipped, 1, vDSP_Length(samples.count))
                vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(samples.count))
                vDSP_vfix16(clipped, 1, dst, 1, vDSP_Length(samples.count))
            }
        }

        int16Samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            data.append(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                    count: dataSize
                )
            )
        }

        return data
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendMultipartFile(
        boundary: String, name: String, filename: String,
        contentType: String, data fileData: Data
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(fileData)
        append(Data("\r\n".utf8))
    }

    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}

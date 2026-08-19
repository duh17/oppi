import Foundation

/// Rewrites unpaired JSON `\uXXXX` surrogate escapes so Foundation's
/// `JSONDecoder` can parse history payloads that contain truncated web text.
///
/// Swift rejects the whole document when a high surrogate is not followed by a
/// low surrogate. That happened on `worker-indep-evals-20260819` when a
/// web_search snippet cut a mathematical-bold pair at `\ud835...`.
enum JSONUnpairedSurrogateRepair {
    static func repairing(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard let repaired = repairingUnpairedSurrogateEscapes(in: bytes) else {
            return data
        }
        return Data(repaired)
    }
}

private func repairingUnpairedSurrogateEscapes(in bytes: [UInt8]) -> [UInt8]? {
    var output = bytes
    var index = 0
    var changed = false

    while index < output.count {
        if output[index] == 0x5C, index + 1 < output.count {
            if isJSONUnicodeEscapeU(output[index + 1]),
               let code = parseJSONHexScalar(output, at: index + 2) {
                if (0xD800...0xDBFF).contains(code) {
                    let next = index + 6
                    if next + 5 < output.count,
                       output[next] == 0x5C,
                       isJSONUnicodeEscapeU(output[next + 1]),
                       let low = parseJSONHexScalar(output, at: next + 2),
                       (0xDC00...0xDFFF).contains(low) {
                        index += 12
                        continue
                    }
                    replaceJSONHexScalarWithReplacement(&output, at: index + 2)
                    changed = true
                    index += 6
                    continue
                }
                if (0xDC00...0xDFFF).contains(code) {
                    replaceJSONHexScalarWithReplacement(&output, at: index + 2)
                    changed = true
                    index += 6
                    continue
                }
                index += 6
                continue
            }
            index += 2
            continue
        }
        index += 1
    }

    return changed ? output : nil
}

private func isJSONUnicodeEscapeU(_ byte: UInt8) -> Bool {
    byte == 0x75 || byte == 0x55
}

private func parseJSONHexScalar(_ bytes: [UInt8], at index: Int) -> UInt16? {
    guard index + 3 < bytes.count else { return nil }
    var value: UInt16 = 0
    for offset in 0..<4 {
        guard let nibble = hexNibble(bytes[index + offset]) else { return nil }
        value = (value << 4) | UInt16(nibble)
    }
    return value
}

private func replaceJSONHexScalarWithReplacement(_ bytes: inout [UInt8], at index: Int) {
    let hex: [UInt8] = [0x66, 0x66, 0x66, 0x64] // fffd
    for offset in 0..<4 {
        bytes[index + offset] = hex[offset]
    }
}

private func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x41...0x46: return byte - 0x41 + 10
    case 0x61...0x66: return byte - 0x61 + 10
    default: return nil
    }
}

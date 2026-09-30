import Foundation

/// JSON's wire order and number spelling are presentation data. Do not route
/// output through JSONValue/JSONSerialization before building the document.
indirect enum OrderedJSON: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        let key: String
        let value: OrderedJSON
    }
    case object([Field]), array([OrderedJSON]), string(String), number(String), bool(Bool), null

    static let byteBudget = 64 * 1024
    static func parse(_ text: String) -> OrderedJSON? {
        guard text.utf8.count <= byteBudget else { return nil }
        var parser = Parser(bytes: Array(text.utf8))
        return try? parser.parse()
    }

    /// Try JSON at line boundaries without copying/re-parsing every suffix.
    /// Repeated misleading starts in an untrusted preamble get a bounded amount
    /// of parser work; beyond it the caller preserves the entire text in a fence.
    static func parseLineSuffix(_ text: String) -> (String, OrderedJSON)? {
        guard text.utf8.count <= byteBudget else { return nil }
        let bytes = Array(text.utf8)
        var work = 0
        var lineStart = 0
        for index in bytes.indices {
            if bytes[index] == 10 { lineStart = index + 1; continue }
            guard index == lineStart else { continue }
            if bytes[index] == 9 || bytes[index] == 13 || bytes[index] == 32 {
                lineStart += 1
                continue
            }
            guard index > 0, bytes[index] == 123 || bytes[index] == 91 else { continue }
            var parser = Parser(bytes: bytes, index: index)
            let result = try? parser.parse()
            work += max(1, parser.index - index)
            if let result { return (String(decoding: bytes[..<index], as: UTF8.self), result) }
            if work >= byteBudget * 4 { return nil }
        }
        return nil
    }

    var scalar: String? {
        switch self {
        case .string(let s), .number(let s): s
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: nil
        }
    }
    subscript(_ key: String) -> OrderedJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.key == key }?.value
    }
    static func quote(_ text: String) -> String {
        // Only a string is encoded here; object order is never delegated.
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
    func json(pretty: Bool = false, level: Int = 0) -> String {
        let indent = pretty ? String(repeating: "  ", count: level) : ""
        let next = pretty ? String(repeating: "  ", count: level + 1) : ""
        let separator = pretty ? ",\n" : ","
        func container(_ open: String, _ close: String, _ items: [String]) -> String {
            guard !items.isEmpty else { return open + close }
            return open + (pretty ? "\n" : "") + items.map { next + $0 }.joined(separator: separator)
                + (pretty ? "\n" + indent : "") + close
        }
        switch self {
        case .object(let fields):
            return container("{", "}", fields.map { Self.quote($0.key) + (pretty ? ": " : ":") + $0.value.json(pretty: pretty, level: level + 1) })
        case .array(let values): return container("[", "]", values.map { $0.json(pretty: pretty, level: level + 1) })
        case .string(let s): return Self.quote(s)
        default: return scalar ?? "null"
        }
    }
    static func from(_ value: JSONValue) -> OrderedJSON {
        switch value {
        case .object(let fields): .object(fields.keys.sorted().map { Field(key: $0, value: from(fields[$0]!)) })
        case .array(let values): .array(values.map(from))
        case .string(let text): .string(text)
        case .number(let n): .number(String(decoding: (try? JSONEncoder().encode(n)) ?? Data("null".utf8), as: UTF8.self))
        case .bool(let b): .bool(b)
        case .null: .null
        }
    }

    private struct Parser {
        enum Invalid: Error { case json }
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            if index < bytes.count && bytes[index] == byte { index += 1; return true }
            return false
        }
        mutating func require(_ byte: UInt8) throws { guard take(byte) else { throw Invalid.json } }
        mutating func parse() throws -> OrderedJSON {
            let result = try value(depth: 0)
            whitespace()
            guard index == bytes.count else { throw Invalid.json }
            return result
        }
        mutating func value(depth: Int) throws -> OrderedJSON {
            nodes += 1
            guard depth <= 64, nodes <= 16_384 else { throw Invalid.json }
            whitespace()
            guard index < bytes.count else { throw Invalid.json }
            switch bytes[index] {
            case 34: return .string(try string())
            case 123:
                index += 1; whitespace()
                var fields: [Field] = []
                if take(125) { return .object(fields) }
                repeat {
                    whitespace()
                    let key = try string()
                    whitespace(); try require(58)
                    fields.append(Field(key: key, value: try value(depth: depth + 1)))
                    whitespace()
                    if take(125) { return .object(fields) }
                    try require(44)
                } while true
            case 91:
                index += 1; whitespace()
                var values: [OrderedJSON] = []
                if take(93) { return .array(values) }
                repeat {
                    values.append(try value(depth: depth + 1)); whitespace()
                    if take(93) { return .array(values) }
                    try require(44)
                } while true
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default: return .number(try number())
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try require(byte) }
        }
        mutating func number() throws -> String {
            let start = index
            _ = take(45)
            if !take(48) { try digits(nonzero: true) }
            if take(46) { try digits() }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                try digits()
            }
            guard index > start else { throw Invalid.json }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        mutating func digits(nonzero: Bool = false) throws {
            guard index < bytes.count, bytes[index] >= (nonzero ? 49 : 48), bytes[index] <= 57 else { throw Invalid.json }
            repeat { index += 1 } while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57
        }
        mutating func hex() throws -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw Invalid.json }
                let b = bytes[index]; index += 1
                let n: UInt32
                switch b {
                case 48...57: n = UInt32(b - 48)
                case 65...70: n = UInt32(b - 55)
                case 97...102: n = UInt32(b - 87)
                default: throw Invalid.json
                }
                result = result * 16 + n
            }
            return result
        }
        mutating func string() throws -> String {
            try require(34)
            var output: [UInt8] = []
            while index < bytes.count {
                let b = bytes[index]; index += 1
                if b == 34 {
                    guard let text = String(bytes: output, encoding: .utf8) else { throw Invalid.json }
                    return text
                }
                guard b >= 32 else { throw Invalid.json }
                if b != 92 { output.append(b); continue }
                guard index < bytes.count else { throw Invalid.json }
                let escape = bytes[index]; index += 1
                switch escape {
                case 34, 47, 92: output.append(escape)
                case 98: output.append(8)
                case 102: output.append(12)
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 117:
                    var code = try hex()
                    if (0xD800...0xDBFF).contains(code) {
                        try require(92); try require(117)
                        let low = try hex()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Invalid.json }
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    }
                    guard let scalar = UnicodeScalar(code) else { throw Invalid.json }
                    output.append(contentsOf: String(scalar).utf8)
                default: throw Invalid.json
                }
            }
            throw Invalid.json
        }
    }
}

import Foundation

/// The Godot version a pack says it was exported by.
struct GodotEngineVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// A release's engine version as the server names it ("4.7", "4.7.2").
    init?(_ text: String) {
        let parts = text.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(major: parts[0], minor: parts[1])
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    var description: String { "\(major).\(minor)" }
}

/// The file table of a Godot pack, read without loading the pack: each file's
/// path (relative to `res://`) and a digest of its bytes. A PCK (format 2 to 4)
/// carries an MD5 per file; a ZIP pack, its CRC-32 and size. That is all the
/// player needs to tell what a new build changed (`GodotPackPolicy`) and what
/// it refuses to hand the engine (`refusedFile`).
struct GodotPackIndex: Hashable, Sendable {
    enum Format: Hashable, Sendable {
        case pck, zip
    }

    enum ReadError: Error, Hashable, Sendable {
        /// Neither a PCK header nor a ZIP directory.
        case notAPack
        case unsupportedVersion(UInt32)
        /// An encrypted directory: Oppi has no key and cannot check the files.
        case encrypted
        /// A sparse bundle keeps its files beside the PCK; a pack is one file here.
        case sparseBundle
        case truncated
    }

    let format: Format
    /// Digest per path. A patch pack's removal of a file reads as no digest.
    let files: [String: Data?]
    /// The Godot version a PCK names; ZIP packs name none.
    let engineVersion: GodotEngineVersion?

    init(format: Format, files: [String: Data?], engineVersion: GodotEngineVersion?) {
        self.format = format
        self.files = files
        self.engineVersion = engineVersion
    }

    /// Reads a pack of `size` bytes through `read(offset, count)`.
    init(size: UInt64, read: @escaping (UInt64, Int) throws -> Data) throws {
        let reader = Reader(size: size, read: read)
        if size >= 4, try reader.u32(at: 0) == Self.pckMagic {
            self = try Self.readPCK(reader)
        } else {
            self = try Self.readZIP(reader)
        }
    }

    init(data: Data) throws {
        try self.init(size: UInt64(data.count)) { offset, count in
            let start = Int(offset)
            guard start >= 0, count >= 0, start + count <= data.count else { throw ReadError.truncated }
            return data.subdata(in: data.startIndex + start ..< data.startIndex + start + count)
        }
    }

    init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try self.init(size: size) { offset, count in
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ReadError.truncated }
            return data
        }
    }

    /// The first file, by path, that would run native code or a .NET
    /// assembly, or list a GDExtension. Oppi runs GDScript only (design §10).
    var refusedFile: String? {
        files.keys.sorted().first(where: Self.isNativeCode)
    }

    static func isNativeCode(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower == ".godot/extension_list.cfg" { return true }
        if lower.contains(".framework/") || lower.contains(".xcframework/") { return true }
        return [".dylib", ".so", ".dll", ".a", ".gdextension", ".framework", ".xcframework"].contains { lower.hasSuffix($0) }
    }

    // MARK: PCK

    static let pckMagic: UInt32 = 0x4350_4447 // "GDPC"
    private static let directoryEncrypted: UInt32 = 1 << 0
    private static let sparseBundle: UInt32 = 1 << 2
    private static let fileRemoval: UInt32 = 1 << 1

    private static func readPCK(_ reader: Reader) throws -> Self {
        var offset: UInt64 = 4
        let version = try reader.u32(at: offset)
        guard (2...4).contains(version) else { throw ReadError.unsupportedVersion(version) }
        let major = try reader.u32(at: offset + 4)
        let minor = try reader.u32(at: offset + 8)
        offset += 16 // version, major, minor, patch
        let flags = try reader.u32(at: offset)
        offset += 4
        guard flags & directoryEncrypted == 0 else { throw ReadError.encrypted }
        guard version < 4 || flags & sparseBundle == 0 else { throw ReadError.sparseBundle }
        offset += 8 // file base
        if version >= 3 {
            offset = try reader.u64(at: offset)
        } else {
            offset += 16 * 4 // reserved
        }
        let count = try reader.u32(at: offset)
        offset += 4
        var files: [String: Data?] = [:]
        for _ in 0..<count {
            let length = try reader.u32(at: offset)
            guard length <= 4096 else { throw ReadError.truncated }
            let raw = try reader.bytes(at: offset + 4, count: Int(length))
            offset += 4 + UInt64(length)
            offset += 16 // offset, size
            let md5 = try reader.bytes(at: offset, count: 16)
            let fileFlags = try reader.u32(at: offset + 16)
            offset += 20
            let path = normalised(String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self))
            let digest: Data? = fileFlags & fileRemoval == 0 ? md5 : nil
            files[path] = .some(digest)
        }
        return Self(format: .pck, files: files, engineVersion: GodotEngineVersion(major: Int(major), minor: Int(minor)))
    }

    // MARK: ZIP

    private static func readZIP(_ reader: Reader) throws -> Self {
        // The end-of-central-directory record sits in the last 64 KiB + 22 bytes.
        let tailLength = Int(min(reader.size, 65_557))
        guard tailLength >= 22 else { throw ReadError.notAPack }
        let tailStart = reader.size - UInt64(tailLength)
        let tail = try reader.bytes(at: tailStart, count: tailLength)
        guard let end = (0...(tailLength - 22)).reversed().first(where: {
            tail[tail.startIndex + $0] == 0x50 && tail[tail.startIndex + $0 + 1] == 0x4B
                && tail[tail.startIndex + $0 + 2] == 0x05 && tail[tail.startIndex + $0 + 3] == 0x06
        }) else { throw ReadError.notAPack }
        let endOffset = tailStart + UInt64(end)
        let count = Int(try reader.u16(at: endOffset + 10))
        var offset = UInt64(try reader.u32(at: endOffset + 16))
        var files: [String: Data?] = [:]
        for _ in 0..<count {
            guard try reader.u32(at: offset) == 0x0201_4B50 else { throw ReadError.truncated }
            let crc = try reader.bytes(at: offset + 16, count: 4)
            let size = try reader.bytes(at: offset + 24, count: 4)
            let nameLength = Int(try reader.u16(at: offset + 28))
            let extraLength = Int(try reader.u16(at: offset + 30))
            let commentLength = Int(try reader.u16(at: offset + 32))
            let name = try reader.bytes(at: offset + 46, count: nameLength)
            offset += 46 + UInt64(nameLength + extraLength + commentLength)
            let path = normalised(String(decoding: name, as: UTF8.self))
            guard !path.hasSuffix("/") else { continue }
            files[path] = .some(crc + size)
        }
        return Self(format: .zip, files: files, engineVersion: nil)
    }

    private static func normalised(_ path: String) -> String {
        var path = path
        if path.hasPrefix("res://") { path.removeFirst(6) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    /// Little-endian reads through the caller's `read`.
    private struct Reader {
        let size: UInt64
        let read: (UInt64, Int) throws -> Data

        func bytes(at offset: UInt64, count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ReadError.truncated }
            return try read(offset, count)
        }

        func u16(at offset: UInt64) throws -> UInt16 {
            let data = try bytes(at: offset, count: 2)
            return data.reversed().reduce(0) { $0 << 8 | UInt16($1) }
        }

        func u32(at offset: UInt64) throws -> UInt32 {
            let data = try bytes(at: offset, count: 4)
            return data.reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        func u64(at offset: UInt64) throws -> UInt64 {
            let data = try bytes(at: offset, count: 8)
            return data.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
    }
}

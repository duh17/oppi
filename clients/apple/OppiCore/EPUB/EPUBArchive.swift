import Compression
import Foundation

/// Budgets for a ZIP container from an untrusted book.
///
/// A book arrives over the network from a workspace or a host path, so every
/// number the archive states about itself is checked against these limits
/// before the reader trusts it. A violation means the entry is not there:
/// the book is still a book, it just cannot show that part.
enum EPUBArchiveLimits {
    /// The end-of-central-directory record sits in the last 64 KiB of a ZIP
    /// without ZIP64; anything further back is not a container we can read.
    static let endOfCentralDirectoryWindow = 64 * 1024
    static let maximumEntries = 10_000
    /// The reading order the package declares. Every chapter costs the reader a
    /// title and a table-of-contents row, and a longer order is a file that
    /// pretends to be a book, so it is refused rather than half shown.
    static let maximumSpineItems = 5_000
    static let maximumTextEntryBytes = 16 * 1024 * 1024
    static let maximumImageEntryBytes = 32 * 1024 * 1024
    /// Above this many declared bytes, an entry that expands more than this
    /// ratio is a zip bomb rather than text.
    static let compressionRatioFloorBytes = 1024 * 1024
    static let maximumCompressionRatio = 100
}

enum EPUBArchiveError: Error, Equatable {
    /// The file is not a ZIP container we can read (no end record, ZIP64,
    /// an entry outside the file).
    case notAnArchive
    /// The entry is absent, encrypted, uses a method we do not read, or is
    /// over its budget.
    case entryUnavailable(String)
    /// The entry's bytes do not inflate the way its header says.
    case corruptEntry(String)
}

/// The ZIP half of an EPUB: the central directory read once, and one entry's
/// bytes on demand. Never writes, never follows a name to the filesystem.
///
/// The reader holds the central directory only, so an illustrated book costs
/// its archive bytes plus the one chapter being read.
struct EPUBArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        /// Encrypted entries (general-purpose bit 0) are refused: DRM.
        let isEncrypted: Bool
    }

    static let storedMethod: UInt16 = 0
    static let deflateMethod: UInt16 = 8

    private let data: Data
    private let entries: [String: Entry]

    init(data: Data) {
        self.data = data
        self.entries = Self.readCentralDirectory(in: data)
    }

    var entryNames: [String] { entries.keys.sorted() }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    /// The entry's bytes, or an error that callers treat as a missing entry.
    func data(for path: String) throws -> Data {
        guard let entry = entries[path], !entry.isEncrypted else {
            throw EPUBArchiveError.entryUnavailable(path)
        }
        let limit = Self.byteLimit(forEntryNamed: path)
        guard entry.uncompressedSize <= limit else {
            throw EPUBArchiveError.entryUnavailable(path)
        }
        if entry.method == Self.deflateMethod,
           entry.uncompressedSize > EPUBArchiveLimits.compressionRatioFloorBytes,
           entry.compressedSize > 0,
           entry.uncompressedSize / entry.compressedSize > EPUBArchiveLimits.maximumCompressionRatio {
            throw EPUBArchiveError.entryUnavailable(path)
        }

        let payload = try compressedBytes(of: entry)
        switch entry.method {
        case Self.storedMethod:
            guard payload.count == entry.uncompressedSize else {
                throw EPUBArchiveError.corruptEntry(path)
            }
            return payload
        case Self.deflateMethod:
            return try Self.inflate(payload, into: entry.uncompressedSize, name: path)
        default:
            throw EPUBArchiveError.entryUnavailable(path)
        }
    }

    /// Text and XHTML stay small so a chapter cannot ask for the whole budget;
    /// images (unused in this slice) are allowed more.
    static func byteLimit(forEntryNamed name: String) -> Int {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tif", "tiff":
            return EPUBArchiveLimits.maximumImageEntryBytes
        default:
            return EPUBArchiveLimits.maximumTextEntryBytes
        }
    }

    private func compressedBytes(of entry: Entry) throws -> Data {
        guard entry.localHeaderOffset >= 0, entry.localHeaderOffset + 30 <= data.count else {
            throw EPUBArchiveError.corruptEntry(entry.name)
        }
        guard Self.uint32(data, at: entry.localHeaderOffset) == 0x0403_4b50 else {
            throw EPUBArchiveError.corruptEntry(entry.name)
        }
        let nameLength = Int(Self.uint16(data, at: entry.localHeaderOffset + 26))
        let extraLength = Int(Self.uint16(data, at: entry.localHeaderOffset + 28))
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else {
            throw EPUBArchiveError.corruptEntry(entry.name)
        }
        return data.subdata(in: start..<end)
    }

    // MARK: - Central directory

    private static func readCentralDirectory(in data: Data) -> [String: Entry] {
        guard let eocd = endOfCentralDirectory(in: data) else { return [:] }
        let entryCount = Int(uint16(data, at: eocd + 10))
        let directorySize = Int(uint32(data, at: eocd + 12))
        let directoryOffset = Int(uint32(data, at: eocd + 16))
        // 0xFFFF/0xFFFFFFFF are the ZIP64 escape values; we do not read ZIP64.
        guard entryCount != 0xFFFF,
              directoryOffset != Int(UInt32.max),
              directorySize != Int(UInt32.max),
              entryCount <= EPUBArchiveLimits.maximumEntries,
              directoryOffset >= 0,
              directorySize >= 0,
              directoryOffset + directorySize <= data.count else { return [:] }

        var entries: [String: Entry] = [:]
        entries.reserveCapacity(entryCount)
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, uint32(data, at: cursor) == 0x0201_4b50 else {
                return [:]
            }
            let flags = uint16(data, at: cursor + 8)
            let method = uint16(data, at: cursor + 10)
            let compressedSize = Int(uint32(data, at: cursor + 20))
            let uncompressedSize = Int(uint32(data, at: cursor + 24))
            let nameLength = Int(uint16(data, at: cursor + 28))
            let extraLength = Int(uint16(data, at: cursor + 30))
            let commentLength = Int(uint16(data, at: cursor + 32))
            let localHeaderOffset = Int(uint32(data, at: cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { return [:] }
            let rawName = data.subdata(in: nameStart..<nameEnd)
            cursor = nameEnd + extraLength + commentLength
            guard let name = normalizedName(rawName), !name.isEmpty else { continue }
            entries[name] = Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isEncrypted: flags & 0x1 != 0
            )
        }
        return entries
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        let count = data.count
        guard count >= 22 else { return nil }
        let earliest = max(0, count - EPUBArchiveLimits.endOfCentralDirectoryWindow - 22)
        var offset = count - 22
        while offset >= earliest {
            if uint32(data, at: offset) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// A ZIP name becomes an archive path: forward slashes, no leading `./`,
    /// no absolute root, no backslash or NUL. Such an entry is skipped.
    private static func normalizedName(_ raw: Data) -> String? {
        guard let decoded = String(data: raw, encoding: .utf8)
            ?? String(data: raw, encoding: .isoLatin1) else { return nil }
        guard !decoded.contains("\0"), !decoded.contains("\\") else { return nil }
        var name = decoded
        while name.hasPrefix("./") { name.removeFirst(2) }
        while name.hasPrefix("/") { name.removeFirst() }
        return name
    }

    // MARK: - Inflate

    /// Raw DEFLATE (RFC 1951), which is what ZIP method 8 stores and what
    /// `Compression`'s `.zlib` decodes. The destination is the declared size,
    /// already bounded by the caller's budget, plus one byte: a payload that
    /// inflates past its declaration fills that byte and is refused, instead of
    /// being truncated into a chapter that looks real.
    private static func inflate(_ payload: Data, into size: Int, name: String) throws -> Data {
        guard size > 0 else {
            guard payload.isEmpty else { throw EPUBArchiveError.corruptEntry(name) }
            return Data()
        }
        let ceiling = size + 1
        var output = Data(count: ceiling)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let base = destination.baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    base.assumingMemoryBound(to: UInt8.self),
                    ceiling,
                    sourceBase.assumingMemoryBound(to: UInt8.self),
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw EPUBArchiveError.corruptEntry(name) }
        return output.prefix(size)
    }

    // MARK: - Little-endian fields

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

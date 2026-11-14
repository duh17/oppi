import Foundation
import Testing
@testable import Oppi

/// Reading a pack's file table without loading it: a real export from the
/// sample project (PCK v3+), a ZIP patch, and packs Oppi cannot check.
@Suite("GodotPackIndex")
struct GodotPackIndexTests {
    @Test func readsAGodotExport() throws {
        let url = try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck"))
        let index = try GodotPackIndex(contentsOf: url)
        #expect(index.format == .pck)
        #expect(index.engineVersion == GodotEngineVersion(major: 4, minor: 7))
        for path in ["project.binary", "main.gd", "probe.gd", "main.tscn.remap"] {
            let digest = try #require(index.files[path], "\(path) is in the sample's pack")
            #expect(digest?.count == 16, "\(path) carries its MD5")
        }
        #expect(index.files.keys.allSatisfy { !$0.hasPrefix("res://") && !$0.hasPrefix("/") })
        #expect(index.refusedFile == nil)
        // The same bytes read from memory give the same table.
        #expect(try GodotPackIndex(data: Data(contentsOf: url)) == index)
    }

    @Test func readsAZipPatch() throws {
        let zip = Self.zip([("main.gd", 0x1234_5678, 42), ("scenes/", 0, 0), ("res://player.gd", 0x0BAD_F00D, 7)])
        let index = try GodotPackIndex(data: zip)
        #expect(index.format == .zip)
        #expect(Set(index.files.keys) == ["main.gd", "player.gd"], "Folders are not files; res:// is dropped")
        #expect(index.files["main.gd"] != index.files["player.gd"])
    }

    @Test func aChangedZipEntryChangesItsDigest() throws {
        let before = try GodotPackIndex(data: Self.zip([("main.gd", 1, 10)]))
        let after = try GodotPackIndex(data: Self.zip([("main.gd", 2, 10)]))
        #expect(before.files["main.gd"] != after.files["main.gd"])
    }

    @Test func anEncryptedDirectoryIsRefused() throws {
        var header = Self.pckHeader(version: 3, flags: 1)
        header.append(contentsOf: [UInt8](repeating: 0, count: 64))
        #expect(throws: GodotPackIndex.ReadError.encrypted) { try GodotPackIndex(data: header) }
    }

    @Test func aTruncatedPackAndOtherFilesAreRefused() throws {
        #expect(throws: GodotPackIndex.ReadError.self) { try GodotPackIndex(data: Self.pckHeader(version: 3, flags: 0)) }
        #expect(throws: GodotPackIndex.ReadError.notAPack) { try GodotPackIndex(data: Data("not a pack at all, just words".utf8)) }
        #expect(throws: GodotPackIndex.ReadError.unsupportedVersion(9)) { try GodotPackIndex(data: Self.pckHeader(version: 9, flags: 0)) }
    }

    // MARK: Builders

    /// A PCK header up to its flags.
    static func pckHeader(version: UInt32, flags: UInt32) -> Data {
        var data = Data()
        for value in [0x4350_4447, version, 4, 7, 2, flags] as [UInt32] { data.append(le32(value)) }
        return data
    }

    /// A ZIP of empty local entries with the given names, CRCs and sizes,
    /// and its central directory.
    static func zip(_ entries: [(name: String, crc: UInt32, size: UInt32)]) -> Data {
        var data = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(data.count)
            data.append(le32(0x0403_4B50))
            data.append(Data(count: 10))
            data.append(le32(entry.crc))
            data.append(le32(entry.size))
            data.append(le32(entry.size))
            data.append(le16(UInt16(name.count)))
            data.append(le16(0))
            data.append(name)
            central.append(le32(0x0201_4B50))
            central.append(Data(count: 12))
            central.append(le32(entry.crc))
            central.append(le32(entry.size))
            central.append(le32(entry.size))
            central.append(le16(UInt16(name.count)))
            central.append(Data(count: 12))
            central.append(le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(data.count)
        data.append(central)
        data.append(le32(0x0605_4B50))
        data.append(Data(count: 4))
        data.append(le16(UInt16(entries.count)))
        data.append(le16(UInt16(entries.count)))
        data.append(le32(UInt32(central.count)))
        data.append(le32(centralOffset))
        data.append(le16(0))
        return data
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

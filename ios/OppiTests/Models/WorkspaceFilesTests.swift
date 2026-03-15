import Foundation
import Testing
@testable import Oppi

@Suite("WorkspaceFiles models")
struct WorkspaceFilesTests {
    // MARK: - FileEntry

    @Test func fileEntryDecodesFile() throws {
        let json = """
        {"name":"index.ts","type":"file","size":1234,"modifiedAt":1710000000000}
        """
        let entry = try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
        #expect(entry.name == "index.ts")
        #expect(entry.type == .file)
        #expect(entry.size == 1234)
        #expect(entry.modifiedAt == 1_710_000_000_000)
        #expect(entry.isFile)
        #expect(!entry.isDirectory)
        #expect(entry.path == nil)
    }

    @Test func fileEntryDecodesDirectory() throws {
        let json = """
        {"name":"src","type":"directory","size":0,"modifiedAt":1710000000000}
        """
        let entry = try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
        #expect(entry.isDirectory)
        #expect(!entry.isFile)
    }

    @Test func fileEntryDecodesSearchResultWithPath() throws {
        let json = """
        {"name":"Button.tsx","type":"file","size":500,"modifiedAt":1710000000000,"path":"src/components/Button.tsx"}
        """
        let entry = try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
        #expect(entry.path == "src/components/Button.tsx")
        #expect(entry.id == "src/components/Button.tsx")
    }

    @Test func fileEntryIdFallsBackToName() throws {
        let json = """
        {"name":"README.md","type":"file","size":100,"modifiedAt":1710000000000}
        """
        let entry = try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
        #expect(entry.id == "README.md")
    }

    // MARK: - formattedSize

    @Test func formattedSizeBytes() throws {
        let entry = FileEntry(name: "tiny.txt", type: .file, size: 42, modifiedAt: 0, path: nil)
        #expect(entry.formattedSize == "42 B")
    }

    @Test func formattedSizeKB() throws {
        let entry = FileEntry(name: "small.txt", type: .file, size: 2048, modifiedAt: 0, path: nil)
        #expect(entry.formattedSize == "2.0 KB")
    }

    @Test func formattedSizeMB() throws {
        let entry = FileEntry(name: "large.bin", type: .file, size: 1_500_000, modifiedAt: 0, path: nil)
        #expect(entry.formattedSize == "1.4 MB")
    }

    @Test func formattedSizeDirectoryIsEmpty() throws {
        let entry = FileEntry(name: "src", type: .directory, size: 0, modifiedAt: 0, path: nil)
        #expect(entry.formattedSize == "")
    }

    // MARK: - DirectoryListingResponse

    @Test func directoryListingDecodes() throws {
        let json = """
        {
          "path": "src/",
          "entries": [
            {"name":"components","type":"directory","size":0,"modifiedAt":1710000000000},
            {"name":"index.ts","type":"file","size":500,"modifiedAt":1710000000000}
          ],
          "truncated": false
        }
        """
        let listing = try JSONDecoder().decode(DirectoryListingResponse.self, from: Data(json.utf8))
        #expect(listing.path == "src/")
        #expect(listing.entries.count == 2)
        #expect(!listing.truncated)
        #expect(listing.entries[0].isDirectory)
        #expect(listing.entries[1].isFile)
    }

    // MARK: - FileSearchResponse

    @Test func fileSearchResponseDecodes() throws {
        let json = """
        {
          "query": "button",
          "entries": [
            {"name":"Button.tsx","type":"file","size":500,"modifiedAt":1710000000000,"path":"src/components/Button.tsx"}
          ],
          "truncated": true
        }
        """
        let response = try JSONDecoder().decode(FileSearchResponse.self, from: Data(json.utf8))
        #expect(response.query == "button")
        #expect(response.entries.count == 1)
        #expect(response.truncated)
        #expect(response.entries[0].path == "src/components/Button.tsx")
    }
}

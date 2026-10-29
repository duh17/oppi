import Foundation
import Testing
@testable import Oppi

/// Sorting, hidden files, search scope, and Git marks: what a folder listing
/// shows and in which order.
@Suite("File browser view options")
struct FileBrowserViewOptionsTests {
    private let listing = [
        entry("src", directory: true, size: 0, modified: 50),
        entry("file10.txt", size: 300, modified: 10),
        entry(".env", size: 20, modified: 40),
        entry("File2.swift", size: 300, modified: 30),
        entry("README", size: 900, modified: 20),
        entry("assets", directory: true, size: 0, modified: 5),
    ]

    @Test func nameSortIsFinderOrderWithFoldersFirst() {
        let options = FileBrowserViewOptions()
        #expect(options.arranged(listing).map(\.name) == ["assets", "src", ".env", "File2.swift", "file10.txt", "README"])
    }

    @Test func choosingTheSameKeyFlipsAndANewKeyStartsInItsOwnDirection() {
        var options = FileBrowserViewOptions()
        options.choose(.name)
        #expect(options.arranged(listing).map(\.name) == ["src", "assets", "README", "file10.txt", "File2.swift", ".env"])

        options.choose(.modified)
        #expect(options.sortKey == .modified && !options.ascending)
        #expect(options.arranged(listing).map(\.name) == ["src", "assets", ".env", "File2.swift", "README", "file10.txt"])

        options.choose(.kind)
        #expect(options.ascending)
    }

    /// Equal sizes fall back to the name, A to Z, in either direction; folders
    /// have no size, so they keep name order.
    @Test func sizeSortBreaksTiesByNameAndKeepsFoldersByName() {
        var options = FileBrowserViewOptions()
        options.choose(.size)
        #expect(options.arranged(listing).map(\.name) == ["assets", "src", "README", "File2.swift", "file10.txt", ".env"])
        options.choose(.size)
        #expect(options.arranged(listing).map(\.name) == ["assets", "src", ".env", "File2.swift", "file10.txt", "README"])
    }

    @Test func kindSortGroupsByExtensionWithExtensionlessFilesFirst() {
        var options = FileBrowserViewOptions()
        options.choose(.kind)
        options.foldersFirst = false
        #expect(options.arranged(listing).map(\.name) == ["assets", "src", ".env", "README", "File2.swift", "file10.txt"])
    }

    @Test func foldersMixWithFilesWhenFoldersFirstIsOff() {
        var options = FileBrowserViewOptions()
        options.foldersFirst = false
        options.choose(.modified)
        #expect(options.arranged(listing).map(\.name) == ["src", ".env", "File2.swift", "README", "file10.txt", "assets"])
    }

    @Test func hidingHiddenFilesDropsDotEntriesOnly() {
        var options = FileBrowserViewOptions()
        options.showsHidden = false
        #expect(options.arranged(listing).map(\.name) == ["assets", "src", "File2.swift", "file10.txt", "README"])
    }

    @MainActor
    @Test func theStoreKeepsTheChoiceOnTheDevice() throws {
        let suite = "FileBrowserViewOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = FileBrowserViewOptionsStore(defaults: defaults)
        #expect(store.options == FileBrowserViewOptions())
        store.update {
            $0.choose(.size)
            $0.showsHidden = false
        }
        let reopened = FileBrowserViewOptionsStore(defaults: defaults)
        #expect(reopened.options.sortKey == .size)
        #expect(!reopened.options.ascending)
        #expect(!reopened.options.showsHidden)
    }

    // MARK: Search scope

    @Test func folderScopeSearchesOnlyBelowTheFolder() {
        let paths = ["src/a.swift", "src/lib/b.swift", "srcx/c.swift", "docs/d.md"]
        #expect(FileBrowserSearchScope.folder.candidates(paths, folder: "src/") == ["src/a.swift", "src/lib/b.swift"])
        #expect(FileBrowserSearchScope.folder.candidates(paths, folder: "src") == ["src/a.swift", "src/lib/b.swift"])
        #expect(FileBrowserSearchScope.everywhere.candidates(paths, folder: "src/") == paths)
        #expect(FileBrowserSearchScope.titles(folderName: nil) == nil)
        #expect(FileBrowserSearchScope.titles(folderName: "src") == ["Everywhere", "src"])
    }

    // MARK: Git marks

    @Test func marksFollowGitsStatusCodesAndReachEveryAncestorFolder() throws {
        let marks = FileBrowserChangeMarks([
            GitFileStatus(status: " M", path: "src/lib/a.swift", addedLines: 3, removedLines: 1),
            GitFileStatus(status: "??", path: "notes.md", addedLines: nil, removedLines: nil),
            GitFileStatus(status: "R ", path: "old.swift -> src/new.swift", addedLines: nil, removedLines: nil),
            GitFileStatus(status: " D", path: "gone.txt", addedLines: 0, removedLines: 5),
            GitFileStatus(status: "UU", path: "merge.swift", addedLines: nil, removedLines: nil),
            GitFileStatus(status: "??", path: "fresh/", addedLines: nil, removedLines: nil),
        ])

        let modified = try #require(marks.mark(forFile: "src/lib/a.swift"))
        #expect(modified.kind == .modified)
        #expect(modified.spokenDescription == "Modified, 3 added, 1 removed")
        #expect(marks.mark(forFile: "notes.md")?.kind == .added)
        #expect(marks.mark(forFile: "src/new.swift")?.kind == .renamed)
        #expect(marks.mark(forFile: "old.swift -> src/new.swift") == nil)
        #expect(marks.mark(forFile: "gone.txt")?.kind == .deleted)
        #expect(marks.mark(forFile: "merge.swift")?.kind == .conflicted)
        // An untracked folder Git reports whole: everything in it is added.
        #expect(marks.mark(forFile: "fresh/deep/x.swift")?.kind == .added)
        #expect(marks.mark(forFile: "src/lib/other.swift") == nil)

        #expect(marks.folderHasChanges("src/"))
        #expect(marks.folderHasChanges("src/lib"))
        #expect(marks.folderHasChanges("fresh/"))
        #expect(!marks.folderHasChanges("docs/"))
        #expect(!marks.folderHasChanges("sr/"))
    }
}

private func entry(_ name: String, directory: Bool = false, size: Int, modified: Int) -> FileEntry {
    FileEntry(name: name, type: directory ? .directory : .file, size: size, modifiedAt: modified, path: nil)
}

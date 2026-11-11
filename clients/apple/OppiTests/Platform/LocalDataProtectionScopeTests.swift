import Foundation
import Testing
@testable import Oppi

/// The file-protection upgrade rewrites the protection class of every file it
/// walks. The unsandboxed Mac build sees the user's whole `~/Library`, and one
/// early Mac launch moved thousands of other apps' files to Class B, so the walk
/// must stay inside Oppi's own folders whatever sits beside them.
@Suite("Local data protection scope")
struct LocalDataProtectionScopeTests {
    private let fileManager = FileManager.default
    private let bundleIdentifier = "dev.chenda.Oppi"

    /// A user Library as the Mac build sees it: other apps' folders beside
    /// Oppi's, a shared temporary folder, and a symlink out of Oppi's folder.
    private func makeSharedLibrary() throws -> (home: URL, layout: LocalDataProtection.StorageLayout) {
        let home = fileManager.temporaryDirectory
            .appending(path: "data-protection-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let support = library.appending(path: "Application Support", directoryHint: .isDirectory)
        let caches = library.appending(path: "Caches", directoryHint: .isDirectory)
        let temporary = home.appending(path: "T", directoryHint: .isDirectory)
        let group = library.appending(path: "Group Containers/group.oppi", directoryHint: .isDirectory)

        let files = [
            support.appending(path: "Zed/db/state.sqlite"),
            support.appending(path: "Music/library.musicdb"),
            support.appending(path: "\(bundleIdentifier)/cache/timeline.json"),
            caches.appending(path: "com.other.app/blob"),
            caches.appending(path: "\(bundleIdentifier)/FileBrowser/tree.json"),
            temporary.appending(path: "other-app-scratch.tmp"),
            group.appending(path: "Inbox/shared.png"),
            group.appending(path: "Library/Preferences/group.oppi.plist"),
        ]
        for file in files {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        try fileManager.createSymbolicLink(
            at: support.appending(path: "\(bundleIdentifier)/escape"),
            withDestinationURL: support.appending(path: "Zed", directoryHint: .isDirectory)
        )

        let layout = LocalDataProtection.StorageLayout(
            applicationSupport: support,
            caches: caches,
            temporary: temporary,
            appGroup: group,
            bundleIdentifier: bundleIdentifier,
            sharesUserLibrary: true
        )
        return (home, layout)
    }

    private func walkedPaths(_ layout: LocalDataProtection.StorageLayout) -> [String] {
        var walked: [String] = []
        let failures = LocalDataProtection.walk(
            LocalDataProtection.storageRoots(layout),
            excluding: LocalDataProtection.excludedPaths(appGroup: layout.appGroup),
            fileManager: fileManager
        ) { walked.append(URL(filePath: $0).standardizedFileURL.path) }
        #expect(failures == 0)
        return walked
    }

    @Test func sharedLibraryWalkStaysInsideOppisOwnFolders() throws {
        let (home, layout) = try makeSharedLibrary()
        defer { try? fileManager.removeItem(at: home) }

        let walked = walkedPaths(layout)

        let ownFolders = [
            layout.applicationSupport.appending(path: bundleIdentifier),
            layout.caches.appending(path: bundleIdentifier),
            try #require(layout.appGroup),
        ].map { $0.standardizedFileURL.path }
        let outside = walked.filter { path in
            !ownFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        #expect(outside.isEmpty, "walked outside Oppi's folders: \(outside)")

        // Oppi's own files are still upgraded, the symlink is not entered, and
        // cfprefsd's plists in the group stay out.
        let walkedNames = Set(walked.map { URL(filePath: $0).lastPathComponent })
        #expect(walkedNames.isSuperset(of: ["timeline.json", "tree.json", "shared.png", "escape"]))
        #expect(!walkedNames.contains("state.sqlite"))
        #expect(!walkedNames.contains("group.oppi.plist"))
    }

    /// In the iOS container every system folder is Oppi's, so the pass keeps
    /// walking all of them, the temporary folder included.
    @Test func containerRootsAreTheContainersFolders() throws {
        let (home, shared) = try makeSharedLibrary()
        defer { try? fileManager.removeItem(at: home) }
        var layout = shared
        layout.sharesUserLibrary = false

        let roots = LocalDataProtection.storageRoots(layout)

        #expect(roots == [layout.applicationSupport, layout.caches, layout.temporary, try #require(layout.appGroup)])
    }
}

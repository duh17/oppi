import Foundation

/// How Git changed one file, as the browser marks it.
struct FileBrowserChangeMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        case conflicted
    }

    let kind: Kind
    let addedLines: Int?
    let removedLines: Int?

    /// The porcelain code (`" M"`, `"??"`, `"R "`, `"UU"`): untracked and
    /// added files are added; any unmerged pair is a conflict.
    init(_ file: GitFileStatus) {
        kind = Self.kind(status: file.status)
        addedLines = file.addedLines
        removedLines = file.removedLines
    }

    init(kind: Kind, addedLines: Int?, removedLines: Int?) {
        self.kind = kind
        self.addedLines = addedLines
        self.removedLines = removedLines
    }

    private static func kind(status: String) -> Kind {
        let code = Array(status)
        let index = code.first ?? " "
        let worktree = code.dropFirst().first ?? " "
        if status == "??" { return .added }
        if index == "U" || worktree == "U" || status == "AA" || status == "DD" { return .conflicted }
        if index == "R" || worktree == "R" || index == "C" { return .renamed }
        if index == "D" || worktree == "D" { return .deleted }
        if index == "A" || worktree == "A" { return .added }
        return .modified
    }

    /// VoiceOver's words for the mark, after the file's name.
    var spokenDescription: String {
        var parts = [kind.spokenName]
        if let addedLines, addedLines > 0 { parts.append(String(localized: "\(addedLines) added")) }
        if let removedLines, removedLines > 0 { parts.append(String(localized: "\(removedLines) removed")) }
        return parts.joined(separator: ", ")
    }
}

extension FileBrowserChangeMark.Kind {
    var spokenName: String {
        switch self {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .conflicted: String(localized: "Conflicted")
        }
    }
}

/// The checkout's changed files, keyed for a folder listing: a file's own
/// mark, and every folder that has a change somewhere below it. Paths are
/// Git's, relative to the repository root, which is the workspace root for
/// a workspace that is a repository.
struct FileBrowserChangeMarks: Equatable, Sendable {
    private var files: [String: FileBrowserChangeMark] = [:]
    /// Folder paths ending in "/".
    private var folders: Set<String> = []
    /// Untracked folders Git reports whole (`?? dir/`): everything in them
    /// is added.
    private var addedFolders: [String: FileBrowserChangeMark] = [:]

    static let none = Self()

    var isEmpty: Bool { files.isEmpty }

    init() {}

    init(_ changed: [GitFileStatus]) {
        for file in changed {
            let path = Self.normalized(Self.currentPath(file.path))
            guard !path.isEmpty else { continue }
            if path.hasSuffix("/") {
                addedFolders[path] = FileBrowserChangeMark(file)
                folders.insert(path)
            } else {
                files[path] = FileBrowserChangeMark(file)
            }
            var prefix = ""
            for component in path.split(separator: "/").dropLast(path.hasSuffix("/") ? 0 : 1) {
                prefix += component + "/"
                folders.insert(prefix)
            }
        }
    }

    func mark(forFile path: String) -> FileBrowserChangeMark? {
        let path = Self.normalized(path)
        if let mark = files[path] { return mark }
        guard !addedFolders.isEmpty else { return nil }
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += component + "/"
            if let folder = addedFolders[prefix] {
                return FileBrowserChangeMark(kind: folder.kind, addedLines: nil, removedLines: nil)
            }
        }
        return nil
    }

    /// `path` is a folder path; with or without its trailing "/".
    func folderHasChanges(_ path: String) -> Bool {
        let normalized = Self.normalized(path)
        guard !normalized.isEmpty else { return !files.isEmpty }
        return folders.contains(normalized.hasSuffix("/") ? normalized : normalized + "/")
    }

    /// A rename's porcelain path is `old -> new`; the file is at `new`.
    private static func currentPath(_ path: String) -> String {
        guard let arrow = path.range(of: " -> ") else { return path }
        return String(path[arrow.upperBound...])
    }

    /// Leading "./" and "/" dropped, so index, listing, and Git paths meet.
    private static func normalized(_ path: String) -> String {
        var path = Substring(path)
        while path.hasPrefix("./") { path = path.dropFirst(2) }
        while path.hasPrefix("/") { path = path.dropFirst() }
        return String(path)
    }
}

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

    /// Git reported more changes than its status lists (`GitStatus.totalFiles`
    /// past its file cap): an unmarked file may still be changed.
    private(set) var unlistedCount = 0

    static let none = Self()

    var isEmpty: Bool { files.isEmpty && addedFolders.isEmpty }

    init() {}

    /// `totalCount`: every change Git counted, listed or not.
    init(_ changed: [GitFileStatus], totalCount: Int? = nil) {
        unlistedCount = max(0, (totalCount ?? changed.count) - changed.count)
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

    /// A rename's porcelain path is `old -> new`; the file is at `new`. Git
    /// C-quotes a path with special characters (`"a b\"c.txt"`, octal
    /// bytes for non-ASCII), each side of a rename on its own.
    private static func currentPath(_ path: String) -> String {
        let current: Substring
        if let arrow = path.range(of: " -> ") {
            current = path[arrow.upperBound...]
        } else {
            current = path[...]
        }
        return unquoted(current)
    }

    /// Git's C-quoting undone: `\\`, `\"`, `\t`, `\n`, the other C escapes,
    /// and `\NNN` octal bytes, decoded as UTF-8. An unquoted path comes back
    /// as it is.
    static func unquoted(_ path: Substring) -> String {
        guard path.count >= 2, path.first == "\"", path.last == "\"" else { return String(path) }
        let body = Array(path.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count)
        var index = 0
        while index < body.count {
            let byte = body[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < body.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let next = body[index + 1]
            let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
            if octal.contains(next), index + 3 < body.count,
               octal.contains(body[index + 2]), octal.contains(body[index + 3]) {
                let value = (Int(next) - 48) * 64 + (Int(body[index + 2]) - 48) * 8 + (Int(body[index + 3]) - 48)
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 4
                continue
            }
            switch next {
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            default: bytes.append(next)
            }
            index += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Leading "./" and "/" dropped, so index, listing, and Git paths meet.
    private static func normalized(_ path: String) -> String {
        var path = Substring(path)
        while path.hasPrefix("./") { path = path.dropFirst(2) }
        while path.hasPrefix("/") { path = path.dropFirst() }
        return String(path)
    }
}

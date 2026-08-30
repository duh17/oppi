import Foundation

/// Routes a document into the shared viewer without carrying file bytes.
///
/// Mac and iOS paint from this identity plus a separately loaded
/// `ToolContentDescriptor`. Viewer state stores `id`, not copied output.
struct FileViewerPlan: Equatable, Sendable, Hashable, Identifiable {
    enum Source: Equatable, Sendable, Hashable {
        case workspaceFile(workspaceID: String, path: String)
        case hostFile(path: String)
        case workspaceReviewDiff(workspaceID: String, path: String)
    }

    let source: Source
    /// Non-main checkout for workspace-file bytes. Nil, blank, and `main` omit
    /// the id suffix so historical main-checkout plans keep their identity.
    let worktreeId: String?

    init(source: Source, worktreeId: String? = nil) {
        self.source = source
        switch source {
        case .workspaceFile:
            self.worktreeId = Self.normalizedWorktreeId(worktreeId)
        case .hostFile, .workspaceReviewDiff:
            self.worktreeId = nil
        }
    }

    var id: String {
        switch source {
        case .workspaceFile(let workspaceID, let path):
            if let worktreeId {
                return "workspace-file:\(workspaceID):\(worktreeId):\(path)"
            }
            return "workspace-file:\(workspaceID):\(path)"
        case .hostFile(let path):
            return "host-file:\(path)"
        case .workspaceReviewDiff(let workspaceID, let path):
            return "workspace-review-diff:\(workspaceID):\(path)"
        }
    }

    var workspaceID: String {
        switch source {
        case .workspaceFile(let workspaceID, _), .workspaceReviewDiff(let workspaceID, _):
            return workspaceID
        case .hostFile:
            return ""
        }
    }

    var path: String {
        switch source {
        case .workspaceFile(_, let path), .hostFile(let path), .workspaceReviewDiff(_, let path):
            return path
        }
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// Review diffs paint a preloaded `ToolContentDescriptor.Diff`. Do not fetch file bytes.
    var loadsFileBytes: Bool {
        switch source {
        case .workspaceFile, .hostFile:
            return true
        case .workspaceReviewDiff:
            return false
        }
    }

    static func normalizedWorktreeId(_ worktreeId: String?) -> String? {
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != WorkspaceWorktree.mainId else { return nil }
        return trimmed
    }

    static func workspaceFile(
        workspaceID: String,
        path: String,
        worktreeId: String? = nil
    ) -> FileViewerPlan {
        FileViewerPlan(
            source: .workspaceFile(workspaceID: workspaceID, path: path),
            worktreeId: worktreeId
        )
    }

    static func hostFile(path: String) -> FileViewerPlan {
        FileViewerPlan(source: .hostFile(path: path))
    }

    static func workspaceReviewDiff(workspaceID: String, path: String) -> FileViewerPlan {
        FileViewerPlan(source: .workspaceReviewDiff(workspaceID: workspaceID, path: path))
    }

    /// Wiki and Markdown file links already classified by `ResourceReference`.
    /// Session-only references stay out of the document column.
    /// `worktreeId` is the selected/source checkout; main, blank, and nil omit it.
    static func opening(reference: ResourceReference, worktreeId: String? = nil) -> FileViewerPlan? {
        // Current-session wiki links stay in chat. Compare target to
        // sourceSessionID only; do not require sourceServerID.
        // SessionTraceShellDetail always parses with workspaceID and sessionID,
        // so `[[sess-1]]` becomes workspace-file:ws-1:sess-1.md without a server id.
        if reference.lineAnchor == nil,
           let sourceSessionID = reference.sourceSessionID,
           reference.target == sourceSessionID {
            return nil
        }
        guard let path = reference.fileCandidatePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        switch reference.kind {
        case .workspaceFile:
            let workspaceID = reference.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let workspaceID, !workspaceID.isEmpty else { return nil }
            return .workspaceFile(workspaceID: workspaceID, path: path, worktreeId: worktreeId)
        case .hostFile:
            return .hostFile(path: path)
        }
    }

    static func opening(url: URL, worktreeId: String? = nil) -> FileViewerPlan? {
        guard let reference = ResourceReferenceURL.parse(url) else { return nil }
        return opening(reference: reference, worktreeId: worktreeId)
    }

    /// Directories stay folders. Any non-directory row opens the document column.
    static func opening(
        entry: FileEntry,
        workspaceID: String,
        currentPath: String,
        worktreeId: String? = nil
    ) -> FileViewerPlan? {
        guard !entry.isDirectory else { return nil }
        return .workspaceFile(
            workspaceID: workspaceID,
            path: resolvedPath(entryPath: entry.path, name: entry.name, currentPath: currentPath),
            worktreeId: worktreeId
        )
    }

    static func resolvedPath(entryPath: String?, name: String, currentPath: String) -> String {
        if let entryPath, !entryPath.isEmpty {
            return entryPath
        }
        if currentPath.isEmpty {
            return name
        }
        return currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
    }
}

/// Parse workspace file bytes once. Platforms only paint the descriptor.
enum FileViewerDescriptorBuilder {
    static func descriptor(path: String, data: Data) -> ToolContentDescriptor {
        let fileType = FileType.detect(
            from: path,
            content: String(data: data, encoding: .utf8)
        )
        if let media = streamingMediaDescriptor(path: path, fileType: fileType) {
            return media
        }
        if fileType == .pdf {
            return .file(
                ToolContentDescriptor.File(
                    text: data.base64EncodedString(),
                    filePath: path,
                    fileType: .pdf,
                    language: nil,
                    startLine: 1,
                    attachments: []
                )
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .status(message: binaryStatus(fileType, path: path))
        }
        return .file(
            ToolContentDescriptor.File(
                text: text,
                filePath: path,
                fileType: fileType,
                language: language(from: fileType),
                startLine: 1,
                attachments: []
            )
        )
    }

    /// Audio and video stream through the Mac Unix-socket range adapter.
    /// Do not download their bytes into the descriptor.
    static func needsFileBytes(path: String) -> Bool {
        switch FileType.detect(from: path) {
        case .audio, .video:
            return false
        default:
            return true
        }
    }

    private static func streamingMediaDescriptor(
        path: String,
        fileType: FileType
    ) -> ToolContentDescriptor? {
        switch fileType {
        case .audio, .video:
            return .media(
                ToolContentDescriptor.Media(
                    output: "",
                    filePath: path,
                    startLine: 1,
                    attachments: [],
                    audio: nil
                )
            )
        default:
            return nil
        }
    }

    private static func binaryStatus(_ fileType: FileType, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        switch fileType {
        case .image:
            return "\(name) is an image. Preview is not available in this column yet."
        case .binary:
            return "\(name) is a binary file."
        default:
            return "\(name) cannot be displayed as text."
        }
    }

    private static func language(from fileType: FileType) -> SyntaxLanguage? {
        switch fileType {
        case .code(let language):
            return language
        case .json:
            return .json
        case .html:
            return .html
        case .latex:
            return .latex
        case .orgMode:
            return .orgMode
        case .mermaid:
            return .mermaid
        case .graphviz:
            return .dot
        case .markdown, .image, .audio, .video, .pdf, .binary, .plain:
            return nil
        }
    }
}

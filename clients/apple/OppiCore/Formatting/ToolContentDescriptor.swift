import Foundation

/// Session attachment identity for expanded tool media.
///
/// Descriptors carry identifiers and MIME metadata only. They never contain
/// URLs, credentials, or fetch clients.
struct ToolContentMediaAttachment: Equatable, Sendable {
    let kind: String
    let id: String
    let mimeType: String
    let fileName: String?
    let sizeBytes: Int?
    let sha256: String?
    let width: Int?
    let height: Int?

    init(
        kind: String,
        id: String,
        mimeType: String,
        fileName: String?,
        sizeBytes: Int?,
        sha256: String? = nil,
        width: Int?,
        height: Int?
    ) {
        self.kind = kind
        self.id = id
        self.mimeType = mimeType
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.width = width
        self.height = height
    }
}

/// Platform-neutral expanded tool content.
///
/// Built once from tool args, details, and output. iOS and Mac paint this
/// value; they must not re-infer language, file type, or content kind.
enum ToolContentDescriptor: Equatable, Sendable {
    /// Bash command/output, generic plaintext, JSON pretty-print, or
    /// `presentationFormat: terminal` (including multi-file unified text).
    case terminal(Terminal)
    /// Single-file structured diff with absolute line numbers.
    case diff(Diff)
    /// Highlighted source from an explicit code format or a code fallback.
    case code(Code)
    /// Markdown (or converted document) body.
    case markdown(Markdown)
    /// File-backed read/write/edit body with resolved path, type, and language.
    case file(File)
    /// Attachment-backed or inline media, including voice messages.
    case media(Media)
    /// Loading or empty-body placeholder. Never a plaintext stand-in for a
    /// requested viewer.
    case status(message: String)

    struct Terminal: Equatable, Sendable {
        var output: String?
        /// Set for pretty-printed JSON that iOS still renders as `.text`.
        var language: SyntaxLanguage?
    }

    struct Diff: Equatable, Sendable {
        var lines: [DiffLine]
        var path: String?
    }

    struct Code: Equatable, Sendable {
        var text: String
        var language: SyntaxLanguage?
        var startLine: Int?
        var filePath: String?
    }

    struct Markdown: Equatable, Sendable {
        var text: String
        var filePath: String? = nil
        var rawText: String? = nil
        /// Exact prefix through the Raw Output boundary, before availability/output.
        var rawOutputPrefix: String? = nil
    }

    struct File: Equatable, Sendable {
        var text: String
        var filePath: String?
        var fileType: FileType?
        var language: SyntaxLanguage?
        var startLine: Int?
        var attachments: [ToolContentMediaAttachment]
    }

    struct Media: Equatable, Sendable {
        var output: String
        var filePath: String?
        var startLine: Int
        var attachments: [ToolContentMediaAttachment]
        var audio: AudioMessage?
    }

    struct AudioMessage: Equatable, Sendable {
        var text: String
        var attachmentId: String
        var mimeType: String
        var durationSeconds: Double?
        var playbackBehavior: AudioPlaybackBehavior?
        var base64: String?
    }
}

/// Composition owned by OppiCore; input is never hidden in an output leaf.
struct ToolInspection: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var name: String
        var value: JSONValue
        var role: String?
        var language: String?
    }
    var input: [Field]
    var calls: NestedToolCalls?
    var output: [ToolContentDescriptor]
    var raw: String
    var previewOnly: Bool
    var totalBytes: Int?
    /// Resolved semantics for the painter, not tool identity.
    var terminalOutput: Bool
    var commandText: String? { input.first { $0.role == "command" }?.value.stringValue }
    var commandLanguageBadge: String? {
        guard terminalOutput,
              let field = input.first(where: { $0.role == "command" }),
              field.language == "shell", let text = field.value.stringValue else { return nil }
        for segment in BashEmbeddedLanguageDetector.detect(text) {
            if case .embeddedCode(let language) = segment.kind { return language.displayName }
        }
        return nil
    }
}

/// Expanded inspection plus copy payloads. `content` is the existing single-leaf
/// adapter for painters that have not migrated to ordered mixed output yet.
struct ToolContentPresentation: Equatable, Sendable {
    var inspection: ToolInspection
    var content: ToolContentDescriptor? { inspection.output.first }
    var copyCommandText: String?
    var copyOutputText: String?
}

import AppIntents
import Foundation
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "StartQuickSessionIntent")

enum QuickSessionIntentError: LocalizedError, Equatable {
    case unsupportedImage
    case emptyImage
    case imageTooLarge
    case agentOnOtherServer

    var errorDescription: String? {
        switch self {
        case .agentOnOtherServer:
            return "The Agent and the workspace are on different servers."
        case .unsupportedImage:
            return "The supplied file is not a supported image."
        case .emptyImage:
            return "The supplied image is empty."
        case .imageTooLarge:
            return "The supplied image exceeds Oppi's image upload limit."
        }
    }
}

/// App Intent that opens Oppi into a new session: in the composer, dictating, or in a
/// Live Voice call, with an optional Agent, workspace, text, and image.
///
/// Every parameter is optional. Left empty, each follows what Quick Session would pick
/// on its own: Message mode, the last-used workspace, and the last-used Agent or Pi.
/// Text and an image start in the composer; in a Live Voice call they are the call's
/// first message.
///
/// Triggered from Spotlight, Siri, the Shortcuts app, and the Action Button set to a
/// Shortcut. The Action Button's controls use `QuickSessionOpenIntent`.
struct StartQuickSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    // periphery:ignore
    static let description: IntentDescription = "Start a new Pi session in Oppi: type, dictate, or talk to an Agent in a Live Voice call."
    static var supportedModes: IntentModes { .foreground(.immediate) }
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$agent) in \(\.$mode) mode") {
            \.$workspace
            \.$text
            \.$image
        }
    }

    @Parameter(title: "Mode", default: .message)
    var mode: QuickSessionMode

    @Parameter(
        title: "Agent",
        description: "Saved Agent to start. Empty: the one Quick Session last used, or Pi."
    )
    var agent: AgentEntity?

    @Parameter(
        title: "Workspace",
        description: "Empty: the Agent's server and the workspace Quick Session last used."
    )
    var workspace: WorkspaceEntity?

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String?

    @Parameter(
        title: "Image",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile?

    init() {}

    init(mode: QuickSessionMode) {
        self.mode = mode
    }

    func perform() async throws -> some IntentResult {
        let start = try await start()
        // The opener waits for App Lock, launch, and the shell, then presents.
        await AppDelegate.opener?.open(.quickSession(start))
        return .result()
    }

    /// The Quick Session start these parameters describe; throws for a bad image or an
    /// Agent and workspace on different servers, before anything opens.
    func start() async throws -> QuickSessionStart {
        QuickSessionStart(
            context: try Self.launchContext(agent: agent, workspace: workspace),
            mode: mode,
            payload: try await QuickSessionIntentPayloadBuilder.initialPayload(
                text: text,
                image: image
            )
        )
    }

    /// Where the chosen Agent and workspace point Quick Session; nil when neither is set.
    static func launchContext(
        agent: AgentEntity?,
        workspace: WorkspaceEntity?
    ) throws -> QuickSessionLaunchContext? {
        if let agent, let workspace, agent.serverId != workspace.serverId {
            throw QuickSessionIntentError.agentOnOtherServer
        }
        guard let serverId = agent?.serverId ?? workspace?.serverId else { return nil }
        return QuickSessionLaunchContext(
            serverId: serverId,
            agentId: agent?.agentId,
            workspaceId: workspace?.workspaceId
        )
    }
}

private enum QuickSessionIntentPayloadBuilder {
    static func initialPayload(
        text: String?,
        image: IntentFile?
    ) async throws -> QuickSessionInitialPayload? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        var attachments: [QuickSessionInitialPayload.Attachment] = []

        if let image {
            attachments.append(try await attachment(from: image))
        }

        guard trimmedText?.isEmpty == false || !attachments.isEmpty else {
            return nil
        }

        return QuickSessionInitialPayload(
            text: trimmedText?.isEmpty == false ? trimmedText : nil,
            attachments: attachments
        )
    }

    private static func attachment(
        from file: IntentFile
    ) async throws -> QuickSessionInitialPayload.Attachment {
        guard let contentType = preferredImageType(for: file) else {
            logger.warning("Shortcut supplied a file without an image representation")
            throw QuickSessionIntentError.unsupportedImage
        }

        let data: Data
        do {
            let representation = try await file.file(contentType: contentType)
            let accessedSecurityScopedResource = representation.fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScopedResource {
                    representation.fileURL.stopAccessingSecurityScopedResource()
                }
            }
            data = try readImageData(at: representation.fileURL)
        } catch {
            logger.error("Failed to load Shortcut image: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard !data.isEmpty else {
            logger.warning("Shortcut supplied an empty image file")
            throw QuickSessionIntentError.emptyImage
        }

        return QuickSessionInitialPayload.Attachment(
            name: filename(for: file, contentType: contentType),
            data: data,
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private static func readImageData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while data.count <= PendingImage.autoResizeMaxDataBytes {
            let remaining = PendingImage.autoResizeMaxDataBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1_024)),
                  !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
        }

        throw QuickSessionIntentError.imageTooLarge
    }

    private static func preferredImageType(for file: IntentFile) -> UTType? {
        if let type = file.type, type.conforms(to: .image) {
            return type
        }

        let fileExtension = URL(fileURLWithPath: file.filename).pathExtension
        if let filenameType = UTType(filenameExtension: fileExtension),
           filenameType.conforms(to: .image),
           file.availableContentTypes.contains(where: { $0 == filenameType }) {
            return filenameType
        }

        return file.availableContentTypes.first(where: { $0.conforms(to: .image) })
    }

    private static func filename(for file: IntentFile, contentType: UTType) -> String {
        let trimmed = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = trimmed.isEmpty ? "Shortcut Image" : URL(fileURLWithPath: trimmed).lastPathComponent
        let originalExtension = URL(fileURLWithPath: originalName).pathExtension

        if let originalType = UTType(filenameExtension: originalExtension),
           originalType.conforms(to: .image) {
            let matchesContentType = originalType == contentType
                || originalType.conforms(to: contentType)
                || contentType.conforms(to: originalType)
            if matchesContentType {
                return originalName
            }
        }

        let stem = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        guard let pathExtension = contentType.preferredFilenameExtension else {
            return stem
        }
        return "\(stem).\(pathExtension)"
    }
}

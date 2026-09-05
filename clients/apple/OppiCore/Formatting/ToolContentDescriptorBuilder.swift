import Foundation

/// Builds a UIKit/AppKit/SwiftUI-free `ToolContentDescriptor` from tool args,
/// details, and output. Language, file type, presentationFormat, attachment
/// identity, and copy text are resolved here so Mac cannot infer them again.
enum ToolContentDescriptorBuilder {
    private static let extensionStructuredParseBudgetBytes = 64 * 1024

    struct Context: Sendable {
        var args: [String: JSONValue]?
        var details: JSONValue?
        var fullOutput: String
        var isLoadingOutput: Bool

        init(
            args: [String: JSONValue]? = nil,
            details: JSONValue? = nil,
            fullOutput: String = "",
            isLoadingOutput: Bool = false
        ) {
            self.args = args
            self.details = details
            self.fullOutput = fullOutput
            self.isLoadingOutput = isLoadingOutput
        }
    }

    struct FileMetadata: Equatable, Sendable {
        let filePath: String?
        let fileType: FileType?
        let language: SyntaxLanguage?
    }

    struct AudioPresentation: Equatable, Sendable {
        let text: String?
        let playbackBehavior: AudioPlaybackBehavior?
        let audio: AudioAttachment?
    }

    struct AudioAttachment: Equatable, Sendable {
        let id: String?
        let mimeType: String
        let base64: String?
        let fileName: String?
        let path: String?
        let storageKey: String?
        let sizeBytes: Int?
        let durationSeconds: Double?
    }

    struct ImageAttachment: Equatable, Sendable {
        let id: String?
        let mimeType: String
        let base64: String?
        let fileName: String?
        let path: String?
        let sizeBytes: Int?
        let sha256: String?
        let width: Int?
        let height: Int?
    }

    static func build(
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        context: Context
    ) -> ToolContentPresentation {
        let normalizedTool = ToolCallFormatting.normalized(tool)
        let output = context.fullOutput.isEmpty ? outputPreview : context.fullOutput
        let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileMetadata = fileMetadata(args: context.args, argsSummary: argsSummary)
        let mediaAttachments = mediaAttachments(from: context.details)
        var copyOutput: String? = outputTrimmed.isEmpty ? nil : outputTrimmed
        var copyCommand: String?
        var content: ToolContentDescriptor?

        switch normalizedTool {
        case "ask":
            break

        case "bash":
            let command = ToolCallFormatting.bashCommandFull(args: context.args, argsSummary: argsSummary)
            copyCommand = command.isEmpty ? nil : command
            content = .terminal(
                ToolContentDescriptor.Terminal(
                    command: command.isEmpty ? nil : command,
                    output: outputTrimmed.isEmpty ? nil : outputTrimmed,
                    unwrapped: true,
                    language: nil
                )
            )

        case "read":
            if !outputTrimmed.isEmpty || !mediaAttachments.isEmpty {
                let startLine = ToolCallFormatting.readStartLine(from: context.args)
                content = fileDescriptor(
                    text: outputTrimmed,
                    metadata: fileMetadata,
                    startLine: startLine,
                    attachments: mediaAttachments
                )
            } else if context.isLoadingOutput {
                content = .status(message: "Loading read output…")
            }

        case "write":
            let writeContent = ToolCallFormatting.writeContent(from: context.args)
            if let writeContent, !writeContent.isEmpty {
                copyOutput = writeContent
                content = fileDescriptor(
                    text: writeContent,
                    metadata: fileMetadata,
                    startLine: 1,
                    attachments: []
                )
            } else if !outputTrimmed.isEmpty {
                content = isDone
                    ? .code(
                        ToolContentDescriptor.Code(
                            text: outputTrimmed,
                            language: fileMetadata.language,
                            startLine: nil,
                            filePath: fileMetadata.filePath
                        )
                    )
                    : .terminal(
                        ToolContentDescriptor.Terminal(
                            command: nil,
                            output: outputTrimmed,
                            unwrapped: false,
                            language: nil
                        )
                    )
            }

        case "edit":
            if !isError {
                let editText = ToolCallFormatting.editOldAndNewText(from: context.args)
                if isDone {
                    let changes = ToolCallFormatting.editTextChanges(from: context.args)
                    let lines = ToolCallFormatting.editResultDiffLines(from: context.details) ?? changes.flatMap { change in
                        DiffEngine.compute(old: change.oldText, new: change.newText)
                    }
                    if !lines.isEmpty {
                        let diffPath = fileMetadata.filePath
                            ?? ToolCallFormatting.displayFilePath(
                                tool: normalizedTool, args: context.args, argsSummary: argsSummary
                            )
                        content = .diff(ToolContentDescriptor.Diff(lines: lines, path: diffPath))
                        copyOutput = DiffEngine.formatUnified(lines)
                    }
                } else if let editText {
                    let streamingText = streamingEditText(from: editText)
                    if !streamingText.isEmpty {
                        copyOutput = streamingText
                        content = fileDescriptor(
                            text: streamingText,
                            metadata: fileMetadata,
                            startLine: 1,
                            attachments: []
                        )
                    }
                }
            }
            if content == nil, !outputTrimmed.isEmpty {
                content = isDone
                    ? .code(
                        ToolContentDescriptor.Code(
                            text: outputTrimmed,
                            language: fileMetadata.language,
                            startLine: nil,
                            filePath: fileMetadata.filePath
                        )
                    )
                    : .terminal(
                        ToolContentDescriptor.Terminal(
                            command: nil,
                            output: outputTrimmed,
                            unwrapped: false,
                            language: nil
                        )
                    )
            }

        default:
            let audioDetails = audioPresentation(from: context.details)
            let hasStructuredVoiceContent = audioDetails != nil
            let hasStructuredMediaContent = !mediaAttachments.isEmpty
                || imageAttachment(from: context.details) != nil
            if !outputTrimmed.isEmpty || hasStructuredVoiceContent || hasStructuredMediaContent {
                if !isError,
                   let audioDetails,
                   audioDetails.audio == nil {
                    let transcript = audioPresentationTranscript(
                        output: outputTrimmed,
                        details: audioDetails,
                        args: context.args
                    )
                    content = .media(
                        ToolContentDescriptor.Media(
                            output: transcript,
                            filePath: nil,
                            startLine: 1,
                            attachments: [],
                            audio: ToolContentDescriptor.AudioMessage(
                                text: transcript,
                                attachmentId: "",
                                mimeType: "audio/wav",
                                durationSeconds: nil,
                                playbackBehavior: audioDetails.playbackBehavior,
                                base64: nil
                            )
                        )
                    )
                    copyOutput = transcript.isEmpty ? nil : transcript
                } else if !mediaAttachments.isEmpty && audioDetails == nil {
                    content = .media(
                        ToolContentDescriptor.Media(
                            output: outputTrimmed,
                            filePath: tool,
                            startLine: 1,
                            attachments: mediaAttachments,
                            audio: nil
                        )
                    )
                    copyOutput = outputTrimmed.isEmpty ? tool : outputTrimmed
                } else {
                    let resolved = resolveGenericExtensionExpandedContent(
                        output: outputTrimmed,
                        toolName: tool,
                        details: context.details,
                        args: context.args
                    )
                    content = resolved.content
                    copyOutput = resolved.copyOutput
                }
            }
        }

        if content == nil, !isDone, normalizedTool != "ask" {
            content = .status(message: pendingStatusMessage(normalizedTool: normalizedTool))
        }

        return ToolContentPresentation(
            content: content,
            copyCommandText: copyCommand,
            copyOutputText: copyOutput
        )
    }

    static func fileMetadata(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> FileMetadata {
        let filePath = resolvedFilePath(args: args, argsSummary: argsSummary)
        let fileType = filePath.map { FileType.detect(from: $0) }
        return FileMetadata(
            filePath: filePath,
            fileType: fileType,
            language: fileType?.syntaxLanguage
        )
    }

    static func readOutputFileType(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> FileType? {
        guard let filePath = resolvedFilePath(args: args, argsSummary: argsSummary),
              !filePath.isEmpty else {
            return nil
        }
        return FileType.detect(from: filePath)
    }

    static func readOutputLanguage(args: [String: JSONValue]?, argsSummary: String) -> SyntaxLanguage? {
        readOutputFileType(args: args, argsSummary: argsSummary)?.syntaxLanguage
    }

    static func mediaAttachments(from details: JSONValue?) -> [ToolContentMediaAttachment] {
        guard let object = details?.objectValue else { return [] }
        let mediaArray = object["media"]?.arrayValue ?? []
        return mediaArray.compactMap { value in
            guard let media = value.objectValue,
                  let kind = media["kind"]?.stringValue,
                  let id = media["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            let normalizedMimeType = media["mimeType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let mimeType = if let normalizedMimeType, !normalizedMimeType.isEmpty {
                normalizedMimeType
            } else {
                "application/octet-stream"
            }
            return ToolContentMediaAttachment(
                kind: kind,
                id: id,
                mimeType: mimeType,
                fileName: media["fileName"]?.stringValue,
                sizeBytes: media["sizeBytes"]?.numberValue.map(Int.init),
                sha256: media["sha256"]?.stringValue,
                width: media["width"]?.numberValue.map(Int.init),
                height: media["height"]?.numberValue.map(Int.init)
            )
        }
    }

    static func audioPresentation(from details: JSONValue?) -> AudioPresentation? {
        guard let object = details?.objectValue,
              object["kind"]?.stringValue == "audio_presentation" else {
            return nil
        }

        let text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioPresentation(
            text: text?.isEmpty == false ? text : nil,
            playbackBehavior: audioPlaybackBehavior(from: object),
            audio: audioAttachment(from: details)
        )
    }

    static func imageAttachment(from details: JSONValue?) -> ImageAttachment? {
        guard let object = details?.objectValue,
              let image = object["image"]?.objectValue,
              image["kind"]?.stringValue == "image" else {
            return nil
        }

        let id = image["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id?.isEmpty == false else { return nil }

        let normalizedMimeType = image["mimeType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = (normalizedMimeType?.isEmpty == false ? normalizedMimeType : nil) ?? "image/png"
        return ImageAttachment(
            id: id,
            mimeType: mimeType,
            base64: nil,
            fileName: image["fileName"]?.stringValue,
            path: image["path"]?.stringValue,
            sizeBytes: image["sizeBytes"]?.numberValue.map(Int.init),
            sha256: image["sha256"]?.stringValue,
            width: image["width"]?.numberValue.map(Int.init),
            height: image["height"]?.numberValue.map(Int.init)
        )
    }

    // MARK: - Generic extension parsing

    private static func resolveGenericExtensionExpandedContent(
        output: String,
        toolName: String,
        details: JSONValue?,
        args: [String: JSONValue]? = nil
    ) -> (content: ToolContentDescriptor, copyOutput: String) {
        let audioDetails = audioPresentation(from: details)
        let image = imageAttachment(from: details)
        if audioDetails == nil,
           image == nil,
           let tuiExpandedText = toolTuiRenderExpandedText(from: details) {
            return (
                .terminal(
                    ToolContentDescriptor.Terminal(
                        command: nil,
                        output: tuiExpandedText,
                        unwrapped: false,
                        language: nil
                    )
                ),
                tuiExpandedText
            )
        }

        let fallbackTextOutput: String
        if let expandedText = extensionDetailString(details, keys: ["expandedText"]),
           !expandedText.isEmpty {
            fallbackTextOutput = expandedText
        } else {
            let sanitized = sanitizeGenericExtensionOutput(output, toolName: toolName)
            fallbackTextOutput = sanitized.isEmpty ? output : sanitized
        }
        if let presentation = audioDetails {
            return voiceAudioExpandedContent(presentation: presentation, fallbackText: fallbackTextOutput, args: args)
        }
        if let image {
            return imageExpandedContent(image: image, fallbackText: fallbackTextOutput)
        }

        let textOutput = fallbackTextOutput

        let format = normalizedExtensionPresentationFormat(details)
        let filePathHint = extensionDetailString(details, keys: ["filePath"])
        let languageHint = extensionLanguageHint(details: details, filePathHint: filePathHint)
        let startLineHint = extensionDetailInt(details, keys: ["startLine"])
        let note: (String) -> ToolContentDescriptor = {
            .terminal(
                ToolContentDescriptor.Terminal(
                    command: nil,
                    output: textOutput + "\n\n[render note: \($0)]",
                    unwrapped: false,
                    language: nil
                )
            )
        }

        if format == "terminal" {
            return (
                .terminal(
                    ToolContentDescriptor.Terminal(
                        command: nil,
                        output: textOutput,
                        unwrapped: false,
                        language: nil
                    )
                ),
                ANSIParser.strip(textOutput)
            )
        }

        if format == "json" || (format != "markdown" && textOutput.utf8.count <= extensionStructuredParseBudgetBytes) {
            if textOutput.utf8.count > extensionStructuredParseBudgetBytes {
                let first = textOutput.first(where: { !$0.isWhitespace && !$0.isNewline })
                if format == "json" || first == "{" || first == "[" {
                    return (note("json preview skipped (over 64KB). showing text"), textOutput)
                }
            } else if let data = textOutput.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      json is [String: Any] || json is [Any],
                      JSONSerialization.isValidJSONObject(json),
                      let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                      let pretty = String(data: prettyData, encoding: .utf8) {
                return (
                    .terminal(
                        ToolContentDescriptor.Terminal(
                            command: nil,
                            output: pretty,
                            unwrapped: false,
                            language: .json
                        )
                    ),
                    pretty
                )
            } else if format == "json" {
                return (note("json preview unavailable (invalid object/array). showing text"), textOutput)
            }
        }

        if format == "markdown" {
            return (.markdown(ToolContentDescriptor.Markdown(text: textOutput)), textOutput)
        }

        if format == "code" {
            return (
                .code(
                    ToolContentDescriptor.Code(
                        text: textOutput,
                        language: languageHint,
                        startLine: startLineHint,
                        filePath: filePathHint
                    )
                ),
                textOutput
            )
        }

        if format == "diff" {
            switch genericUnifiedPatchContent(textOutput, filePathHint: filePathHint) {
            case .some(let content):
                return (content, textOutput)
            case .none:
                return (note("diff preview unavailable (invalid unified diff). showing text"), textOutput)
            }
        }

        if let content = genericUnifiedPatchContent(textOutput, filePathHint: filePathHint) {
            return (content, textOutput)
        }

        if looksLikeMarkdownContent(textOutput) {
            return (.markdown(ToolContentDescriptor.Markdown(text: textOutput)), textOutput)
        }

        if let languageHint {
            return (
                .code(
                    ToolContentDescriptor.Code(
                        text: textOutput,
                        language: languageHint,
                        startLine: startLineHint,
                        filePath: filePathHint
                    )
                ),
                textOutput
            )
        }

        return (
            .terminal(
                ToolContentDescriptor.Terminal(
                    command: nil,
                    output: textOutput,
                    unwrapped: false,
                    language: nil
                )
            ),
            textOutput
        )
    }

    // MARK: - Private

    private static func fileDescriptor(
        text: String,
        metadata: FileMetadata,
        startLine: Int,
        attachments: [ToolContentMediaAttachment]
    ) -> ToolContentDescriptor {
        .file(
            ToolContentDescriptor.File(
                text: text,
                filePath: metadata.filePath,
                fileType: metadata.fileType,
                language: metadata.language,
                startLine: startLine,
                attachments: attachments
            )
        )
    }

    private static func streamingEditText(from editText: (oldText: String, newText: String)) -> String {
        if !editText.newText.isEmpty {
            return editText.newText
        }
        return editText.oldText
    }

    private static func audioPresentationTranscript(
        output: String,
        details: AudioPresentation,
        args: [String: JSONValue]?
    ) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitMessage = details.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argText = args?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitMessage.isEmpty {
            return explicitMessage
        }
        if trimmedOutput == "Voice message" {
            return argText
        }
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }
        return argText
    }

    private static func pendingStatusMessage(normalizedTool: String) -> String {
        switch normalizedTool {
        case "read":
            return "Reading…"
        case "write":
            return "Writing…"
        case "edit":
            return "Editing…"
        default:
            return "Waiting for output…"
        }
    }

    private static func resolvedFilePath(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String? {
        ToolCallFormatting.filePath(from: args)
            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            ?? inferredPathFromSummary(argsSummary)
    }

    private static func inferredPathFromSummary(_ argsSummary: String) -> String? {
        let trimmed = argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutToolPrefix: String
        if trimmed.hasPrefix("read ") {
            withoutToolPrefix = String(trimmed.dropFirst(5))
        } else if trimmed.hasPrefix("write ") {
            withoutToolPrefix = String(trimmed.dropFirst(6))
        } else if trimmed.hasPrefix("edit ") {
            withoutToolPrefix = String(trimmed.dropFirst(5))
        } else {
            withoutToolPrefix = trimmed
        }

        let candidate = withoutToolPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let range = candidate.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) {
            return String(candidate[..<range.lowerBound])
        }

        return candidate
    }

    private static func audioPlaybackBehavior(from object: [String: JSONValue]) -> AudioPlaybackBehavior? {
        switch object["playbackBehavior"]?.stringValue {
        case "tapToPlay": return .tapToPlay
        case "playNow": return .playNow
        default: return nil
        }
    }

    private static func audioAttachment(from details: JSONValue?) -> AudioAttachment? {
        guard let object = details?.objectValue,
              let audio = object["audio"]?.objectValue,
              audio["kind"]?.stringValue == "audio" else {
            return nil
        }

        let mimeType = audio["mimeType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? ""
        guard mimeType == "audio/wav" else {
            return AudioAttachment(
                id: audio["id"]?.stringValue,
                mimeType: mimeType.isEmpty ? "audio/unknown" : mimeType,
                base64: nil,
                fileName: audio["fileName"]?.stringValue,
                path: audio["path"]?.stringValue,
                storageKey: audio["storageKey"]?.stringValue,
                sizeBytes: audio["sizeBytes"]?.numberValue.map(Int.init),
                durationSeconds: audio["durationSeconds"]?.numberValue
            )
        }

        let base64 = audio["base64"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioAttachment(
            id: audio["id"]?.stringValue,
            mimeType: mimeType,
            base64: base64?.isEmpty == false ? base64 : nil,
            fileName: audio["fileName"]?.stringValue,
            path: audio["path"]?.stringValue,
            storageKey: audio["storageKey"]?.stringValue,
            sizeBytes: audio["sizeBytes"]?.numberValue.map(Int.init),
            durationSeconds: audio["durationSeconds"]?.numberValue
        )
    }

    private static func voiceAudioExpandedContent(
        presentation: AudioPresentation,
        fallbackText: String,
        args: [String: JSONValue]?
    ) -> (content: ToolContentDescriptor, copyOutput: String) {
        let title = "Voice message"
        let explicitMessage = presentation.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argMessage = args?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackMessage = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputMessage = fallbackMessage == title ? "" : fallbackMessage
        let message = !explicitMessage.isEmpty ? explicitMessage : (!argMessage.isEmpty ? argMessage : outputMessage)

        guard let audio = presentation.audio else {
            let displayText = message.isEmpty ? title : message
            return (
                .media(
                    ToolContentDescriptor.Media(
                        output: displayText,
                        filePath: nil,
                        startLine: 1,
                        attachments: [],
                        audio: ToolContentDescriptor.AudioMessage(
                            text: displayText,
                            attachmentId: "",
                            mimeType: "audio/wav",
                            durationSeconds: nil,
                            playbackBehavior: presentation.playbackBehavior,
                            base64: nil
                        )
                    )
                ),
                displayText
            )
        }

        guard audio.mimeType == "audio/wav" else {
            let displayText = message.isEmpty ? title : message
            return (
                .media(
                    ToolContentDescriptor.Media(
                        output: displayText,
                        filePath: title,
                        startLine: 1,
                        attachments: [],
                        audio: ToolContentDescriptor.AudioMessage(
                            text: displayText,
                            attachmentId: audio.id ?? "",
                            mimeType: audio.mimeType,
                            durationSeconds: audio.durationSeconds,
                            playbackBehavior: presentation.playbackBehavior,
                            base64: nil
                        )
                    )
                ),
                displayText
            )
        }

        if let attachmentId = audio.id, !attachmentId.isEmpty {
            let displayText = message.isEmpty ? title : message
            return (
                .media(
                    ToolContentDescriptor.Media(
                        output: displayText,
                        filePath: nil,
                        startLine: 1,
                        attachments: [],
                        audio: ToolContentDescriptor.AudioMessage(
                            text: displayText,
                            attachmentId: attachmentId,
                            mimeType: audio.mimeType,
                            durationSeconds: audio.durationSeconds,
                            playbackBehavior: presentation.playbackBehavior,
                            base64: nil
                        )
                    )
                ),
                displayText
            )
        }

        guard let base64 = audio.base64, !base64.isEmpty else {
            let displayText = title
            return (
                .terminal(
                    ToolContentDescriptor.Terminal(
                        command: nil,
                        output: displayText,
                        unwrapped: false,
                        language: nil
                    )
                ),
                displayText
            )
        }

        var outputLines: [String] = []
        if !message.isEmpty {
            outputLines.append(message)
        }
        outputLines.append("data:audio/wav;base64,\(base64)")
        let output = outputLines.joined(separator: "\n")
        return (
            .media(
                ToolContentDescriptor.Media(
                    output: output,
                    filePath: title,
                    startLine: 1,
                    attachments: [],
                    audio: nil
                )
            ),
            title
        )
    }

    private static func imageExpandedContent(
        image: ImageAttachment,
        fallbackText: String
    ) -> (content: ToolContentDescriptor, copyOutput: String) {
        let title = image.fileName ?? image.path ?? "image"
        let message = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = image.id, !id.isEmpty {
            let attachment = ToolContentMediaAttachment(
                kind: "image",
                id: id,
                mimeType: safeImageMimeType(image.mimeType),
                fileName: image.fileName,
                sizeBytes: image.sizeBytes,
                sha256: image.sha256,
                width: image.width,
                height: image.height
            )
            return (
                .media(
                    ToolContentDescriptor.Media(
                        output: message,
                        filePath: title,
                        startLine: 1,
                        attachments: [attachment],
                        audio: nil
                    )
                ),
                message.isEmpty ? title : message
            )
        }

        let unavailable = message.isEmpty ? "Image attachment unavailable" : message
        return (
            .media(
                ToolContentDescriptor.Media(
                    output: unavailable,
                    filePath: title,
                    startLine: 1,
                    attachments: [],
                    audio: nil
                )
            ),
            unavailable
        )
    }

    private static func safeImageMimeType(_ mimeType: String) -> String {
        let normalized = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        switch normalized {
        case "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
             "image/bmp", "image/tiff", "image/svg+xml", "image/x-icon",
             "image/vnd.microsoft.icon":
            return normalized
        default:
            return "image/png"
        }
    }

    private static func normalizedExtensionPresentationFormat(_ details: JSONValue?) -> String? {
        extensionDetailString(details, keys: ["presentationFormat"])?.lowercased()
    }

    private static func toolTuiRenderExpandedText(from details: JSONValue?) -> String? {
        guard let object = details?.objectValue,
              let tuiRender = object["tuiRender"]?.objectValue,
              tuiRender["source"]?.stringValue == "renderResult",
              Int(tuiRender["version"]?.numberValue ?? 0) == 1,
              let expandedText = tuiRender["expandedText"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expandedText.isEmpty else {
            return nil
        }
        return expandedText
    }

    private static func extensionDetailString(_ details: JSONValue?, keys: [String]) -> String? {
        guard let object = details?.objectValue else { return nil }
        for key in keys {
            guard let value = object[key] else { continue }
            if let stringValue = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stringValue.isEmpty {
                return stringValue
            }
        }
        return nil
    }

    private static func extensionDetailInt(_ details: JSONValue?, keys: [String]) -> Int? {
        guard let object = details?.objectValue else { return nil }
        for key in keys {
            guard let value = object[key] else { continue }
            if let number = value.numberValue {
                return Int(number)
            }
            if let stringValue = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = Int(stringValue) {
                return parsed
            }
        }
        return nil
    }

    private static func extensionLanguageHint(details: JSONValue?, filePathHint: String?) -> SyntaxLanguage? {
        if let explicit = extensionDetailString(details, keys: ["language"]) {
            let detected = SyntaxLanguage.detect(explicit)
            if detected != .unknown {
                return detected
            }
        }

        if let filePathHint {
            return FileType.detect(from: filePathHint).syntaxLanguage
        }

        return nil
    }

    private static func genericUnifiedPatchContent(_ text: String, filePathHint: String?) -> ToolContentDescriptor? {
        guard let document = UnifiedPatchParser.parse(text, options: .lenient) else {
            return nil
        }
        if document.isMultiFile {
            return .terminal(
                ToolContentDescriptor.Terminal(
                    command: nil,
                    output: text,
                    unwrapped: false,
                    language: nil
                )
            )
        }
        guard let file = document.files.first, !file.lines.isEmpty else {
            return nil
        }
        return .diff(ToolContentDescriptor.Diff(lines: file.lines, path: file.displayPath ?? filePathHint))
    }

    private static func looksLikeMarkdownContent(_ text: String) -> Bool {
        if text.contains("```") {
            return true
        }

        if text.range(of: #"(?m)^#{1,6}\s+\S"#, options: .regularExpression) != nil {
            return true
        }

        if text.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil {
            return true
        }

        if text.range(of: #"(?m)^\|.*\|\s*$"#, options: .regularExpression) != nil,
           text.range(of: #"(?m)^\|\s*:?-{3,}"#, options: .regularExpression) != nil {
            return true
        }

        var listCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                listCount += 1
                if listCount >= 2 {
                    return true
                }
            }
        }

        return false
    }

    private static func sanitizeGenericExtensionOutput(_ output: String, toolName: String) -> String {
        var normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized
            .components(separatedBy: "\n")
            .map { ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : $0 }
            .joined(separator: "\n")
        normalized = stripInvocationEchoBlockIfPresent(normalized, toolName: toolName)
        normalized = normalized.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInvocationEchoBlockIfPresent(_ text: String, toolName: String) -> String {
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tool.isEmpty else { return text }

        let candidates = Set([
            tool,
            tool.split(separator: ".").last.map(String.init),
            tool.split(separator: "/").last.map(String.init),
        ].compactMap { $0 })
        let orderedCandidates = candidates.sorted { $0.count > $1.count }
        let lines = text.components(separatedBy: "\n")
        let isBlank: (String) -> Bool = {
            ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let firstContentIndex = lines.firstIndex(where: { !isBlank($0) }) else { return text }
        let firstLine = ANSIParser.strip(lines[firstContentIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isLikelyInvocationEchoHeader(firstLine, toolCandidates: orderedCandidates) else {
            return text
        }

        var scanIndex = firstContentIndex + 1
        while scanIndex < lines.count {
            if isBlank(lines[scanIndex]) {
                var nextContentIndex = scanIndex + 1
                while nextContentIndex < lines.count, isBlank(lines[nextContentIndex]) {
                    nextContentIndex += 1
                }
                if nextContentIndex < lines.count {
                    return lines[nextContentIndex...].joined(separator: "\n")
                }
            }
            scanIndex += 1
        }

        guard firstContentIndex + 1 < lines.count,
              lines[(firstContentIndex + 1)...].contains(where: { !isBlank($0) }) else {
            return text
        }
        var updated = lines
        updated.remove(at: firstContentIndex)
        return updated.joined(separator: "\n")
    }

    private static func isLikelyInvocationEchoHeader(_ line: String, toolCandidates: [String]) -> Bool {
        for candidate in toolCandidates where line.hasPrefix(candidate) {
            let remainder = line.dropFirst(candidate.count)
            guard let first = remainder.first,
                  first == " " || first == "(" || first == ":" else {
                continue
            }
            if line.contains(":") || line.contains("(") || line.contains("{") || line.contains("[")
                || line.contains("\"") || line.contains("'") || line.contains("`") {
                return true
            }
        }
        return false
    }
}

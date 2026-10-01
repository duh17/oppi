import Foundation

/// Builds a UIKit/AppKit/SwiftUI-free `ToolContentDescriptor` from tool args,
/// details, and output. Language, file type, presentationFormat, attachment
/// identity, and copy text are resolved here so Mac cannot infer them again.
enum ToolContentDescriptorBuilder {
    struct Context: Sendable {
        var args: [String: JSONValue]?
        var details: JSONValue?
        var fullOutput: String
        var isLoadingOutput: Bool
        var inputPresentation: ToolInputPresentation?
        var nestedCalls: NestedToolCalls?
        var previewOnly: Bool
        var totalBytes: Int?
        var display: ToolDisplay?
        var outputPresentation: ToolOutputPresentation?
        var outputAvailability: ToolOutputAvailability?

        init(
            args: [String: JSONValue]? = nil,
            details: JSONValue? = nil,
            fullOutput: String = "",
            isLoadingOutput: Bool = false,
            inputPresentation: ToolInputPresentation? = nil,
            nestedCalls: NestedToolCalls? = nil,
            previewOnly: Bool = false,
            totalBytes: Int? = nil,
            display: ToolDisplay? = nil,
            outputPresentation: ToolOutputPresentation? = nil,
            outputAvailability: ToolOutputAvailability? = nil
        ) {
            self.args = args
            self.details = details
            self.fullOutput = fullOutput
            self.isLoadingOutput = isLoadingOutput
            self.inputPresentation = inputPresentation
            self.nestedCalls = nestedCalls
            self.previewOnly = previewOnly
            self.totalBytes = totalBytes
            self.display = display
            self.outputPresentation = outputPresentation
            self.outputAvailability = outputAvailability
        }
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

    static func inspect(tool: String, argsSummary: String = "", outputPreview: String = "",
                        isError: Bool = false, isDone: Bool = false, context: Context,
                        includeOutput: Bool = true) -> ToolInspection {
        build(tool: tool, argsSummary: argsSummary, outputPreview: outputPreview,
              isError: isError, isDone: isDone, context: context, includeOutput: includeOutput).inspection
    }

    /// The legacy presentation is a Mac adapter; all translated facts and copy
    /// payloads live in its single inspection value.
    static func build(tool: String, argsSummary: String, outputPreview: String,
                      isError: Bool, isDone: Bool, context: Context,
                      includeOutput: Bool = true) -> ToolContentPresentation {
        let context = BuiltInToolFacts.resolve(tool: tool, context: context)
        var result = buildContent(tool: tool, argsSummary: argsSummary, outputPreview: outputPreview,
                                  isError: isError, isDone: isDone, context: context, includeOutput: includeOutput)
        result.inspection.display = context.display
        result.inspection.title = context.display?.label(fallback: tool) ?? tool
        result.inspection.isInteractive = context.outputPresentation?.isInteractive == true
        if result.inspection.isInteractive {
            result.inspection.interactionSummary = ToolCallFormatting.askCollapsedTitle(args: context.args, details: context.details, argsSummary: argsSummary)
        }
        result.inspection.audioOutput = audioPresentation(from: context.details) != nil
        result.inspection.glyph = glyph(input: context.inputPresentation, output: context.outputPresentation, details: context.details)
        result.inspection.mediaOutput = audioPresentation(from: context.details) != nil
            || imageAttachment(from: context.details) != nil || !mediaAttachments(from: context.details).isEmpty
        result.inspection.availability = context.outputAvailability
        result.inspection.outputPresentation = context.outputPresentation
        return result
    }

    private static func buildContent(
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        context: Context,
        includeOutput: Bool = true
    ) -> ToolContentPresentation {
        let output = context.fullOutput.isEmpty ? outputPreview : context.fullOutput
        let input = (context.args ?? [:]).keys.sorted().compactMap { key -> ToolInspection.Field? in
            guard let value = context.args?[key] else { return nil }
            let fact = context.inputPresentation?.fields[key]
            return .init(name: key, value: value, role: fact?.role, language: fact?.language)
        }
        let command = input.first { $0.role == "command" }?.value.stringValue
        let previewOnly = context.previewOnly || (context.fullOutput.isEmpty && context.outputAvailability?.complete == false)
        let totalBytes = context.totalBytes ?? context.outputAvailability?.totalBytes
        if context.outputPresentation?.kind == "terminal" {
            // Input and output stay separate before execution and through deltas.
            // Preserve whitespace in terminal output and replace-mode tails.
            let terminalText = context.details?.objectValue?["expandedText"]?.stringValue.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            } ?? output
            let leaf = ToolContentDescriptor.terminal(.init(output: terminalText.isEmpty ? nil : terminalText, language: nil))
            return ToolContentPresentation(
                inspection: .init(input: input, calls: context.nestedCalls, output: [leaf], raw: output,
                                  previewOnly: previewOnly, totalBytes: totalBytes, terminalOutput: true),
                copyCommandText: command?.isEmpty == false ? command : nil,
                copyOutputText: output.isEmpty ? nil : output
            )
        }
        if let file = ToolFileInspection.resolve(args: context.args, input: context.inputPresentation,
                                                  output: context.outputPresentation, details: context.details,
                                                  text: includeOutput ? output : outputPreview, isDone: isDone, isError: isError) {
            let leaf: ToolContentDescriptor?
            if !includeOutput { leaf = nil }
            else if isError {
                leaf = ToolCallDocumentBuilder.build(args: context.args, inputPresentation: context.inputPresentation,
                    nestedCalls: context.nestedCalls, output: output, rawOutput: output, details: context.details,
                    isDone: isDone, previewOnly: previewOnly, totalBytes: totalBytes).map { .markdown($0) }
            } else if file.operation == .edits, isDone, let lines = file.diff {
                leaf = .diff(.init(lines: lines, path: file.path))
            } else if !file.text.isEmpty || !mediaAttachments(from: context.details).isEmpty {
                leaf = .file(.init(text: file.text, filePath: file.path, fileType: file.fileType,
                                  language: file.fileType?.syntaxLanguage, startLine: file.startLine,
                                  attachments: file.operation == .content ? mediaAttachments(from: context.details) : []))
            } else { leaf = .status(message: context.isLoadingOutput ? "Loading output…" : "Waiting for output…") }
            let copy = if isError { output } else if file.operation == .edits, isDone, let lines = file.diff {
                DiffEngine.formatUnified(lines)
            } else { file.text }
            return .init(inspection: .init(input: input, calls: context.nestedCalls, output: leaf.map { [$0] } ?? [],
                                          raw: output, previewOnly: previewOnly, totalBytes: totalBytes,
                                          terminalOutput: false, file: file,
                                          supplement: { if case .file(let native) = leaf,
                                              native.fileType == .image || native.fileType == .audio || native.fileType == .video {
                                              return ToolCallDocumentBuilder.supplement(args: context.args, inputPresentation: context.inputPresentation, nestedCalls: context.nestedCalls)
                                          }; return nil }()), copyCommandText: nil,
                         copyOutputText: copy.isEmpty ? nil : copy)
        }
        // Collapsed rows need semantic input and glyph facts, not a JSON/Markdown
        // document rebuilt for every delta. Preserve the existing lazy output path.
        if !includeOutput, audioPresentation(from: context.details) == nil {
            return .init(inspection: .init(input: input, calls: context.nestedCalls, output: [], raw: output,
                                          previewOnly: previewOnly, totalBytes: totalBytes, terminalOutput: false),
                         copyCommandText: nil, copyOutputText: nil)
        }
        let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaAttachments = mediaAttachments(from: context.details)
        var copyOutput: String? = outputTrimmed.isEmpty ? nil : outputTrimmed
        var content: ToolContentDescriptor?

        do {
            let audioDetails = audioPresentation(from: context.details)
            let hasStructuredVoiceContent = audioDetails != nil
            let hasStructuredMediaContent = !mediaAttachments.isEmpty
                || imageAttachment(from: context.details) != nil
            if !hasStructuredVoiceContent && !hasStructuredMediaContent {
                content = ToolCallDocumentBuilder.build(
                    args: context.args, inputPresentation: context.inputPresentation,
                    nestedCalls: context.nestedCalls,
                    output: sanitizeGenericExtensionOutput(output), rawOutput: output,
                    details: context.details, isDone: isDone,
                    previewOnly: previewOnly || (context.fullOutput.isEmpty && !outputPreview.isEmpty),
                    totalBytes: totalBytes,
                    toolName: context.display?.title.isEmpty == false ? tool : nil
                ).map { .markdown($0) }
                copyOutput = output.isEmpty ? nil : output
            } else if !outputTrimmed.isEmpty || hasStructuredVoiceContent || hasStructuredMediaContent {
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
                    let resolved = resolveMediaExpandedContent(
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

        if content == nil, !isDone {
            content = .status(message: "Waiting for output…")
        }

        return ToolContentPresentation(
            inspection: .init(input: input, calls: context.nestedCalls, output: content.map { [$0] } ?? [],
                              raw: output, previewOnly: previewOnly, totalBytes: totalBytes, terminalOutput: false,
                              supplement: { if case .media = content {
                                  return ToolCallDocumentBuilder.supplement(args: context.args, inputPresentation: context.inputPresentation, nestedCalls: context.nestedCalls)
                              }; return nil }()),
            copyCommandText: nil,
            copyOutputText: copyOutput
        )
    }

    /// Shared fact-to-glyph translation. A raw name/summary never chooses a glyph.
    static func glyph(input: ToolInputPresentation?, output: ToolOutputPresentation?, details: JSONValue?) -> String? {
        if output?.isInteractive == true { return "questionmark" }
        if audioPresentation(from: details) != nil { return "speaker.wave.2.fill" }
        if imageAttachment(from: details) != nil || !mediaAttachments(from: details).isEmpty { return "photo" }
        switch output?.kind {
        case "terminal": return "dollarsign"
        case "diffOfEdits": return "arrow.left.arrow.right"
        case "fileContent":
            return input?.fields.values.contains { $0.role == "fileContent" } == true ? "pencil" : "magnifyingglass"
        default: return nil
        }
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

    private static func resolveMediaExpandedContent(
        output: String,
        toolName: String,
        details: JSONValue?,
        args: [String: JSONValue]? = nil
    ) -> (content: ToolContentDescriptor, copyOutput: String) {
        let audioDetails = audioPresentation(from: details)
        let image = imageAttachment(from: details)
        let fallbackTextOutput: String
        if let expandedText = extensionDetailString(details, keys: ["expandedText"]),
           !expandedText.isEmpty {
            fallbackTextOutput = expandedText
        } else {
            let sanitized = sanitizeGenericExtensionOutput(output)
            fallbackTextOutput = sanitized.isEmpty ? output : sanitized
        }
        if let presentation = audioDetails {
            return voiceAudioExpandedContent(presentation: presentation, fallbackText: fallbackTextOutput, args: args)
        }
        if let image {
            return imageExpandedContent(image: image, fallbackText: fallbackTextOutput)
        }

        return (.terminal(.init(output: fallbackTextOutput, language: nil)), fallbackTextOutput)
    }

    // MARK: - Private

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
                        output: displayText,
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
             "image/vnd.microsoft.icon", "image/heic", "image/heif":
            return normalized
        default:
            return "image/png"
        }
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

    static func looksLikeMarkdownContent(_ text: String) -> Bool {
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

    private static func sanitizeGenericExtensionOutput(_ output: String) -> String {
        var normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized
            .components(separatedBy: "\n")
            .map { ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : $0 }
            .joined(separator: "\n")
        normalized = normalized.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

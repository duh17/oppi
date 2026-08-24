import Foundation
import SwiftUI

// MARK: - Async Audio Blob

/// Async audio decoder + inline playback row for data URI audio blocks.
struct AsyncAudioBlob: View {
    let id: String
    let base64: String
    let mimeType: String?

    @Environment(AudioPlayerService.self) private var audioPlayer

    @State private var decodedData: Data?
    @State private var decodeFailed = false

    private var isLoading: Bool {
        audioPlayer.loadingItemID == id
    }

    private var isPlaying: Bool {
        audioPlayer.playingItemID == id
    }

    private var title: String {
        mimeType ?? "audio"
    }

    private var subtitle: String {
        guard let decodedData else { return "Preparing audio…" }
        return ToolCallFormatting.formatBytes(decodedData.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.themePurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            Spacer()

            if decodeFailed {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if decodedData == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    guard let decodedData else { return }
                    audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.themePurple)
                        } else if isPlaying {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                                .foregroundStyle(.themePurple)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.themeBgHighlight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: base64.prefix(32)) {
            decodeFailed = false
            decodedData = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            }.value
            if decodedData == nil {
                decodeFailed = true
            }
        }
    }
}

// MARK: - ToolPresentationBuilder Generic Extension Output Parsing

extension ToolPresentationBuilder {
    private static let extensionStructuredParseBudgetBytes = 64 * 1024

    struct ToolAudioPresentationDetails: Equatable {
        let text: String?
        let playbackBehavior: AudioPlaybackBehavior?
        let audio: ToolAudioAttachmentDetails?
    }

    /// Audio-producing tools may return `tool_end.details.audio` with
    /// `{ kind: "audio", id?, mimeType, storageKey?, fileName?, durationSeconds? }`.
    /// New results replay by fetching the session attachment from the Oppi server;
    /// base64/path are fallback paths.
    struct ToolAudioAttachmentDetails: Equatable {
        let id: String?
        let mimeType: String
        let base64: String?
        let fileName: String?
        let path: String?
        let storageKey: String?
        let sizeBytes: Int?
        let durationSeconds: Double?
    }

    private static func audioPlaybackBehavior(from object: [String: JSONValue]) -> AudioPlaybackBehavior? {
        switch object["playbackBehavior"]?.stringValue {
        case "tapToPlay": return .tapToPlay
        case "playNow": return .playNow
        default: return nil
        }
    }

    struct ToolImageAttachmentDetails: Equatable {
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

    static func resolveGenericExtensionExpandedContent(
        output: String,
        toolName: String,
        details: JSONValue?,
        args: [String: JSONValue]? = nil
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        // Media tools keep their attachment-specific rendering. Text-only extension
        // tools can provide either a server-captured Pi TUI render snapshot or an
        // explicit details.expandedText payload without iOS knowing tool specifics.
        let audioPresentation = toolAudioPresentationDetails(from: details)
        let imageAttachment = toolImageAttachmentDetails(from: details)
        if audioPresentation == nil,
           imageAttachment == nil,
           let tuiExpandedText = toolTuiRenderExpandedText(from: details) {
            return (.text(text: tuiExpandedText, language: nil), tuiExpandedText)
        }

        let fallbackTextOutput: String
        if let expandedText = extensionDetailString(details, keys: ["expandedText"]),
           !expandedText.isEmpty {
            fallbackTextOutput = expandedText
        } else {
            let sanitized = sanitizeGenericExtensionOutput(output, toolName: toolName)
            fallbackTextOutput = sanitized.isEmpty ? output : sanitized
        }
        if let presentation = audioPresentation {
            return voiceAudioExpandedContent(presentation: presentation, fallbackText: fallbackTextOutput, args: args)
        }
        if let image = imageAttachment {
            return imageExpandedContent(image: image, fallbackText: fallbackTextOutput)
        }

        let textOutput = fallbackTextOutput

        let format = normalizedExtensionPresentationFormat(details)
        let filePathHint = extensionDetailString(details, keys: ["filePath"])
        let languageHint = extensionLanguageHint(details: details, filePathHint: filePathHint)
        let startLineHint = extensionDetailInt(details, keys: ["startLine"])
        let note: (String) -> ToolExpandedContent = {
            .text(text: textOutput + "\n\n[render note: \($0)]", language: nil)
        }

        // Terminal output is already semantically formatted by the producer. Do not
        // reinterpret command/result text as JSON, Markdown, or a unified diff.
        if format == "terminal" {
            return (.text(text: textOutput, language: nil), ANSIParser.strip(textOutput))
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
                return (.text(text: pretty, language: .json), pretty)
            } else if format == "json" {
                return (note("json preview unavailable (invalid object/array). showing text"), textOutput)
            }
        }

        if format == "markdown" {
            return (.markdown(text: textOutput), textOutput)
        }

        if format == "code" {
            return (
                .code(text: textOutput, language: languageHint, startLine: startLineHint, filePath: filePathHint),
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
            return (.markdown(text: textOutput), textOutput)
        }

        if let languageHint {
            return (
                .code(text: textOutput, language: languageHint, startLine: startLineHint, filePath: filePathHint),
                textOutput
            )
        }

        return (.text(text: textOutput, language: nil), textOutput)
    }

    static func toolAudioPresentationDetails(from details: JSONValue?) -> ToolAudioPresentationDetails? {
        guard let object = details?.objectValue,
              object["kind"]?.stringValue == "audio_presentation" else {
            return nil
        }

        let text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolAudioPresentationDetails(
            text: text?.isEmpty == false ? text : nil,
            playbackBehavior: audioPlaybackBehavior(from: object),
            audio: toolAudioAttachmentDetails(from: details)
        )
    }

    static func toolAudioAttachmentDetails(from details: JSONValue?) -> ToolAudioAttachmentDetails? {
        guard let object = details?.objectValue,
              let audio = object["audio"]?.objectValue,
              audio["kind"]?.stringValue == "audio" else {
            return nil
        }

        let mimeType = audio["mimeType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? ""
        guard mimeType == "audio/wav" else {
            return ToolAudioAttachmentDetails(
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
        return ToolAudioAttachmentDetails(
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

    static func toolImageAttachmentDetails(from details: JSONValue?) -> ToolImageAttachmentDetails? {
        guard let object = details?.objectValue,
              let image = object["image"]?.objectValue,
              image["kind"]?.stringValue == "image" else {
            return nil
        }

        let id = image["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id?.isEmpty == false else { return nil }

        let normalizedMimeType = image["mimeType"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = (normalizedMimeType?.isEmpty == false ? normalizedMimeType : nil) ?? "image/png"
        return ToolImageAttachmentDetails(
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

    static func mediaAttachmentDetails(from details: JSONValue?) -> [ToolMediaAttachment] {
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
            return ToolMediaAttachment(
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

    private static func voiceAudioExpandedContent(
        presentation: ToolAudioPresentationDetails,
        fallbackText: String,
        args: [String: JSONValue]?
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        let title = "Voice message"
        let explicitMessage = presentation.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argMessage = args?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackMessage = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputMessage = fallbackMessage == title ? "" : fallbackMessage
        let message = !explicitMessage.isEmpty ? explicitMessage : (!argMessage.isEmpty ? argMessage : outputMessage)

        guard let audio = presentation.audio else {
            let displayText = message.isEmpty ? title : message
            return (
                .audioMessage(
                    text: displayText,
                    attachmentId: "",
                    mimeType: "audio/wav",
                    durationSeconds: nil,
                    playbackBehavior: presentation.playbackBehavior
                ),
                displayText
            )
        }

        guard audio.mimeType == "audio/wav" else {
            let message = "Audio unavailable on iOS: unsupported MIME type \(audio.mimeType)"
            return (.readMedia(output: message, filePath: title, startLine: 1, attachments: []), message)
        }

        if let attachmentId = audio.id, !attachmentId.isEmpty {
            let displayText = message.isEmpty ? title : message
            return (
                .audioMessage(
                    text: displayText,
                    attachmentId: attachmentId,
                    mimeType: audio.mimeType,
                    durationSeconds: audio.durationSeconds,
                    playbackBehavior: presentation.playbackBehavior
                ),
                displayText
            )
        }

        guard let base64 = audio.base64, !base64.isEmpty else {
            let displayText = title
            return (.text(text: displayText, language: nil), displayText)
        }

        var outputLines: [String] = []
        if !message.isEmpty {
            outputLines.append(message)
        }
        outputLines.append("data:audio/wav;base64,\(base64)")
        let output = outputLines.joined(separator: "\n")
        return (.readMedia(output: output, filePath: title, startLine: 1, attachments: []), title)
    }

    private static func imageExpandedContent(
        image: ToolImageAttachmentDetails,
        fallbackText: String
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        let title = image.fileName ?? image.path ?? "image"
        let message = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = image.id, !id.isEmpty {
            let attachment = ToolMediaAttachment(
                kind: "image",
                id: id,
                mimeType: MediaMimeType.safeImageMimeType(image.mimeType),
                fileName: image.fileName,
                sizeBytes: image.sizeBytes,
                sha256: image.sha256,
                width: image.width,
                height: image.height
            )
            return (.readMedia(output: message, filePath: title, startLine: 1, attachments: [attachment]), message.isEmpty ? title : message)
        }

        let unavailable = message.isEmpty ? "Image attachment unavailable" : message
        return (.readMedia(output: unavailable, filePath: title, startLine: 1, attachments: []), unavailable)
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remaining = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remaining)
        }
        return String(format: "0:%02d", remaining)
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
            switch FileType.detect(from: filePathHint) {
            case .code(let language):
                return language
            case .json:
                return .json
            case .html:
                return .html
            case .latex: return .latex
            case .orgMode: return .orgMode
            case .mermaid: return .mermaid
            case .graphviz: return .dot
            case .markdown, .image, .audio, .video, .pdf, .binary, .plain:
                return nil
            }
        }

        return nil
    }

    /// Single-file unified patches become a rich diff. Multi-file patches stay
    /// the original unified text so we never flatten several files into one.
    private static func genericUnifiedPatchContent(_ text: String, filePathHint: String?) -> ToolExpandedContent? {
        guard let document = UnifiedPatchParser.parse(text, options: .lenient) else {
            return nil
        }
        if document.isMultiFile {
            return .text(text: text, language: nil)
        }
        guard let file = document.files.first, !file.lines.isEmpty else {
            return nil
        }
        return .diff(lines: file.lines, path: file.displayPath ?? filePathHint)
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

    // Generic extension output sanitizer.
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

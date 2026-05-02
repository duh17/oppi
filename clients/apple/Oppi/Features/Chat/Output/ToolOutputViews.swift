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
        .background(Color.themeBgHighlight)
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

    /// Pi/Yuwp voice tools (`voice_create`, `voice_speak`) may return
    /// `tool_end.details.audio` with `{ kind: "audio", id?, mimeType,
    /// storageKey?, fileName?, durationSeconds? }`. New results replay by fetching
    /// the session attachment from the Oppi server; base64/path are legacy fallbacks.
    struct ToolAudioAttachmentDetails: Equatable {
        let id: String?
        let mimeType: String
        let base64: String?
        let fileName: String?
        let path: String?
        let storageKey: String?
        let sizeBytes: Int?
        let durationSeconds: Double?
        let message: String?
        let delivery: VoiceReplyDelivery?
    }

    struct ToolVoicePresentationDetails: Equatable {
        let message: String?
        let delivery: VoiceReplyDelivery?
    }

    private struct ParsedUnifiedDiff {
        let lines: [DiffLine]
        let path: String?
    }

    static func resolveGenericExtensionExpandedContent(
        output: String,
        toolName: String,
        details: JSONValue?,
        args: [String: JSONValue]? = nil
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        // Server/extension-provided expanded text overrides raw output for display.
        // The extension sets details.expandedText + details.presentationFormat to
        // control how the expanded content appears without iOS knowing tool specifics.
        let textOutput: String
        if let expandedText = extensionDetailString(details, keys: ["expandedText"]),
           !expandedText.isEmpty {
            textOutput = expandedText
        } else {
            let sanitized = sanitizeGenericExtensionOutput(output, toolName: toolName)
            textOutput = sanitized.isEmpty ? output : sanitized
        }
        if let audio = toolAudioAttachmentDetails(from: details) {
            return voiceAudioExpandedContent(audio: audio, fallbackText: textOutput, args: args)
        }

        let format = normalizedExtensionPresentationFormat(details)
        let filePathHint = extensionDetailString(details, keys: ["filePath"])
        let languageHint = extensionLanguageHint(details: details, filePathHint: filePathHint)
        let startLineHint = extensionDetailInt(details, keys: ["startLine"])
        let note: (String) -> ToolExpandedContent = {
            .text(text: textOutput + "\n\n[render note: \($0)]", language: nil)
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
            if textOutput.utf8.count > extensionStructuredParseBudgetBytes {
                return (note("markdown preview skipped (over 64KB). showing text"), textOutput)
            }
            return (.markdown(text: textOutput), textOutput)
        }

        if format == "code" {
            return (
                .code(text: textOutput, language: languageHint, startLine: startLineHint, filePath: filePathHint),
                textOutput
            )
        }

        if format == "diff" {
            if let parsed = parseUnifiedDiff(textOutput) {
                return (.diff(lines: parsed.lines, path: parsed.path ?? filePathHint), textOutput)
            }
            return (note("diff preview unavailable (invalid unified diff). showing text"), textOutput)
        }

        if let parsed = parseUnifiedDiff(textOutput) {
            return (.diff(lines: parsed.lines, path: parsed.path ?? filePathHint), textOutput)
        }

        if looksLikeMarkdownContent(textOutput) {
            if textOutput.utf8.count > extensionStructuredParseBudgetBytes {
                return (note("markdown preview skipped (over 64KB). showing text"), textOutput)
            }
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

    static func toolVoicePresentationDetails(from details: JSONValue?) -> ToolVoicePresentationDetails? {
        guard let object = details?.objectValue,
              object["presentation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "voice" else {
            return nil
        }

        let message = object["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolVoicePresentationDetails(
            message: message?.isEmpty == false ? message : nil,
            delivery: object["delivery"]?.stringValue.flatMap(VoiceReplyDelivery.init(rawValue:))
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
                durationSeconds: audio["durationSeconds"]?.numberValue,
                message: object["message"]?.stringValue,
                delivery: object["delivery"]?.stringValue.flatMap(VoiceReplyDelivery.init(rawValue:))
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
            durationSeconds: audio["durationSeconds"]?.numberValue,
            message: object["message"]?.stringValue,
            delivery: object["delivery"]?.stringValue.flatMap(VoiceReplyDelivery.init(rawValue:))
        )
    }

    private static func voiceAudioExpandedContent(
        audio: ToolAudioAttachmentDetails,
        fallbackText: String,
        args: [String: JSONValue]?
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        let title = "Voice message"
        let explicitMessage = audio.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argMessage = args?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackMessage = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputMessage = fallbackMessage == title ? "" : fallbackMessage
        let message = !explicitMessage.isEmpty ? explicitMessage : (!argMessage.isEmpty ? argMessage : outputMessage)

        guard audio.mimeType == "audio/wav" else {
            let message = "Audio unavailable on iOS: unsupported MIME type \(audio.mimeType)"
            return (.readMedia(output: message, filePath: title, startLine: 1), message)
        }

        if let attachmentId = audio.id, !attachmentId.isEmpty {
            let displayText = message.isEmpty ? title : message
            return (
                .voiceMessage(
                    text: displayText,
                    attachmentId: attachmentId,
                    mimeType: audio.mimeType,
                    durationSeconds: audio.durationSeconds,
                    delivery: audio.delivery
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
        return (.readMedia(output: output, filePath: title, startLine: 1), title)
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

    private static func parseUnifiedDiff(_ text: String) -> ParsedUnifiedDiff? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var parsedLines: [DiffLine] = []
        parsedLines.reserveCapacity(lines.count)

        var sawStructuredHeader = false
        var added = 0
        var removed = 0
        var path: String?

        for line in lines {
            if line.hasPrefix("--- ") {
                sawStructuredHeader = true
                if path == nil {
                    path = parseDiffPath(line, prefix: "--- ")
                }
                continue
            }

            if line.hasPrefix("+++ ") {
                sawStructuredHeader = true
                path = parseDiffPath(line, prefix: "+++ ") ?? path
                continue
            }

            if line.hasPrefix("@@") {
                sawStructuredHeader = true
                continue
            }

            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                parsedLines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
                added += 1
                continue
            }

            if line.hasPrefix("-"), !line.hasPrefix("---") {
                parsedLines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
                removed += 1
                continue
            }

            if line.hasPrefix(" ") {
                parsedLines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
            }
        }

        guard !parsedLines.isEmpty else { return nil }
        guard sawStructuredHeader || (added > 0 && removed > 0) else { return nil }

        return ParsedUnifiedDiff(lines: parsedLines, path: path)
    }

    private static func parseDiffPath(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var candidate = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)

        if let tabIndex = candidate.firstIndex(of: "\t") {
            candidate = String(candidate[..<tabIndex])
        }

        if candidate == "/dev/null" || candidate.isEmpty {
            return nil
        }

        if candidate.hasPrefix("a/") || candidate.hasPrefix("b/") {
            candidate.removeFirst(2)
        }

        return candidate
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

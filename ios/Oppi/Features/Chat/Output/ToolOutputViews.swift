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

// MARK: - Async Diff View

/// Computes LCS diff off main thread, then renders.
struct AsyncDiffView: View {
    let oldText: String
    let newText: String
    let filePath: String?
    var showHeader: Bool = true
    var precomputedLines: [DiffLine]? = nil

    @State private var ready = false

    var body: some View {
        if ready {
            DiffContentView(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                showHeader: showHeader,
                precomputedLines: precomputedLines
            )
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(precomputedLines == nil ? "Computing diff…" : "Loading diff…")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .padding(8)
            .task {
                if precomputedLines == nil {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                ready = true
            }
        }
    }
}

// MARK: - ToolPresentationBuilder Generic Extension Output Parsing

extension ToolPresentationBuilder {
    private static let extensionStructuredParseBudgetBytes = 64 * 1024

    private struct ParsedUnifiedDiff {
        let lines: [DiffLine]
        let path: String?
    }

    static func resolveGenericExtensionExpandedContent(
        output: String,
        toolName: String,
        details: JSONValue?
    ) -> (content: ToolExpandedContent, copyOutput: String) {
        // Server/extension-provided expanded text overrides raw output for display.
        // The extension sets details.expandedText + details.presentationFormat to
        // control how the expanded content appears without iOS knowing tool specifics.
        let textOutput: String
        if let expandedText = extensionDetailString(details, keys: ["expandedText", "expanded_text"]),
           !expandedText.isEmpty {
            textOutput = expandedText
        } else {
            let sanitized = sanitizeGenericExtensionOutput(output, toolName: toolName)
            textOutput = sanitized.isEmpty ? output : sanitized
        }
        let format = normalizedExtensionPresentationFormat(details)
        let filePathHint = extensionDetailString(details, keys: ["filePath", "file_path", "path", "file"])
        let languageHint = extensionLanguageHint(details: details, filePathHint: filePathHint)
        let startLineHint = extensionDetailInt(details, keys: ["startLine", "start_line", "start"])
        let note: (String) -> ToolExpandedContent = {
            .text(text: textOutput + "\n\n[render note: \($0)]", language: nil)
        }

        if let chart = PlotChartSpec.fromToolDetails(details) {
            return (
                .plot(spec: chart.spec, fallbackText: chart.fallbackText ?? (textOutput.isEmpty ? nil : textOutput)),
                textOutput
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

    private static func normalizedExtensionPresentationFormat(_ details: JSONValue?) -> String? {
        guard let raw = extensionDetailString(
            details,
            keys: ["presentationFormat", "presentation_format", "format"]
        )?.lowercased() else {
            return nil
        }

        switch raw {
        case "md": return "markdown"
        case "patch", "unified-diff", "unified_diff": return "diff"
        case "source", "syntax": return "code"
        default: return raw
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
        if let explicit = extensionDetailString(details, keys: ["language", "lang", "syntaxLanguage", "syntax_language"]) {
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
            case .markdown, .image, .audio, .plain:
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

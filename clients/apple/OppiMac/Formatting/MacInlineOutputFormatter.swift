import Foundation

enum MacInlineOutputBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case code(language: String?, text: String)
}

struct MacTerminalOutputModel: Equatable, Sendable {
    static let maxOutputCharacters = 16_000

    let commandText: String?
    let outputText: String
    let isError: Bool
    let wasTruncated: Bool

    init(text: String, isError explicitError: Bool = false) {
        let stripped = Self.strippingANSI(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = stripped.components(separatedBy: .newlines)
        let parsedCommand = lines.first.flatMap(Self.commandText(from:))
        commandText = parsedCommand

        let rawOutput: String
        if parsedCommand != nil {
            rawOutput = lines.dropFirst().joined(separator: "\n")
        } else {
            rawOutput = stripped
        }

        let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.count > Self.maxOutputCharacters {
            let index = trimmedOutput.index(trimmedOutput.startIndex, offsetBy: Self.maxOutputCharacters)
            outputText = String(trimmedOutput[..<index]) + "\n… output truncated for inline preview"
            wasTruncated = true
        } else {
            outputText = trimmedOutput.isEmpty ? "No output" : trimmedOutput
            wasTruncated = false
        }
        isError = explicitError || Self.detectsError(in: outputText)
    }

    var statusTitle: String {
        isError ? "Error output" : "Output"
    }

    static func strippingANSI(from text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func commandText(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["$ ", "> ", "+ "] where trimmed.hasPrefix(prefix) {
            let command = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : command
        }
        return nil
    }

    private static func detectsError(in text: String) -> Bool {
        let lowercased = text.localizedLowercase
        return ["error:", "fatal:", "failed", "failure", "exit code 1", "command exited with code"]
            .contains { lowercased.contains($0) }
    }
}

enum MacMediaOutputKind: Equatable, Sendable {
    case image
    case svg
    case audio
    case video

    var title: String {
        switch self {
        case .image: "Image"
        case .svg: "SVG"
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    var systemImage: String {
        switch self {
        case .image, .svg: "photo"
        case .audio: "waveform"
        case .video: "film"
        }
    }
}

struct MacMediaOutputItem: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: MacMediaOutputKind
    let mimeType: String
    let label: String?
    let data: Data

    var byteCount: Int { data.count }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var displayLabel: String {
        guard let label else { return kind.title }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }
}

struct MacMediaOutputModel: Equatable, Sendable {
    static let maxInlineMediaItems = 4
    static let maxInlineMediaBytes = 2_000_000

    let items: [MacMediaOutputItem]

    init(text: String) {
        items = Self.extractItems(from: MacTerminalOutputModel.strippingANSI(from: text))
    }

    var summary: String {
        let mediaWord = items.count == 1 ? "media item" : "media items"
        return "\(items.count) inline \(mediaWord)"
    }

    static func shouldRender(text: String) -> Bool {
        !MacMediaOutputModel(text: text).items.isEmpty
    }

    private static func extractItems(from text: String) -> [MacMediaOutputItem] {
        let markdownMatches = matches(
            pattern: #"!\[([^\]]*)\]\((data:[^)\s]+)\)"#,
            in: text
        )
        let textNSString = text as NSString
        var seenURIs = Set<String>()
        var items: [MacMediaOutputItem] = []

        for match in markdownMatches {
            guard match.numberOfRanges >= 3 else { continue }
            let label = textNSString.substring(with: match.range(at: 1))
            let uri = textNSString.substring(with: match.range(at: 2))
            appendItem(from: uri, label: label, seenURIs: &seenURIs, items: &items)
        }

        let rawMatches = matches(
            pattern: #"data:(?:image|audio|video)/[A-Za-z0-9.+-]+(?:;[A-Za-z0-9=.+-]+)*;base64,[A-Za-z0-9+/=_-]+"#,
            in: text
        )
        for match in rawMatches {
            let uri = textNSString.substring(with: match.range)
            appendItem(from: uri, label: nil, seenURIs: &seenURIs, items: &items)
        }

        return Array(items.prefix(maxInlineMediaItems))
    }

    private static func appendItem(
        from uri: String,
        label: String?,
        seenURIs: inout Set<String>,
        items: inout [MacMediaOutputItem]
    ) {
        guard items.count < maxInlineMediaItems, seenURIs.insert(uri).inserted else { return }
        guard let item = item(from: uri, label: label, id: items.count) else { return }
        items.append(item)
    }

    private static func item(from uri: String, label: String?, id: Int) -> MacMediaOutputItem? {
        guard uri.hasPrefix("data:"), let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let metadataStart = uri.index(uri.startIndex, offsetBy: 5)
        let metadata = String(uri[metadataStart..<commaIndex]).lowercased()
        guard metadata.contains(";base64") else { return nil }
        let mimeType = metadata.split(separator: ";").first.map(String.init) ?? ""
        let encodedPayload = String(uri[uri.index(after: commaIndex)...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: encodedPayload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              data.count <= maxInlineMediaBytes,
              let kind = kind(for: mimeType) else {
            return nil
        }
        return MacMediaOutputItem(
            id: id,
            kind: kind,
            mimeType: mimeType,
            label: label,
            data: data
        )
    }

    private static func kind(for mimeType: String) -> MacMediaOutputKind? {
        if mimeType == "image/svg+xml" { return .svg }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("video/") { return .video }
        return nil
    }

    private static func matches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range)
    }
}

enum MacDiffLineKind: Equatable, Sendable {
    case fileHeader
    case hunk
    case addition
    case removal
    case context
}

struct MacDiffLine: Equatable, Sendable {
    let kind: MacDiffLineKind
    let text: String
}

struct MacDiffOutputModel: Equatable, Sendable {
    let lines: [MacDiffLine]

    init(text: String) {
        let stripped = MacTerminalOutputModel.strippingANSI(from: text)
        lines = stripped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { line in MacDiffLine(kind: Self.kind(for: line), text: line) }
    }

    var additionCount: Int {
        lines.filter { $0.kind == .addition }.count
    }

    var removalCount: Int {
        lines.filter { $0.kind == .removal }.count
    }

    var changeSummary: String {
        "\(additionCount) \(additionCount == 1 ? "addition" : "additions"), \(removalCount) \(removalCount == 1 ? "removal" : "removals")"
    }

    static func shouldRender(text: String) -> Bool {
        let stripped = MacTerminalOutputModel.strippingANSI(from: text)
        let lines = stripped.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let hasUnifiedMarkers = lines.contains { line in
            line.hasPrefix("diff --git") || line.hasPrefix("@@ ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
        }
        guard hasUnifiedMarkers else { return false }
        return lines.contains { line in
            (line.hasPrefix("+") && !line.hasPrefix("+++")) || (line.hasPrefix("-") && !line.hasPrefix("---"))
        }
    }

    private static func kind(for line: String) -> MacDiffLineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
            return .fileHeader
        }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .removal }
        return .context
    }
}

struct MacCodeLine: Equatable, Sendable {
    let number: Int
    let text: String
}

struct MacCodeOutputModel: Equatable, Sendable {
    let language: String?
    let syntaxLanguage: SyntaxLanguage?
    let text: String
    let lines: [MacCodeLine]

    init(language: String?, text: String) {
        let stripped = MacTerminalOutputModel.strippingANSI(from: text).trimmingCharacters(in: .newlines)
        self.text = stripped
        self.language = language?.isEmpty == false ? language : Self.inferredLanguage(from: stripped)
        if let language = self.language {
            let detected = SyntaxLanguage.detect(language)
            syntaxLanguage = detected == .unknown ? nil : detected
        } else {
            syntaxLanguage = nil
        }
        lines = stripped.components(separatedBy: .newlines).enumerated().map { offset, line in
            MacCodeLine(number: offset + 1, text: line)
        }
    }

    static func shouldRenderStandalone(text: String) -> Bool {
        let stripped = MacTerminalOutputModel.strippingANSI(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.components(separatedBy: .newlines).count >= 3 else { return false }
        return inferredLanguage(from: stripped) != nil
    }

    static func inferredLanguage(from text: String) -> String? {
        let lowercased = text.lowercased()
        if lowercased.contains("import swiftui") || lowercased.contains("struct ") && lowercased.contains(": view") {
            return "swift"
        }
        if lowercased.contains("func ") && lowercased.contains("{") {
            return "swift"
        }
        if lowercased.contains("export ") || lowercased.contains("const ") || lowercased.contains("interface ") {
            return "typescript"
        }
        if lowercased.contains("def ") && lowercased.contains(":") {
            return "python"
        }
        if lowercased.contains("package main") || lowercased.contains("func main()") {
            return "go"
        }
        return nil
    }
}

struct MacInlineOutputFormatter: Sendable {
    static let maxRenderedCharacters = 24_000

    static func blocks(from text: String) -> [MacInlineOutputBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.paragraph("No content")] }

        let limited: String
        let wasTruncated: Bool
        if trimmed.count > maxRenderedCharacters {
            let index = trimmed.index(trimmed.startIndex, offsetBy: maxRenderedCharacters)
            limited = String(trimmed[..<index])
            wasTruncated = true
        } else {
            limited = trimmed
            wasTruncated = false
        }

        var blocks: [MacInlineOutputBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in limited.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
                if inCodeFence {
                    flushCode()
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                    let language = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            guard !trimmedLine.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmedLine) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let bullet = parseBullet(trimmedLine) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }

            paragraphLines.append(trimmedLine)
        }

        if inCodeFence {
            flushCode()
        }
        flushParagraph()

        if wasTruncated {
            blocks.append(.paragraph("Output truncated after \(maxRenderedCharacters.formatted()) characters."))
        }

        return blocks.isEmpty ? [.paragraph("No content")] : blocks
    }

    static func shouldUseTerminalBlock(for text: String) -> Bool {
        if text.contains("```") { return false }
        let stripped = MacTerminalOutputModel.strippingANSI(from: text)
        let lines = stripped.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }
        let shellishPrefixes = ["$ ", "> ", "+ ", "- ", "error:", "warning:", "npm ", "SwiftCompile", "Ld "]
        return lines.prefix(20).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return shellishPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

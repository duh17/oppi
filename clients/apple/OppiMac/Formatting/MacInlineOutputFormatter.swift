import Foundation

struct MacTerminalOutputModel: Equatable, Sendable {
    static let maxOutputCharacters = 16_000

    let commandText: String?
    let outputText: String
    let isError: Bool

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
        } else {
            outputText = trimmedOutput.isEmpty ? "No output" : trimmedOutput
        }
        isError = explicitError || Self.detectsError(in: outputText)
    }

    var statusTitle: String {
        isError ? "Error output" : "Output"
    }

    static func strippingANSI(from text: String) -> String {
        ANSIParser.strip(text)
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

struct MacCodeOutputModel: Equatable, Sendable {
    let language: String?
    let syntaxLanguage: SyntaxLanguage?
    let text: String

    init(language: String?, text: String) {
        let stripped = MacTerminalOutputModel.strippingANSI(from: text).trimmingCharacters(in: .newlines)
        self.text = stripped
        // Language comes from shared descriptors. Do not guess from source text.
        let explicitLanguage = language?.isEmpty == false ? language : nil
        self.language = explicitLanguage
        if let explicitLanguage {
            let detected = SyntaxLanguage.detect(explicitLanguage)
            syntaxLanguage = detected == .unknown ? nil : detected
        } else {
            syntaxLanguage = nil
        }
    }
}

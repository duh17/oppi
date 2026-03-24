import Foundation
import UIKit

@MainActor
final class SelectedTextPiActionRouter {
    private let dispatchClosure: (SelectedTextPiRequest) -> Void

    init(dispatch: @escaping (SelectedTextPiRequest) -> Void) {
        dispatchClosure = dispatch
    }

    func dispatch(_ request: SelectedTextPiRequest) {
        dispatchClosure(request)
    }
}

/// Shim for backward compatibility with tests and call sites that
/// reference the old hardcoded action kinds.  Maps 1:1 to built-in
/// `PiQuickAction` entries via their stable UUIDs.
// periphery:ignore - used by PiQuickActionTests via @testable import
enum SelectedTextPiActionKind: String, CaseIterable, Equatable {
    case explain
    case doIt
    case fix
    case refactor
    case addToPrompt

    /// Convert to the matching built-in `PiQuickAction`.
    var builtInAction: PiQuickAction {
        switch self {
        case .explain: PiQuickAction.builtInDefaults[0]
        case .doIt: PiQuickAction.builtInDefaults[1]
        case .fix: PiQuickAction.builtInDefaults[2]
        case .refactor: PiQuickAction.builtInDefaults[3]
        case .addToPrompt: PiQuickAction.builtInDefaults[4]
        }
    }
}

enum SelectedTextSurfaceKind: Equatable {
    case assistantProse
    case userMessage
    case assistantCodeBlock
    case assistantTable
    case thinking
    case toolCommand
    case toolOutput
    case toolExpandedText
    case fullScreenCode
    case fullScreenDiff
    case fullScreenSource
    case fullScreenTerminal
    case fullScreenMarkdown
    case fullScreenThinking

    var prefersCodeBlockInsertion: Bool {
        switch self {
        case .assistantCodeBlock, .toolCommand, .toolOutput, .toolExpandedText, .fullScreenCode, .fullScreenDiff, .fullScreenSource, .fullScreenTerminal:
            true
        case .assistantProse, .userMessage, .assistantTable, .thinking, .fullScreenMarkdown, .fullScreenThinking:
            false
        }
    }
}

struct SelectedTextSourceContext: Equatable {
    let sessionId: String
    let surface: SelectedTextSurfaceKind
    let sourceLabel: String?
    let filePath: String?
    let lineRange: ClosedRange<Int>?
    let languageHint: String?

    init(
        sessionId: String,
        surface: SelectedTextSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil
    ) {
        self.sessionId = sessionId
        self.surface = surface
        self.sourceLabel = sourceLabel
        self.filePath = filePath
        self.lineRange = lineRange
        self.languageHint = languageHint
    }
}

struct SelectedTextPiRequest: Equatable {
    let action: PiQuickAction
    let selectedText: String
    let source: SelectedTextSourceContext

    /// Convenience initializer for backward compatibility with old enum-based callers.
    init(action: SelectedTextPiActionKind, selectedText: String, source: SelectedTextSourceContext) {
        self.action = action.builtInAction
        self.selectedText = selectedText
        self.source = source
    }

    init(action: PiQuickAction, selectedText: String, source: SelectedTextSourceContext) {
        self.action = action
        self.selectedText = selectedText
        self.source = source
    }
}

enum SelectedTextPiTextViewSupport {
    static func selectedText(in textView: UITextView, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              range.length > 0 else {
            return nil
        }

        let fullText = textView.attributedText?.string ?? textView.text ?? ""
        let nsText = fullText as NSString
        guard NSMaxRange(range) <= nsText.length else {
            return nil
        }

        let selected = nsText.substring(with: range)
        let normalized = SelectedTextPiPromptFormatter.normalizedSelectedText(selected)
        return normalized.isEmpty ? nil : normalized
    }
}

enum SelectedTextPiMenuBuilder {
    @MainActor
    static func editMenu(
        suggestedActions: [UIMenuElement],
        selectedText: String,
        sourceContext: SelectedTextSourceContext,
        router: SelectedTextPiActionRouter,
        actionStore: PiQuickActionStore? = nil
    ) -> UIMenu? {
        guard let piSubmenu = piSubmenu(
            selectedText: selectedText,
            sourceContext: sourceContext,
            router: router,
            actionStore: actionStore
        ) else {
            return nil
        }

        // Keep π first so the system is less likely to bury it under "More"
        // when the edit menu gets crowded.
        return UIMenu(children: [piSubmenu] + suggestedActions)
    }

    @MainActor
    static func piSubmenu(
        selectedText: String,
        sourceContext: SelectedTextSourceContext,
        router: SelectedTextPiActionRouter,
        actionStore: PiQuickActionStore? = nil
    ) -> UIMenu? {
        let normalized = SelectedTextPiPromptFormatter.normalizedSelectedText(selectedText)
        guard !normalized.isEmpty else { return nil }

        let quickActions = actionStore?.actions ?? PiQuickAction.builtInDefaults

        let menuActions = quickActions.map { quickAction in
            UIAction(
                title: quickAction.title,
                image: UIImage(systemName: quickAction.systemImage)
            ) { _ in
                router.dispatch(.init(
                    action: quickAction,
                    selectedText: normalized,
                    source: sourceContext
                ))
            }
        }

        return UIMenu(title: "π", children: menuActions)
    }
}

enum SelectedTextPiEditMenuSupport {
    @MainActor
    static func buildMenu(
        textView: UITextView,
        range: NSRange,
        suggestedActions: [UIMenuElement],
        router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?,
        actionStore: PiQuickActionStore? = nil
    ) -> UIMenu? {
        guard let router,
              let sourceContext,
              let selectedText = SelectedTextPiTextViewSupport.selectedText(in: textView, range: range) else {
            return nil
        }

        return SelectedTextPiMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
            selectedText: selectedText,
            sourceContext: sourceContext,
            router: router,
            actionStore: actionStore
        )
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

private struct SelectedTextPiRouterEnvironmentKey: EnvironmentKey {
    static let defaultValue: SelectedTextPiActionRouter? = nil
}

extension EnvironmentValues {
    /// Pi action router for text selection menus.
    ///
    /// Injected by `FileBrowserContentView` (routes to quick session)
    /// and `ChatTimelineView` (routes to active session composer).
    var selectedTextPiActionRouter: SelectedTextPiActionRouter? {
        get { self[SelectedTextPiRouterEnvironmentKey.self] }
        set { self[SelectedTextPiRouterEnvironmentKey.self] = newValue }
    }
}

private struct PiQuickActionStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: PiQuickActionStore? = nil
}

extension EnvironmentValues {
    /// Store for user-configured π quick actions.
    var piQuickActionStore: PiQuickActionStore? {
        get { self[PiQuickActionStoreEnvironmentKey.self] }
        set { self[PiQuickActionStoreEnvironmentKey.self] = newValue }
    }
}

enum SelectedTextPiPromptFormatter {
    static let maxInsertedCharacters = 12_000

    static func composeDraftAddition(for request: SelectedTextPiRequest) -> String {
        let snippet = formattedSnippet(for: request.selectedText, source: request.source)
        let prefix = request.action.isRawInsert ? nil : nonEmpty(request.action.promptPrefix)

        guard let prefix else {
            return snippet
        }

        return [prefix, sourceMetadataBlock(for: request.source), snippet]
            .compactMap(nonEmpty)
            .joined(separator: "\n\n")
    }

    static func normalizedSelectedText(_ text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formattedSnippet(for selectedText: String, source: SelectedTextSourceContext) -> String {
        let normalized = normalizedSelectedText(selectedText)
        guard !normalized.isEmpty else { return "" }

        let clamped = clampedSelection(normalized)
        if prefersCodeBlockFormatting(for: source) {
            return fencedCodeBlock(clamped.text, languageHint: source.languageHint) + clamped.noticeSuffix
        }
        return quotedBlock(clamped.text) + clamped.noticeSuffix
    }

    private static func prefersCodeBlockFormatting(for source: SelectedTextSourceContext) -> Bool {
        source.surface.prefersCodeBlockInsertion || source.languageHint != nil
    }

    private static func sourceMetadataBlock(for source: SelectedTextSourceContext) -> String? {
        var lines: [String] = []

        if let filePath = source.filePath, !filePath.isEmpty {
            lines.append("File: \(filePath)")
        } else if let sourceLabel = nonEmpty(source.sourceLabel), source.surface != .assistantProse {
            lines.append("Source: \(sourceLabel)")
        }

        if let lineRange = source.lineRange {
            lines.append("Lines: \(lineRange.lowerBound)-\(lineRange.upperBound)")
        }

        if let languageHint = nonEmpty(source.languageHint), prefersCodeBlockFormatting(for: source) {
            lines.append("Language: \(languageHint)")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func quotedBlock(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let content = String(line)
                return content.isEmpty ? ">" : "> \(content)"
            }
            .joined(separator: "\n")
    }

    private static func fencedCodeBlock(_ text: String, languageHint: String?) -> String {
        let fenceLength = max(3, longestBacktickRun(in: text) + 1)
        let fence = String(repeating: "`", count: fenceLength)
        let language = nonEmpty(languageHint) ?? ""
        if language.isEmpty {
            return "\(fence)\n\(text)\n\(fence)"
        }
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func clampedSelection(_ text: String) -> (text: String, noticeSuffix: String) {
        guard text.count > maxInsertedCharacters else {
            return (text, "")
        }

        let prefix = String(text.prefix(maxInsertedCharacters))
        return (
            prefix,
            "\n\n[selection truncated from \(text.count) characters]"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

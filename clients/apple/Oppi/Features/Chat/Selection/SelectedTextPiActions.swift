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

struct SelectedTextActionContext {
    let dispatcher: SelectedTextPiActionRouter
    let sessionId: String
    let sourceLabel: String?
    let filePath: String?
    let languageHint: String?
    let timelineItemId: String?
    let sourceSurfaceOverride: SelectedTextSurfaceKind?

    init(
        dispatcher: SelectedTextPiActionRouter,
        sessionId: String,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: SelectedTextSurfaceKind? = nil
    ) {
        self.dispatcher = dispatcher
        self.sessionId = sessionId
        self.sourceLabel = sourceLabel
        self.filePath = filePath
        self.languageHint = languageHint
        self.timelineItemId = timelineItemId
        self.sourceSurfaceOverride = sourceSurfaceOverride
    }

    init?(
        router: SelectedTextPiActionRouter?,
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: SelectedTextSurfaceKind? = nil
    ) {
        guard let router else { return nil }
        self.init(
            dispatcher: router,
            sessionId: sessionId ?? "",
            sourceLabel: sourceLabel,
            filePath: filePath,
            languageHint: languageHint,
            timelineItemId: timelineItemId,
            sourceSurfaceOverride: sourceSurfaceOverride
        )
    }

    func sourceContext(
        surface: SelectedTextSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) -> SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: sessionId,
            surface: sourceSurfaceOverride ?? surface,
            sourceLabel: sourceLabel ?? self.sourceLabel,
            filePath: filePath ?? self.filePath,
            lineRange: lineRange,
            languageHint: languageHint ?? self.languageHint,
            timelineItemId: timelineItemId ?? self.timelineItemId
        )
    }

    func overriding(
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: SelectedTextSurfaceKind? = nil
    ) -> SelectedTextActionContext {
        SelectedTextActionContext(
            dispatcher: dispatcher,
            sessionId: sessionId ?? self.sessionId,
            sourceLabel: sourceLabel ?? self.sourceLabel,
            filePath: filePath ?? self.filePath,
            languageHint: languageHint ?? self.languageHint,
            timelineItemId: timelineItemId ?? self.timelineItemId,
            sourceSurfaceOverride: sourceSurfaceOverride ?? self.sourceSurfaceOverride
        )
    }
}

extension SelectedTextActionScope {
    func makeActionContext(
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: SelectedTextSurfaceKind? = nil
    ) -> SelectedTextActionContext? {
        SelectedTextActionContext(
            router: router,
            sessionId: sessionId,
            sourceLabel: sourceLabel,
            filePath: filePath,
            languageHint: languageHint,
            timelineItemId: timelineItemId,
            sourceSurfaceOverride: sourceSurfaceOverride
        )
    }
}

struct SelectedTextSourceContext: Equatable {
    let sessionId: String
    let surface: SelectedTextSurfaceKind
    let sourceLabel: String?
    let filePath: String?
    let lineRange: ClosedRange<Int>?
    let languageHint: String?
    let timelineItemId: String?

    init(
        sessionId: String,
        surface: SelectedTextSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) {
        self.sessionId = sessionId
        self.surface = surface
        self.sourceLabel = sourceLabel
        self.filePath = filePath
        self.lineRange = lineRange
        self.languageHint = languageHint
        self.timelineItemId = timelineItemId
    }

    func withLineRange(_ range: ClosedRange<Int>?) -> SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: sessionId,
            surface: surface,
            sourceLabel: sourceLabel,
            filePath: filePath,
            lineRange: range ?? lineRange,
            languageHint: languageHint,
            timelineItemId: timelineItemId
        )
    }
}

struct SelectedTextPiRequest: Equatable {
    let action: PiQuickAction
    let selectedText: String
    let source: SelectedTextSourceContext

    init(action: PiQuickAction, selectedText: String, source: SelectedTextSourceContext) {
        self.action = action
        self.selectedText = selectedText
        self.source = source
    }
}

enum SelectedTextPiTextViewSupport {
    @MainActor
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
        guard let commentAction = commentAction(
            selectedText: selectedText,
            sourceContext: sourceContext,
            router: router
        ) else {
            return nil
        }

        // Keep Comment first so the system is less likely to bury it under
        // "More" when the edit menu gets crowded.
        return UIMenu(children: [commentAction] + suggestedActions)
    }

    @MainActor
    static func commentAction(
        selectedText: String,
        sourceContext: SelectedTextSourceContext,
        router: SelectedTextPiActionRouter
    ) -> UIAction? {
        let normalized = SelectedTextPiPromptFormatter.normalizedSelectedText(selectedText)
        guard !normalized.isEmpty else { return nil }

        let quickAction = PiQuickAction.reviewCommentAction
        return UIAction(
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
            sourceContext: enrichedSourceContext(sourceContext, textView: textView, range: range),
            router: router,
            actionStore: actionStore
        )
    }

    private static func enrichedSourceContext(
        _ sourceContext: SelectedTextSourceContext,
        textView: UITextView,
        range: NSRange
    ) -> SelectedTextSourceContext {
        guard sourceContext.lineRange == nil else { return sourceContext }

        if let attributedRange = attributedLineRange(in: textView, range: range) {
            return sourceContext.withLineRange(attributedRange)
        }

        return sourceContext.withLineRange(textLineRange(in: textView.attributedText?.string ?? textView.text ?? "", range: range))
    }

    private static func attributedLineRange(in textView: UITextView, range: NSRange) -> ClosedRange<Int>? {
        guard let attributedText = textView.attributedText,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= attributedText.length else {
            return nil
        }

        let start = max(0, range.location)
        let end = max(start, NSMaxRange(range) - 1)
        var numbers: [Int] = []
        attributedText.enumerateAttribute(reviewLineNumberAttributeKey, in: NSRange(location: start, length: end - start + 1)) { value, _, _ in
            if let number = value as? Int {
                numbers.append(number)
            }
        }
        guard let min = numbers.min(), let max = numbers.max() else { return nil }
        return min...max
    }

    private static func textLineRange(in text: String, range: NSRange) -> ClosedRange<Int>? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return nil }

        let before = nsText.substring(to: range.location)
        let selected = nsText.substring(with: range)
        let startLine = before.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        let additionalLines = selected.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
        return startLine...max(startLine, startLine + additionalLines)
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

enum SelectedTextActionScope {
    case activeSession(SelectedTextPiActionRouter)
    case quickSession(SelectedTextPiActionRouter)

    var router: SelectedTextPiActionRouter {
        switch self {
        case .activeSession(let router), .quickSession(let router):
            return router
        }
    }
}

private struct SelectedTextActionScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue: SelectedTextActionScope? = nil
}

extension EnvironmentValues {
    /// Routing scope for selected-text actions.
    ///
    /// Boundary views must inject a scope explicitly. Shared file/diff viewers
    /// consume it but do not manufacture their own fallback routing.
    var selectedTextActionScope: SelectedTextActionScope? {
        get { self[SelectedTextActionScopeEnvironmentKey.self] }
        set { self[SelectedTextActionScopeEnvironmentKey.self] = newValue }
    }

    /// Convenience read-only access to the scoped router.
    var selectedTextPiActionRouter: SelectedTextPiActionRouter? {
        selectedTextActionScope?.router
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

enum SelectedTextPiRoute: Equatable {
    case currentSessionDraft(String)
    case quickSessionDraft(String)
    case reviewComment(SelectedTextPiRequest)
}

enum SelectedTextPiRoutingContext: Equatable {
    case activeChat
    case nonChat
}

enum SelectedTextPiRouterPolicy {
    static func route(
        request: SelectedTextPiRequest,
        context: SelectedTextPiRoutingContext
    ) -> SelectedTextPiRoute? {
        switch request.action.behavior {
        case .reviewComment:
            switch context {
            case .activeChat:
                return .reviewComment(request)
            case .nonChat:
                let addition = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
                return addition.isEmpty ? nil : .quickSessionDraft(addition)
            }
        case .newSession:
            let addition = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            return addition.isEmpty ? nil : .quickSessionDraft(addition)
        case .currentSession:
            let addition = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            guard !addition.isEmpty else { return nil }
            switch context {
            case .activeChat:
                return .currentSessionDraft(addition)
            case .nonChat:
                return .quickSessionDraft(addition)
            }
        }
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

import Foundation
import SwiftUI
import UIKit

@MainActor
final class ReviewCommentSelectionRouter {
    typealias InlineSaveHandler = (String, ReviewCommentSelectionRequest) async -> Bool

    private let dispatchClosure: (ReviewCommentSelectionRequest, UIViewController?) -> Void
    private let inlineSaveClosure: InlineSaveHandler?
    let inlineQuickComments: [QuickCommentTemplate]
    let voiceInputManager: VoiceInputManager?

    var supportsInlineCommentComposer: Bool {
        inlineSaveClosure != nil
    }

    init(
        dispatch: @escaping (ReviewCommentSelectionRequest) -> Void,
        inlineSave: InlineSaveHandler? = nil,
        inlineQuickComments: [QuickCommentTemplate] = [],
        voiceInputManager: VoiceInputManager? = nil
    ) {
        dispatchClosure = { request, _ in dispatch(request) }
        inlineSaveClosure = inlineSave
        self.inlineQuickComments = inlineQuickComments
        self.voiceInputManager = voiceInputManager
    }

    init(
        dispatchWithPresentation: @escaping (ReviewCommentSelectionRequest, UIViewController?) -> Void,
        inlineSave: InlineSaveHandler? = nil,
        inlineQuickComments: [QuickCommentTemplate] = [],
        voiceInputManager: VoiceInputManager? = nil
    ) {
        dispatchClosure = dispatchWithPresentation
        inlineSaveClosure = inlineSave
        self.inlineQuickComments = inlineQuickComments
        self.voiceInputManager = voiceInputManager
    }

    func dispatch(_ request: ReviewCommentSelectionRequest) {
        dispatchClosure(request, nil)
    }

    func dispatch(_ request: ReviewCommentSelectionRequest, presentingViewController: UIViewController?) {
        dispatchClosure(request, presentingViewController)
    }

    func saveInlineComment(body: String, request: ReviewCommentSelectionRequest) async -> Bool {
        guard let inlineSaveClosure else { return false }
        return await inlineSaveClosure(body, request)
    }

    func retargetingDispatch(_ dispatch: @escaping (ReviewCommentSelectionRequest) -> Void) -> ReviewCommentSelectionRouter {
        let inlineSave: InlineSaveHandler? = supportsInlineCommentComposer ? { body, request in
            await self.saveInlineComment(body: body, request: request)
        } : nil
        return ReviewCommentSelectionRouter(
            dispatch: dispatch,
            inlineSave: inlineSave,
            inlineQuickComments: inlineQuickComments,
            voiceInputManager: voiceInputManager
        )
    }
}

enum ReviewCommentSurfaceKind: Equatable {
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

    var usesInlineCommentWidget: Bool {
        switch self {
        case .toolExpandedText, .fullScreenCode, .fullScreenDiff, .fullScreenSource, .fullScreenTerminal, .fullScreenMarkdown, .fullScreenThinking:
            true
        case .assistantProse, .userMessage, .assistantCodeBlock, .assistantTable, .thinking, .toolCommand, .toolOutput:
            false
        }
    }
}

struct ReviewCommentSelectionContext {
    let dispatcher: ReviewCommentSelectionRouter
    let sessionId: String
    let sourceLabel: String?
    let filePath: String?
    let languageHint: String?
    let timelineItemId: String?
    let sourceSurfaceOverride: ReviewCommentSurfaceKind?

    init(
        dispatcher: ReviewCommentSelectionRouter,
        sessionId: String,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: ReviewCommentSurfaceKind? = nil
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
        router: ReviewCommentSelectionRouter?,
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: ReviewCommentSurfaceKind? = nil
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
        surface: ReviewCommentSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) -> ReviewCommentSourceContext {
        makeSourceContext(
            surface: sourceSurfaceOverride ?? surface,
            sourceLabel: sourceLabel,
            filePath: filePath,
            lineRange: lineRange,
            languageHint: languageHint,
            timelineItemId: timelineItemId
        )
    }

    func sourceContextIgnoringSurfaceOverride(
        surface: ReviewCommentSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil
    ) -> ReviewCommentSourceContext {
        makeSourceContext(
            surface: surface,
            sourceLabel: sourceLabel,
            filePath: filePath,
            lineRange: lineRange,
            languageHint: languageHint,
            timelineItemId: timelineItemId
        )
    }

    private func makeSourceContext(
        surface: ReviewCommentSurfaceKind,
        sourceLabel: String?,
        filePath: String?,
        lineRange: ClosedRange<Int>?,
        languageHint: String?,
        timelineItemId: String?
    ) -> ReviewCommentSourceContext {
        ReviewCommentSourceContext(
            sessionId: sessionId,
            surface: surface,
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
        sourceSurfaceOverride: ReviewCommentSurfaceKind? = nil
    ) -> ReviewCommentSelectionContext {
        ReviewCommentSelectionContext(
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

enum ReviewCommentSelectionScope {
    case activeSession(ReviewCommentSelectionRouter)

    var router: ReviewCommentSelectionRouter {
        switch self {
        case .activeSession(let router):
            router
        }
    }

    func makeContext(
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        languageHint: String? = nil,
        timelineItemId: String? = nil,
        sourceSurfaceOverride: ReviewCommentSurfaceKind? = nil
    ) -> ReviewCommentSelectionContext? {
        ReviewCommentSelectionContext(
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

struct ReviewCommentSourceContext: Equatable {
    let sessionId: String
    let surface: ReviewCommentSurfaceKind
    let sourceLabel: String?
    let filePath: String?
    let lineRange: ClosedRange<Int>?
    let languageHint: String?
    let timelineItemId: String?

    init(
        sessionId: String,
        surface: ReviewCommentSurfaceKind,
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

    func withLineRange(_ range: ClosedRange<Int>?) -> ReviewCommentSourceContext {
        ReviewCommentSourceContext(
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

struct ReviewCommentSelectionRequest: Equatable {
    let selectedText: String
    let source: ReviewCommentSourceContext
}

@MainActor
protocol ReviewCommentSourceLineRangeResolving: AnyObject {
    func reviewCommentSourceLineRange(for range: NSRange) -> ClosedRange<Int>?
}

enum ReviewCommentSelectionTextFormatter {
    static func normalizedSelectedText(_ text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReviewCommentSelectionTextViewSupport {
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
        let normalized = ReviewCommentSelectionTextFormatter.normalizedSelectedText(selected)
        return normalized.isEmpty ? nil : normalized
    }
}

enum ReviewCommentSelectionMenuBuilder {
    @MainActor
    static func editMenu(
        suggestedActions: [UIMenuElement],
        selectedText: String,
        sourceContext: ReviewCommentSourceContext,
        router: ReviewCommentSelectionRouter,
        presentingViewController: UIViewController? = nil,
        textView: UITextView? = nil,
        selectedRange: NSRange? = nil
    ) -> UIMenu? {
        guard let commentAction = commentAction(
            selectedText: selectedText,
            sourceContext: sourceContext,
            router: router,
            presentingViewController: presentingViewController,
            textView: textView,
            selectedRange: selectedRange
        ) else {
            return nil
        }

        return UIMenu(children: [commentAction] + suggestedActions)
    }

    @MainActor
    static func commentAction(
        selectedText: String,
        sourceContext: ReviewCommentSourceContext,
        router: ReviewCommentSelectionRouter,
        presentingViewController: UIViewController? = nil,
        textView: UITextView? = nil,
        selectedRange: NSRange? = nil
    ) -> UIAction? {
        let normalized = ReviewCommentSelectionTextFormatter.normalizedSelectedText(selectedText)
        guard !normalized.isEmpty else { return nil }

        let request = ReviewCommentSelectionRequest(
            selectedText: normalized,
            source: sourceContext
        )

        return UIAction(
            title: "Comment",
            image: UIImage(systemName: "text.bubble")
        ) { _ in
            if router.supportsInlineCommentComposer,
               sourceContext.surface.usesInlineCommentWidget,
               let textView,
               let selectedRange {
                ReviewCommentInlineDraftPresenter.present(
                    textView: textView,
                    selectedRange: selectedRange,
                    request: request,
                    router: router
                )
            } else {
                router.dispatch(request, presentingViewController: presentingViewController)
            }
        }
    }
}

enum ReviewCommentSelectionEditMenuSupport {
    @MainActor
    static func buildMenu(
        textView: UITextView,
        range: NSRange,
        suggestedActions: [UIMenuElement],
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?,
        presentingViewController: UIViewController? = nil
    ) -> UIMenu? {
        guard let router,
              let sourceContext,
              let selectedText = ReviewCommentSelectionTextViewSupport.selectedText(in: textView, range: range) else {
            return nil
        }

        return ReviewCommentSelectionMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
            selectedText: selectedText,
            sourceContext: enrichedSourceContext(sourceContext, textView: textView, range: range),
            router: router,
            presentingViewController: presentingViewController,
            textView: textView,
            selectedRange: range
        )
    }

    @MainActor
    static func enrichedSourceContext(
        _ sourceContext: ReviewCommentSourceContext,
        textView: UITextView,
        range: NSRange
    ) -> ReviewCommentSourceContext {
        sourceContext.withLineRange(sourceLineRange(
            in: textView,
            range: range,
            sourceContext: sourceContext
        ))
    }

    @MainActor
    static func sourceLineRange(
        in textView: UITextView,
        range: NSRange,
        sourceContext: ReviewCommentSourceContext
    ) -> ClosedRange<Int>? {
        if let sourceRange = (textView as? ReviewCommentSourceLineRangeResolving)?.reviewCommentSourceLineRange(for: range) {
            return sourceRange
        }

        if let attributedRange = attributedLineRange(in: textView, range: range) {
            return attributedRange
        }

        let text = textView.attributedText?.string ?? textView.text ?? ""
        if let baseRange = sourceContext.lineRange {
            guard let localRange = textLineRange(in: text, range: range) else { return baseRange }
            return offsetLineRange(localRange, from: baseRange)
        }

        return textLineRange(in: text, range: range)
    }

    @MainActor
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

    static func textLineRange(in text: String, range: NSRange) -> ClosedRange<Int>? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return nil }

        var line = 1
        if range.location > 0 {
            let before = nsText.substring(to: range.location)
            for character in before where character == "\n" {
                line += 1
            }
        }

        var additionalLines = 0
        let selected = nsText.substring(with: range)
        for character in selected where character == "\n" {
            additionalLines += 1
        }
        return line...max(line, line + additionalLines)
    }

    static func offsetLineRange(
        _ localRange: ClosedRange<Int>,
        from baseRange: ClosedRange<Int>
    ) -> ClosedRange<Int> {
        let lower = baseRange.lowerBound + localRange.lowerBound - 1
        let upper = baseRange.lowerBound + localRange.upperBound - 1
        let clampedLower = min(max(lower, baseRange.lowerBound), baseRange.upperBound)
        let clampedUpper = min(max(upper, clampedLower), baseRange.upperBound)
        return clampedLower...clampedUpper
    }
}

private struct ReviewCommentSelectionScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ReviewCommentSelectionScope? = nil
}

private struct ReviewCommentSourceContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: ReviewCommentSourceContext? = nil
}

extension EnvironmentValues {
    /// Routing scope for selected-text review comments.
    /// Boundary views inject this explicitly; shared renderers only consume it.
    var reviewCommentSelectionScope: ReviewCommentSelectionScope? {
        get { self[ReviewCommentSelectionScopeEnvironmentKey.self] }
        set { self[ReviewCommentSelectionScopeEnvironmentKey.self] = newValue }
    }

    /// Source metadata for shared selectable renderers embedded inside a file surface.
    var reviewCommentSourceContext: ReviewCommentSourceContext? {
        get { self[ReviewCommentSourceContextEnvironmentKey.self] }
        set { self[ReviewCommentSourceContextEnvironmentKey.self] = newValue }
    }

    /// Convenience read-only access to the scoped review comment router.
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter? {
        reviewCommentSelectionScope?.router
    }
}

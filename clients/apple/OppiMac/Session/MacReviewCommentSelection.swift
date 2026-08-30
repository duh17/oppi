import AppKit
import Foundation
import SwiftUI

enum MacReviewCommentSelectionFormatting {
    static func normalizedSelectedText(_ text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func absoluteLineRange(local: ClosedRange<Int>, startLine: Int) -> ClosedRange<Int> {
        let offset = max(startLine, 1) - 1
        return (local.lowerBound + offset)...(local.upperBound + offset)
    }
}

enum MacReviewCommentMenu {
    static let addCommentTitle = "Add Review Comment…"

    static func shouldOfferComment(_ selectedText: String) -> Bool {
        !MacReviewCommentSelectionFormatting.normalizedSelectedText(selectedText).isEmpty
    }
}

enum MacReviewCommentMenuBuilder {
    @MainActor
    static func menu(
        insertingCommentInto menu: NSMenu,
        selectedText: String,
        canComment: Bool = true
    ) -> NSMenu {
        guard canComment, MacReviewCommentMenu.shouldOfferComment(selectedText) else { return menu }
        let item = NSMenuItem(
            title: MacReviewCommentMenu.addCommentTitle,
            action: nil,
            keyEquivalent: ""
        )
        menu.insertItem(item, at: 0)
        if menu.items.count > 1 {
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }
}

enum MacReviewCommentComposerPaint {
    static func stashTitle(count: Int) -> String {
        "\(count) review \(count == 1 ? "comment" : "comments") staged"
    }

    static func sendPlaceholder(count: Int) -> String {
        "Send \(count) review \(count == 1 ? "comment" : "comments")…"
    }
}

struct MacReviewCommentSource: Equatable, Sendable {
    var kind: ReviewCommentReferenceSource
    var path: String? = nil
    var label: String? = nil
    var languageHint: String? = nil
    var timelineItemId: String? = nil
    var startLine: Int = 1

    /// File-backed document text. Never `.terminalOutput`.
    static func fileDocument(
        path: String?,
        itemID: String? = nil,
        startLine: Int = 1
    ) -> MacReviewCommentSource {
        MacReviewCommentSource(
            kind: .file,
            path: path,
            timelineItemId: itemID,
            startLine: startLine
        )
    }

    /// File documents use `.file`. Assistant fences omit a path and stay timeline text.
    static func selectable(
        filePath: String?,
        itemID: String? = nil,
        startLine: Int = 1
    ) -> MacReviewCommentSource {
        let trimmed = filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return MacReviewCommentSource(
                kind: .timelineText,
                timelineItemId: itemID,
                startLine: startLine
            )
        }
        return fileDocument(path: trimmed, itemID: itemID, startLine: startLine)
    }
}

struct MacReviewCommentDraft: Equatable, Sendable {
    let selectedText: String
    let source: ReviewCommentReferenceSource
    let label: String?
    let path: String?
    let startLine: Int?
    let endLine: Int?
    let languageHint: String?
    let timelineItemId: String?

    var reference: ReviewCommentReference {
        ReviewCommentReference(
            source: source,
            label: label,
            path: path,
            side: nil,
            startLine: startLine,
            endLine: endLine,
            selectedText: selectedText,
            languageHint: languageHint,
            toolCallId: nil,
            timelineItemId: timelineItemId,
            url: nil
        )
    }

    static func make(
        selectedText: String,
        utf16Range: NSRange,
        in text: String,
        source: MacReviewCommentSource
    ) -> MacReviewCommentDraft? {
        let normalized = MacReviewCommentSelectionFormatting.normalizedSelectedText(selectedText)
        guard !normalized.isEmpty else { return nil }
        let localRange = MacReviewCommentSelectionFormatting.textLineRange(in: text, range: utf16Range)
        let absolute = localRange.map {
            MacReviewCommentSelectionFormatting.absoluteLineRange(local: $0, startLine: source.startLine)
        }
        return MacReviewCommentDraft(
            selectedText: normalized,
            source: source.kind,
            label: source.label,
            path: source.path,
            startLine: absolute?.lowerBound,
            endLine: absolute?.upperBound,
            languageHint: source.languageHint,
            timelineItemId: source.timelineItemId
        )
    }
}

struct IdentifiableReviewCommentDraft: Identifiable {
    let draft: MacReviewCommentDraft

    var id: String {
        [
            draft.path ?? "",
            String(draft.startLine ?? 0),
            String(draft.endLine ?? 0),
            draft.selectedText,
        ].joined(separator: "\u{1e}")
    }
}

struct MacReviewCommentStaging: Sendable {
    let workspaceID: String
    let sessionID: String
    let beginDraft: @MainActor @Sendable (MacReviewCommentDraft) -> Void
}

private struct MacReviewCommentStagingKey: EnvironmentKey {
    static let defaultValue: MacReviewCommentStaging? = nil
}

extension EnvironmentValues {
    var macReviewCommentStaging: MacReviewCommentStaging? {
        get { self[MacReviewCommentStagingKey.self] }
        set { self[MacReviewCommentStagingKey.self] = newValue }
    }
}

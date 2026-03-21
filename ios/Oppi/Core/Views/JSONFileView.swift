import SwiftUI
import Foundation

// MARK: - JSONFileView

/// Pretty-printed JSON with colored keys and values.
///
/// Pretty-printing runs off the main thread. The UIKit code body
/// handles syntax highlighting internally.
struct JSONFileView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var prettyContent: String?

    var body: some View {
        let effectiveContent = prettyContent ?? content

        Group {
            if presentation.usesInlineChrome {
                InlineFileContentChrome(
                    label: "JSON",
                    content: effectiveContent,
                    fullScreenContent: .code(
                        content: content, language: "json",
                        filePath: filePath, startLine: startLine
                    ),
                    maxDisplayLines: FileContentView.maxDisplayLines,
                    presentation: presentation,
                    copyContent: content
                ) { displayContent, _ in
                    NativeCodeBodyView(
                        content: displayContent,
                        language: "json",
                        startLine: startLine,
                        maxHeight: presentation.viewportMaxHeight
                    )
                }
            } else {
                NativeCodeBodyView(
                    content: effectiveContent,
                    language: "json",
                    startLine: startLine,
                    selectedTextSourceContext: piRouter != nil
                        ? fileContentSourceContext(filePath: filePath, language: "json")
                        : nil
                )
            }
        }
        .id(prettyContent != nil ? 1 : 0)
        .task(id: content.count) {
            let raw = content
            prettyContent = await Task.detached(priority: .userInitiated) {
                Self.prettyPrint(raw)
            }.value
        }
    }

    /// Pretty-print JSON, returning the original if parsing fails.
    nonisolated private static func prettyPrint(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
              ),
              let result = String(data: prettyData, encoding: .utf8) else {
            return content
        }
        return result
    }
}

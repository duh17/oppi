import Testing
import UIKit
@testable import Oppi

@Suite("Markdown typography refresh")
@MainActor
struct MarkdownTypographyRefreshTests {
    /// Message Text Size and Dynamic Type changes rebuild `AppFont`; a visible
    /// reply reconfigured with the same content must pick up the new size.
    @Test func fontRebuildReRendersUnchangedMarkdown() throws {
        let originalScale = FontPreferences.messageTextScale
        let originalMono = FontPreferences.useMonoForMessages
        defer {
            FontPreferences.setMessageTextScale(originalScale)
            FontPreferences.setUseMonoForMessages(originalMono)
        }
        FontPreferences.setUseMonoForMessages(false)
        FontPreferences.setMessageTextScale(1.0)

        let content = "Plain words in a reply, with `inline code` after them."
        let view = AssistantMarkdownContentView()
        view.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.apply(configuration: .make(content: content, isStreaming: false, themeID: .dark))
        view.layoutIfNeeded()
        let before = try #require(firstFontSize(in: view))

        FontPreferences.setMessageTextScale(1.3)
        view.apply(configuration: .make(content: content, isStreaming: false, themeID: .dark))
        view.layoutIfNeeded()
        let after = try #require(firstFontSize(in: view))

        #expect(abs(after - before * 1.3) < 0.01)
    }

    private func firstFontSize(in view: UIView) -> CGFloat? {
        guard let text = timelineAllTextViews(in: view).first?.attributedText,
              text.length > 0,
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        else { return nil }
        return font.pointSize
    }
}

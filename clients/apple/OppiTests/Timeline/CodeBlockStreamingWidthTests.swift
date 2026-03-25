import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tests that streaming code blocks maintain correct width constraints.
///
/// Regression: during streaming, the code block header (language label area)
/// appeared wider than the container. The bug auto-recovered when re-entering
/// the chat (fresh render). This test captures the streaming -> re-enter
/// width difference.
@Suite("Code block streaming width")
@MainActor
struct CodeBlockStreamingWidthTests {

    private let containerWidth: CGFloat = 350

    // MARK: - Direct NativeCodeBlockView width

    @Test func codeBlockViewDoesNotExceedContainerWidth() throws {
        let codeView = NativeCodeBlockView()
        let palette = ThemeRuntimeState.currentPalette()

        codeView.apply(
            language: "typescript",
            code: "// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);",
            palette: palette,
            isOpen: false
        )

        let container = UIView(frame: CGRect(x: 0, y: 0, width: containerWidth, height: 800))
        codeView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(codeView)
        NSLayoutConstraint.activate([
            codeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            codeView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            codeView.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()

        #expect(
            codeView.frame.width <= containerWidth + 1,
            "Code block width \(codeView.frame.width) exceeds container \(containerWidth)"
        )
    }

    // MARK: - Streaming code block width via AssistantMarkdownContentView

    @Test func streamingCodeBlockWidthMatchesContainer() throws {
        let mdView = AssistantMarkdownContentView()

        // Phase 1: text only (streaming)
        mdView.apply(configuration: .init(
            content: "So to answer your question directly: **yes, we ARE mounting it.** Line 299 of `sdk-backend.ts`:",
            isStreaming: true,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        // Phase 2: code fence opens (streaming, unclosed)
        let phase2 = "So to answer your question directly: **yes, we ARE mounting it.** Line 299 of `sdk-backend.ts`:\n\n```typescript\n// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);"
        mdView.apply(configuration: .init(
            content: phase2,
            isStreaming: true,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockDuringStreaming = timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView)
        let streamingCodeBlockWidth = codeBlockDuringStreaming?.frame.width ?? 0

        // Phase 3: code fence closes, more text follows (streaming)
        let phase3 = "So to answer your question directly: **yes, we ARE mounting it.** Line 299 of `sdk-backend.ts`:\n\n```typescript\n// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);\n```\n\nThat's production code, not my test."
        mdView.apply(configuration: .init(
            content: phase3,
            isStreaming: true,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockAfterClose = timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView)
        let closedCodeBlockWidth = codeBlockAfterClose?.frame.width ?? 0

        // Phase 4: streaming ends
        mdView.apply(configuration: .init(
            content: phase3,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlockFinal = timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView)
        let finalCodeBlockWidth = codeBlockFinal?.frame.width ?? 0

        // Phase 5: fresh render (simulates re-entering chat)
        let freshView = AssistantMarkdownContentView()
        freshView.apply(configuration: .init(
            content: phase3,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: freshView, width: containerWidth)

        let codeBlockFresh = timelineFirstView(ofType: NativeCodeBlockView.self, in: freshView)
        let freshCodeBlockWidth = codeBlockFresh?.frame.width ?? 0

        // All code block widths must be within the container
        #expect(
            streamingCodeBlockWidth <= containerWidth + 1,
            "Streaming code block width \(streamingCodeBlockWidth) exceeds container \(containerWidth)"
        )
        #expect(
            closedCodeBlockWidth <= containerWidth + 1,
            "Closed code block width \(closedCodeBlockWidth) exceeds container \(containerWidth)"
        )
        #expect(
            finalCodeBlockWidth <= containerWidth + 1,
            "Final code block width \(finalCodeBlockWidth) exceeds container \(containerWidth)"
        )
        #expect(
            freshCodeBlockWidth <= containerWidth + 1,
            "Fresh code block width \(freshCodeBlockWidth) exceeds container \(containerWidth)"
        )

        // The streaming width should match the fresh render width (no regression)
        let widthDelta = abs(streamingCodeBlockWidth - freshCodeBlockWidth)
        #expect(
            widthDelta < 2,
            "Streaming code block width (\(streamingCodeBlockWidth)) differs from fresh render (\(freshCodeBlockWidth)) by \(widthDelta)pt"
        )
    }

    // MARK: - Header width specifically

    @Test func codeBlockHeaderDoesNotExceedCodeBlockWidth() throws {
        let mdView = AssistantMarkdownContentView()

        // Streaming with unclosed code fence
        let content = "Some text before:\n\n```typescript\n// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);"
        mdView.apply(configuration: .init(
            content: content,
            isStreaming: true,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        _ = fittedTimelineSize(for: mdView, width: containerWidth)

        let codeBlock = try #require(
            timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView),
            "Code block view should exist during streaming"
        )

        // Find the header stack (UIStackView inside the code block, not the scroll view)
        let headerStack = codeBlock.subviews
            .compactMap { $0 as? UIStackView }
            .first

        let header = try #require(headerStack, "Header stack should exist in code block")

        #expect(
            header.frame.maxX <= codeBlock.bounds.width,
            "Header maxX (\(header.frame.maxX)) exceeds code block width (\(codeBlock.bounds.width))"
        )

        // Check the header background view width
        let headerBg = codeBlock.subviews.first { !($0 is UIStackView) && !($0 is UIScrollView) }
        if let bg = headerBg {
            #expect(
                bg.frame.width <= codeBlock.bounds.width + 1,
                "Header background width (\(bg.frame.width)) exceeds code block width (\(codeBlock.bounds.width))"
            )
        }
    }

    // MARK: - Layout without pre-layout (mirrors first self-sizing pass)

    @Test func codeBlockWidthCorrectWithoutPrelayout() throws {
        let mdView = AssistantMarkdownContentView()

        let content = "Some text:\n\n```typescript\n// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);\n```\n\nDone."
        mdView.apply(configuration: .init(
            content: content,
            isStreaming: true,
            themeID: ThemeRuntimeState.currentThemeID()
        ))

        // Use fittedTimelineSizeWithoutPrelayout to mirror first self-sizing pass
        _ = fittedTimelineSizeWithoutPrelayout(for: mdView, width: containerWidth)

        let codeBlock = try #require(
            timelineFirstView(ofType: NativeCodeBlockView.self, in: mdView),
            "Code block should exist"
        )

        // After systemLayoutSizeFitting WITHOUT prior layoutIfNeeded,
        // check if the code block width is bounded
        #expect(
            codeBlock.frame.width <= containerWidth + 1,
            "Code block width (\(codeBlock.frame.width)) exceeds container (\(containerWidth)) without pre-layout"
        )
    }

    // MARK: - Streaming-to-markdown transition (actual cell path)

    /// Simulates the real streaming -> markdown transition that happens when
    /// isStreaming flips from true to false. The AssistantTimelineRowContentView
    /// uses a plain streamingTextView during streaming and crossfades to the
    /// markdownView when streaming ends.
    @Test func codeBlockWidthAfterStreamingTransition() throws {
        // Phase 1: create cell with streaming content (plain text view is used)
        let streamingConfig = AssistantTimelineRowConfiguration(
            text: "So to answer your question:\n\n```typescript\n// Mount agentDir\nreadonlyMounts.push(agentDir);\n```\n\nDone.",
            isStreaming: true,
            canFork: false,
            onFork: nil
        )
        let cell = AssistantTimelineRowContentView(configuration: streamingConfig)
        _ = fittedTimelineSize(for: cell, width: containerWidth)

        // During streaming, no code block should exist (streaming text view is used)
        let codeBlockDuringStreaming = timelineFirstView(ofType: NativeCodeBlockView.self, in: cell)
        // Note: code block may or may not exist depending on internal implementation

        // Phase 2: streaming ends — this triggers the crossfade transition
        let finalConfig = AssistantTimelineRowConfiguration(
            text: "So to answer your question:\n\n```typescript\n// Mount agentDir\nreadonlyMounts.push(agentDir);\n```\n\nDone.",
            isStreaming: false,
            canFork: false,
            onFork: nil
        )
        cell.configuration = finalConfig

        // Re-layout at the correct container width — in production this happens
        // when the collection view calls preferredLayoutAttributesFitting, which
        // passes the correct width from the layout attributes.
        _ = fittedTimelineSize(for: cell, width: containerWidth)

        let codeBlockAfterTransition = timelineFirstView(ofType: NativeCodeBlockView.self, in: cell)
        if let codeBlock = codeBlockAfterTransition {
            #expect(
                codeBlock.frame.width <= containerWidth + 1,
                "Code block width (\(codeBlock.frame.width)) exceeds container (\(containerWidth)) after streaming transition"
            )

            // Check the scroll view inside the code block has correct frame
            let scrollViews = timelineAllScrollViews(in: codeBlock)
            for sv in scrollViews {
                #expect(
                    sv.frame.width <= codeBlock.bounds.width + 1,
                    "Scroll view width (\(sv.frame.width)) exceeds code block (\(codeBlock.bounds.width))"
                )
                #expect(
                    sv.frame.width > 0,
                    "Scroll view has zero width after transition — layout not propagated"
                )
            }
        }

        // Phase 3: fresh render (simulating re-entry)
        let freshCell = AssistantTimelineRowContentView(configuration: finalConfig)
        _ = fittedTimelineSize(for: freshCell, width: containerWidth)

        let freshCodeBlock = timelineFirstView(ofType: NativeCodeBlockView.self, in: freshCell)

        if let transitionCB = codeBlockAfterTransition, let freshCB = freshCodeBlock {
            let widthDelta = abs(transitionCB.frame.width - freshCB.frame.width)
            #expect(
                widthDelta < 2,
                "Transition code block width (\(transitionCB.frame.width)) differs from fresh (\(freshCB.frame.width)) by \(widthDelta)pt"
            )

            let heightDelta = abs(transitionCB.frame.height - freshCB.frame.height)
            #expect(
                heightDelta < 5,
                "Transition code block height (\(transitionCB.frame.height)) differs from fresh (\(freshCB.frame.height)) by \(heightDelta)pt"
            )
        }
    }

    @Test func streamingCodeBlockSizeMatchesFreshRender() throws {
        let content = "So to answer your question directly: **yes, we ARE mounting it.** Line 299 of `sdk-backend.ts`:\n\n```typescript\n// Mount agentDir so AGENTS.md, extensions,\nreadonlyMounts.push(agentDir);\n```\n\nThat's production code, not my test. And the real auth.json (2534 bytes, 2 provider entries) is fully readable from inside the VM."

        // Simulate streaming: build up content incrementally
        let streamView = AssistantMarkdownContentView()
        let lines = content.components(separatedBy: "\n")
        for i in 1...lines.count {
            let partial = lines[0..<i].joined(separator: "\n")
            let isLast = i == lines.count
            streamView.apply(configuration: .init(
                content: partial,
                isStreaming: !isLast,
                themeID: ThemeRuntimeState.currentThemeID()
            ))
        }
        let streamSize = fittedTimelineSize(for: streamView, width: containerWidth)

        // Fresh render (simulating re-enter)
        let freshView = AssistantMarkdownContentView()
        freshView.apply(configuration: .init(
            content: content,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
        let freshSize = fittedTimelineSize(for: freshView, width: containerWidth)

        // Heights should be very close (within a few points)
        let heightDelta = abs(streamSize.height - freshSize.height)
        #expect(
            heightDelta < 5,
            "Streaming height (\(streamSize.height)) differs from fresh (\(freshSize.height)) by \(heightDelta)pt -- layout drift"
        )

        // Both code blocks should have the same width
        let streamCodeBlock = timelineFirstView(ofType: NativeCodeBlockView.self, in: streamView)
        let freshCodeBlock = timelineFirstView(ofType: NativeCodeBlockView.self, in: freshView)

        if let sw = streamCodeBlock?.frame.width, let fw = freshCodeBlock?.frame.width {
            let widthDelta = abs(sw - fw)
            #expect(
                widthDelta < 2,
                "Streaming code block width (\(sw)) differs from fresh (\(fw)) by \(widthDelta)pt"
            )
        }
    }
}

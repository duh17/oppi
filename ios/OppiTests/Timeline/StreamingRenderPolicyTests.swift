import Testing
@testable import Oppi

// MARK: - Render Tier Tests

@Suite("StreamingRenderPolicy tier decisions")
@MainActor
struct StreamingRenderPolicyTierTests {

    // MARK: - Streaming always cheap

    @Test("all content kinds return cheap when streaming")
    func allKindsReturnCheapWhenStreaming() {
        let kinds: [StreamingRenderPolicy.ContentKind] = [
            .code(language: .known),
            .code(language: .unknown),
            .code(language: .none),
            .markdown,
            .diff,
            .plainText,
            .bash,
        ]
        for kind in kinds {
            let tier = StreamingRenderPolicy.tier(
                isStreaming: true,
                contentKind: kind,
                byteCount: 100_000,
                lineCount: 5000,
                maxLineByteCount: 500
            )
            #expect(tier == .cheap, "Expected cheap for \(kind) while streaming")
        }
    }

    @Test("media always returns full even when streaming")
    func mediaAlwaysFullEvenStreaming() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: true,
            contentKind: .media,
            byteCount: 0,
            lineCount: 0
        )
        #expect(tier == .full)
    }

    // MARK: - Code tier thresholds

    @Test("small known-language code returns full")
    func smallKnownCodeFull() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 10,
            maxLineByteCount: 50
        )
        #expect(tier == .full)
    }

    @Test("known code at exactly line threshold returns deferred")
    func knownCodeAtLineThresholdDeferred() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 80,
            maxLineByteCount: 10
        )
        #expect(tier == .deferred)
    }

    @Test("known code one line below threshold returns full")
    func knownCodeBelowLineThresholdFull() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 79,
            maxLineByteCount: 10
        )
        #expect(tier == .full)
    }

    @Test("known code at exactly byte threshold returns deferred")
    func knownCodeAtByteThresholdDeferred() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 4096,
            lineCount: 10,
            maxLineByteCount: 10
        )
        #expect(tier == .deferred)
    }

    @Test("known code one byte below byte threshold returns full")
    func knownCodeBelowByteThresholdFull() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 4095,
            lineCount: 10,
            maxLineByteCount: 10
        )
        #expect(tier == .full)
    }

    @Test("known code at exactly long-line byte threshold returns deferred")
    func knownCodeAtLongLineThresholdDeferred() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 200,
            lineCount: 3,
            maxLineByteCount: 160
        )
        #expect(tier == .deferred)
    }

    @Test("known code one byte below long-line threshold returns full")
    func knownCodeBelowLongLineThresholdFull() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 200,
            lineCount: 3,
            maxLineByteCount: 159
        )
        #expect(tier == .full)
    }

    // MARK: - Unknown language doubled thresholds

    @Test("unknown language uses 2x thresholds - below known threshold returns full")
    func unknownBelowKnownThresholdFull() {
        // 80 lines would defer a known language, but unknown needs 160
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .unknown),
            byteCount: 500,
            lineCount: 80,
            maxLineByteCount: 10
        )
        #expect(tier == .full)
    }

    @Test("unknown language defers at 2x line threshold")
    func unknownDefersAtDoubledLineThreshold() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .unknown),
            byteCount: 500,
            lineCount: 160,
            maxLineByteCount: 10
        )
        #expect(tier == .deferred)
    }

    @Test("unknown language defers at 2x byte threshold")
    func unknownDefersAtDoubledByteThreshold() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .unknown),
            byteCount: 8192,
            lineCount: 10,
            maxLineByteCount: 10
        )
        #expect(tier == .deferred)
    }

    @Test("unknown language defers at 2x long-line threshold")
    func unknownDefersAtDoubledLongLineThreshold() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .unknown),
            byteCount: 400,
            lineCount: 3,
            maxLineByteCount: 320
        )
        #expect(tier == .deferred)
    }

    // MARK: - Nil language (no deferral)

    @Test("nil language never defers regardless of size")
    func nilLanguageNeverDefers() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .none),
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }

    // MARK: - Non-code content (no deferred path)

    @Test("text never defers regardless of size")
    func textNeverDefers() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .plainText,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }

    @Test("diff never defers regardless of size")
    func diffNeverDefers() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .diff,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }

    @Test("bash never defers regardless of size")
    func bashNeverDefers() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .bash,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }

    @Test("markdown never defers regardless of size")
    func markdownNeverDefers() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .markdown,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }

    // MARK: - Media

    @Test("media always returns full when not streaming")
    func mediaAlwaysFullNotStreaming() {
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .media,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 1000
        )
        #expect(tier == .full)
    }
}

// MARK: - Content Profile Tests

@Suite("StreamingRenderPolicy content profiling")
@MainActor
struct StreamingRenderPolicyContentProfileTests {

    @Test("profile counts lines and bytes correctly")
    func profileBasic() {
        let text = "line 1\nline 2\nline 3"
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.lineCount == 3)
        #expect(profile.byteCount == text.utf8.count)
        #expect(profile.maxLineByteCount == 6) // "line 1" = 6 bytes
    }

    @Test("profile handles single line with no newline")
    func profileSingleLine() {
        let text = "hello world"
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.lineCount == 1)
        #expect(profile.byteCount == 11)
        #expect(profile.maxLineByteCount == 11)
    }

    @Test("profile handles trailing newline")
    func profileTrailingNewline() {
        let text = "line 1\n"
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        // Trailing newline creates an empty final line
        #expect(profile.lineCount == 2)
        #expect(profile.maxLineByteCount == 6)
    }

    @Test("profile finds longest line")
    func profileLongestLine() {
        let text = "short\n" + String(repeating: "x", count: 200) + "\nshort"
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.maxLineByteCount == 200)
    }

    @Test("profile handles empty string")
    func profileEmptyString() {
        let profile = StreamingRenderPolicy.ContentProfile.from(text: "")
        #expect(profile.lineCount == 1)
        #expect(profile.byteCount == 0)
        #expect(profile.maxLineByteCount == 0)
    }

    @Test("profile handles multibyte UTF-8")
    func profileMultibyteUTF8() {
        let text = "café" // é is 2 bytes in UTF-8
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.byteCount == 5) // c(1) a(1) f(1) é(2)
        #expect(profile.maxLineByteCount == 5)
    }

    @Test("profile integration with tier decision at boundary")
    func profileTierIntegration() {
        // Build text that is exactly at the line threshold
        let lines = (1...80).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.lineCount == 80)

        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount
        )
        #expect(tier == .deferred)
    }
}

// MARK: - Inconsistency Tests

@Suite("StreamingRenderPolicy inconsistencies")
@MainActor
struct StreamingRenderPolicyInconsistencyTests {

    // MARK: - INCONSISTENCY 1: Signature hashing

    // FIXED (Phase 2): Markdown signature now includes isStreaming, consistent
    // with all other strategies. Streaming->done transition forces re-render.

    @Test("FIXED: all strategies include isStreaming in signature")
    func allStrategiesIncludeStreamingInSignature() {
        let kinds: [StreamingRenderPolicy.ContentKind] = [
            .code(language: .known),
            .plainText,
            .diff,
            .bash,
            .markdown,
        ]
        for kind in kinds {
            #expect(
                StreamingRenderPolicy.signatureIncludesStreamingFlag(for: kind) == true,
                "All text-based strategies should include isStreaming in signature"
            )
        }
        // Media has no signature-based re-render gate
        #expect(StreamingRenderPolicy.signatureIncludesStreamingFlag(for: .media) == false)
    }

    @Test("FIXED: verify markdown signature now changes on streaming transition")
    func verifyMarkdownSignatureFixedWithRealImplementation() {
        // Code: signature changes when isStreaming changes
        let codeStreamingSig = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: "let x = 1",
            language: .swift,
            startLine: 1,
            isStreaming: true
        )
        let codeDoneSig = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: "let x = 1",
            language: .swift,
            startLine: 1,
            isStreaming: false
        )
        #expect(codeStreamingSig != codeDoneSig,
            "Code signature should change on streaming->done transition")

        // Markdown: signature NOW changes when isStreaming changes (fixed)
        let mdStreamingSig = ToolTimelineRowRenderMetrics.markdownSignature(
            "# Hello", isStreaming: true
        )
        let mdDoneSig = ToolTimelineRowRenderMetrics.markdownSignature(
            "# Hello", isStreaming: false
        )
        #expect(mdStreamingSig != mdDoneSig,
            "Markdown signature should now change on streaming->done transition")
    }

    // MARK: - INCONSISTENCY 2: Deferred rendering support

    // Only code has size-based deferral. Text, diff, and bash all jump
    // directly from cheap (streaming) to full (done) with no intermediate
    // deferred tier. A 100KB bash output gets full ANSI parsing on the
    // main thread the moment isDone flips, while a 5KB code file defers.

    @Test("INCONSISTENCY: code defers large content but text does not")
    func codeDeferButTextDoesNot() {
        let largeByteCount = 100_000
        let largeLineCount = 5000

        let codeTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )
        let textTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .plainText,
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )

        #expect(codeTier == .deferred)
        #expect(textTier == .full,
            """
            INCONSISTENCY: 100KB of text is rendered fully on the main thread \
            (ANSI parse + attributed string construction), while 5KB of code \
            gets deferred to avoid blocking. Text strategy has no size-based \
            deferral even though ToolRowTextRenderer.makeANSIOutputPresentation \
            does O(n) ANSI parsing.
            """)
    }

    @Test("INCONSISTENCY: code defers large content but diff does not")
    func codeDeferButDiffDoesNot() {
        let largeByteCount = 50_000
        let largeLineCount = 2000

        let codeTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )
        let diffTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .diff,
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )

        #expect(codeTier == .deferred)
        #expect(diffTier == .full,
            """
            INCONSISTENCY: A 2000-line diff is rendered fully on the main \
            thread (makeDiffAttributedText iterates all lines for coloring), \
            while 80-line code gets deferred. Diff rendering includes syntax \
            highlighting per-line via diffLanguage(for:), making it potentially \
            more expensive than plain code highlighting.
            """)
    }

    @Test("INCONSISTENCY: code defers large content but bash does not")
    func codeDeferButBashDoesNot() {
        let largeByteCount = 100_000
        let largeLineCount = 3000

        let codeTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )
        let bashTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .bash,
            byteCount: largeByteCount,
            lineCount: largeLineCount
        )

        #expect(codeTier == .deferred)
        #expect(bashTier == .full,
            """
            INCONSISTENCY: 100KB of bash output gets full ANSI parsing the \
            moment isDone flips, potentially blocking the main thread. Bash \
            output is often the largest content type (build logs, test output) \
            and has no deferral mechanism.
            """)
    }

    // MARK: - INCONSISTENCY 3: Auto-follow on cell reuse during streaming

    // When a cell is reused during streaming (content is NOT a continuation),
    // strategies disagree about whether to enable or disable auto-follow.

    @Test("INCONSISTENCY: code enables auto-follow on cell reuse but diff disables it")
    func codeEnablesDiffDisablesOnCellReuse() {
        let codeBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .code(language: .known))
        let diffBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .diff)

        #expect(codeBehavior == .enableOnNonContinuation)
        #expect(diffBehavior == .disableOnNonContinuation,
            """
            INCONSISTENCY: When a cell is reused during streaming and the new \
            content is not a continuation of the old (different tool's output), \
            code re-enables auto-follow for the new content, but diff DISABLES \
            it. This means reused diff cells won't auto-scroll to show new \
            streaming content, while code cells will.

            Code strategy (line ~134):
                } else if !isStreamingContinuation, shouldRerender {
                    expandedShouldAutoFollow = true  // re-enable

            Diff strategy (line ~90):
                } else if !isStreamingContinuation {
                    expandedShouldAutoFollow = false  // disable (opposite!)
            """)
    }

    @Test("INCONSISTENCY: text uses shouldAutoFollowOnFirstRender but code checks isStreaming directly")
    func textUsesParameterCodeChecksDirectly() {
        let codeBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .code(language: .known))
        let textBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .plainText)

        // Both ultimately enable, but the condition paths differ.
        // Code checks: isStreaming && !isStreamingContinuation && shouldRerender
        // Text checks: shouldAutoFollowOnFirstRender && shouldRerender && !isStreamingContinuation
        // The difference: text couples auto-follow to a parameter, code couples to isStreaming.
        // If shouldAutoFollowOnFirstRender != isStreaming (which shouldn't happen, but
        // could if called incorrectly), behavior diverges.
        #expect(codeBehavior == .enableOnNonContinuation)
        #expect(textBehavior == .enableOnNonContinuation,
            """
            Code and text AGREE on the outcome (both enable auto-follow on \
            cell reuse during streaming), but DISAGREE on the mechanism. Code \
            checks isStreaming directly; text checks a shouldAutoFollowOnFirstRender \
            parameter (always set to !isDone by the caller). If a future caller \
            passes a different value, text behavior would silently diverge.
            """)
    }

    @Test("INCONSISTENCY: bash has no cell reuse auto-follow check at all")
    func bashHasNoCellReuseCheck() {
        let bashBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .bash)

        #expect(bashBehavior == .noCheck,
            """
            INCONSISTENCY: Bash strategy has no isStreamingContinuation check. \
            When a cell is reused, outputShouldAutoFollow is only set on first \
            visibility (!wasOutputVisible). If a bash cell is reused for a \
            different tool's output while already visible, the auto-follow \
            state from the PREVIOUS tool persists. A user who manually scrolled \
            up in tool A's output would see tool B's output also not auto-follow, \
            even though it's fresh content.
            """)
    }

    @Test("INCONSISTENCY: markdown disables on done rather than checking continuation")
    func markdownDisablesOnDoneNotContinuation() {
        let markdownBehavior = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: .markdown)

        #expect(markdownBehavior == .disableOnDone,
            """
            INCONSISTENCY: Markdown strategy's auto-follow condition is: \
            if visible && !shouldAutoFollowOnFirstRender && shouldRerender \
            && !isStreamingContinuation → disable. This is structurally \
            different from all other strategies: it only acts when content \
            is DONE (!shouldAutoFollowOnFirstRender), never during streaming. \
            During streaming cell reuse, markdown auto-follow state is not \
            updated for the new content.
            """)
    }

    // MARK: - INCONSISTENCY 4: Scroll reset behavior

    @Test("INCONSISTENCY: text always resets scroll but code guards with !isStreaming")
    func textAlwaysResetsScrollCodeGuards() {
        let textBehavior = StreamingRenderPolicy.scrollResetBehavior(for: .plainText)
        let codeBehavior = StreamingRenderPolicy.scrollResetBehavior(for: .code(language: .known))

        #expect(textBehavior == .always)
        #expect(codeBehavior == .onlyWhenNotStreaming,
            """
            INCONSISTENCY: When a re-render occurs, text strategy always resets \
            scroll position (including during streaming signature changes caused \
            by error state or language changes). Code and diff only reset when \
            !isStreaming, preserving the user's scroll position during streaming. \

            Text strategy (line ~88):
                if shouldRerender {
                    if expandedShouldAutoFollow {
                        scheduleExpandedAutoScrollToBottomIfNeeded()
                    } else {
                        ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
                    }
                }
            // ^ No !isStreaming guard — always enters this block on re-render.

            Code strategy (line ~140):
                if shouldRerender {
                    if expandedShouldAutoFollow {
                        ...
                    } else if !isStreaming {  // <-- guard
                        ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
                    }
                }
            """)
    }

    @Test("INCONSISTENCY: markdown uses auto-follow guard instead of streaming guard")
    func markdownUsesAutoFollowGuardForScroll() {
        let markdownBehavior = StreamingRenderPolicy.scrollResetBehavior(for: .markdown)
        let codeBehavior = StreamingRenderPolicy.scrollResetBehavior(for: .code(language: .known))

        #expect(markdownBehavior == .onlyWhenNotAutoFollowing)
        #expect(codeBehavior == .onlyWhenNotStreaming,
            """
            INCONSISTENCY: Markdown resets scroll only when NOT auto-following \
            (regardless of streaming state). Code/diff reset only when NOT streaming \
            (regardless of auto-follow state). These conditions overlap but aren't \
            equivalent: during streaming with auto-follow disabled (user scrolled up), \
            code preserves scroll position but markdown resets it.
            """)
    }

    // MARK: - INCONSISTENCY 5: Threshold asymmetry

    @Test("INCONSISTENCY: unknown language gets 2x tolerance but no other strategy adjusts for content complexity")
    func unknownLanguageThresholdAsymmetry() {
        // At 80 lines, known language defers but unknown does not
        let knownTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 80,
            maxLineByteCount: 10
        )
        let unknownTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .unknown),
            byteCount: 500,
            lineCount: 80,
            maxLineByteCount: 10
        )

        #expect(knownTier == .deferred)
        #expect(unknownTier == .full,
            """
            Code strategy gives .unknown language 2x threshold tolerance \
            (80->160 lines, 4KB->8KB bytes, 160->320 bytes/line) because \
            unknown-language highlighting is cheaper (no keyword matching). \
            This threshold adjustment is buried in shouldDeferHighlight() \
            and not applied to any other content kind. If text or bash \
            got a deferred path, they'd need their own complexity-adjusted \
            thresholds but have no infrastructure for it.
            """)
    }

    // MARK: - INCONSISTENCY 6: supportsDeferredRendering gap

    @Test("INCONSISTENCY: only code supports deferred rendering")
    func onlyCodeSupportsDeferredRendering() {
        let codeSupports = StreamingRenderPolicy.ContentKind.code(language: .known).supportsDeferredRendering
        let textSupports = StreamingRenderPolicy.ContentKind.plainText.supportsDeferredRendering
        let diffSupports = StreamingRenderPolicy.ContentKind.diff.supportsDeferredRendering
        let bashSupports = StreamingRenderPolicy.ContentKind.bash.supportsDeferredRendering
        let mdSupports = StreamingRenderPolicy.ContentKind.markdown.supportsDeferredRendering

        #expect(codeSupports == true)
        #expect(textSupports == false)
        #expect(diffSupports == false)
        #expect(bashSupports == false)
        #expect(mdSupports == false,
            """
            Only code has a deferred rendering path. This means the transition \
            from streaming to done is a binary cheap->full jump for all other \
            content types. For large bash outputs (build logs) or large diffs, \
            this jump can block the main thread. The policy's tier() function \
            reflects this current reality — text/diff/bash/markdown can never \
            return .deferred.
            """)
    }

    // MARK: - Edge case: streaming->done transition

    @Test("streaming to done transition changes tier for code")
    func streamingToDoneChangesCodeTier() {
        let streamingTier = StreamingRenderPolicy.tier(
            isStreaming: true,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 10,
            maxLineByteCount: 50
        )
        let doneTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 500,
            lineCount: 10,
            maxLineByteCount: 50
        )

        #expect(streamingTier == .cheap)
        #expect(doneTier == .full)
    }

    @Test("streaming to done transition changes tier for large code to deferred")
    func streamingToDoneChangesLargeCodeToDeferred() {
        let streamingTier = StreamingRenderPolicy.tier(
            isStreaming: true,
            contentKind: .code(language: .known),
            byteCount: 10_000,
            lineCount: 200,
            maxLineByteCount: 50
        )
        let doneTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: 10_000,
            lineCount: 200,
            maxLineByteCount: 50
        )

        #expect(streamingTier == .cheap)
        #expect(doneTier == .deferred)
    }

    @Test("streaming to done transition for text: cheap to full with no deferred step")
    func streamingToDoneTextJumpsCheapToFull() {
        let streamingTier = StreamingRenderPolicy.tier(
            isStreaming: true,
            contentKind: .plainText,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 200
        )
        let doneTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .plainText,
            byteCount: 100_000,
            lineCount: 5000,
            maxLineByteCount: 200
        )

        #expect(streamingTier == .cheap)
        #expect(doneTier == .full,
            """
            100KB of text jumps directly from cheap to full with no deferred \
            step. The main thread will block for the entire ANSI parse.
            """)
    }

    // MARK: - Edge case: threshold boundaries with real content profiles

    @Test("profile at exactly 80 lines with short lines: only line threshold triggers")
    func profileAtExactly80Lines() {
        let lines = (1...80).map { _ in "short" }
        let text = lines.joined(separator: "\n")
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)

        #expect(profile.lineCount == 80)
        #expect(profile.byteCount < StreamingRenderPolicy.deferredHighlightByteThreshold)
        #expect(profile.maxLineByteCount < StreamingRenderPolicy.deferredHighlightLongLineByteThreshold)

        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount
        )
        #expect(tier == .deferred, "80 lines should trigger deferral via line threshold alone")
    }

    @Test("profile at exactly 4096 bytes with few lines: only byte threshold triggers")
    func profileAtExactly4096Bytes() {
        // Build text that's exactly 4096 bytes but well under 80 lines
        let lineContent = String(repeating: "a", count: 200)
        var text = ""
        while text.utf8.count + lineContent.utf8.count + 1 <= 4096 {
            if !text.isEmpty { text += "\n" }
            text += lineContent
        }
        // Pad to exactly 4096
        let remaining = 4096 - text.utf8.count
        if remaining > 0 {
            if remaining > 1 {
                text += "\n" + String(repeating: "b", count: remaining - 1)
            } else {
                text += "b"
            }
        }

        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)
        #expect(profile.byteCount == 4096)
        #expect(profile.lineCount < StreamingRenderPolicy.deferredHighlightLineThreshold)

        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount
        )
        #expect(tier == .deferred, "4096 bytes should trigger deferral via byte threshold alone")
    }

    @Test("profile with single 160-byte line: only long-line threshold triggers")
    func profileWithSingle160ByteLine() {
        let text = String(repeating: "x", count: 160)
        let profile = StreamingRenderPolicy.ContentProfile.from(text: text)

        #expect(profile.lineCount == 1)
        #expect(profile.byteCount == 160)
        #expect(profile.maxLineByteCount == 160)
        #expect(profile.byteCount < StreamingRenderPolicy.deferredHighlightByteThreshold)

        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount
        )
        #expect(tier == .deferred, "160-byte line should trigger deferral via long-line threshold")
    }
}

// MARK: - Cross-Strategy Agreement Matrix

@Suite("StreamingRenderPolicy cross-strategy agreement")
@MainActor
struct StreamingRenderPolicyCrossStrategyTests {

    /// Scenario: identical content rendered by different strategies.
    /// Documents what each strategy would decide for the same input.

    @Test("5KB content: code defers, all others render fully")
    func fiveKBContentDivergence() {
        let byteCount = 5000
        let lineCount = 50
        let maxLineByteCount = 100

        let codeTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: byteCount,
            lineCount: lineCount,
            maxLineByteCount: maxLineByteCount
        )
        let textTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .plainText,
            byteCount: byteCount,
            lineCount: lineCount,
            maxLineByteCount: maxLineByteCount
        )
        let diffTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .diff,
            byteCount: byteCount,
            lineCount: lineCount,
            maxLineByteCount: maxLineByteCount
        )
        let bashTier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .bash,
            byteCount: byteCount,
            lineCount: lineCount,
            maxLineByteCount: maxLineByteCount
        )

        #expect(codeTier == .deferred, "Code defers 5KB content")
        #expect(textTier == .full, "Text renders 5KB fully (no deferral)")
        #expect(diffTier == .full, "Diff renders 5KB fully (no deferral)")
        #expect(bashTier == .full, "Bash renders 5KB fully (no deferral)")
    }

    @Test("streaming state: all strategies agree on cheap")
    func streamingAllAgreeOnCheap() {
        let kinds: [StreamingRenderPolicy.ContentKind] = [
            .code(language: .known),
            .code(language: .unknown),
            .code(language: .none),
            .plainText,
            .diff,
            .bash,
            .markdown,
        ]

        for kind in kinds {
            let tier = StreamingRenderPolicy.tier(
                isStreaming: true,
                contentKind: kind,
                byteCount: 100,
                lineCount: 5,
                maxLineByteCount: 20
            )
            #expect(tier == .cheap, "\(kind) should be cheap while streaming")
        }
    }

    @Test("small not-streaming: all strategies agree on full")
    func smallNotStreamingAllAgreeOnFull() {
        let kinds: [StreamingRenderPolicy.ContentKind] = [
            .code(language: .known),
            .code(language: .unknown),
            .code(language: .none),
            .plainText,
            .diff,
            .bash,
            .markdown,
            .media,
        ]

        for kind in kinds {
            let tier = StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: kind,
                byteCount: 100,
                lineCount: 5,
                maxLineByteCount: 20
            )
            #expect(tier == .full, "\(kind) should be full for small non-streaming content")
        }
    }

    @Test("large not-streaming: strategies DIVERGE — only code defers")
    func largeNotStreamingDivergence() {
        let kinds: [StreamingRenderPolicy.ContentKind] = [
            .code(language: .known),
            .plainText,
            .diff,
            .bash,
            .markdown,
        ]

        var tierMap: [String: StreamingRenderPolicy.RenderTier] = [:]
        for kind in kinds {
            let tier = StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: kind,
                byteCount: 50_000,
                lineCount: 2000,
                maxLineByteCount: 200
            )
            tierMap["\(kind)"] = tier
        }

        // Only code defers — all others do full expensive rendering
        #expect(tierMap["code(language: Oppi.StreamingRenderPolicy.CodeLanguageCategory.known)"] == .deferred)

        let fullCount = tierMap.values.filter { $0 == .full }.count
        let deferredCount = tierMap.values.filter { $0 == .deferred }.count

        #expect(deferredCount == 1, "Only 1 content kind defers large content")
        #expect(fullCount == 4, "4 content kinds do full rendering on large content")
    }

    // MARK: - Signature behavior matrix

    @Test("signature flag matrix: 5 include streaming, 1 does not")
    func signatureFlagMatrix() {
        let includesStreaming: [(StreamingRenderPolicy.ContentKind, Bool)] = [
            (.code(language: .known), true),
            (.plainText, true),
            (.diff, true),
            (.bash, true),
            (.markdown, true),   // fixed in Phase 2
            (.media, false),
        ]

        for (kind, expected) in includesStreaming {
            let actual = StreamingRenderPolicy.signatureIncludesStreamingFlag(for: kind)
            #expect(actual == expected, "Signature streaming flag for \(kind)")
        }
    }

    // MARK: - Auto-follow behavior matrix

    @Test("auto-follow behavior matrix: strategies disagree on cell reuse")
    func autoFollowBehaviorMatrix() {
        let behaviors: [(StreamingRenderPolicy.ContentKind, StreamingRenderPolicy.CellReuseAutoFollowBehavior)] = [
            (.code(language: .known), .enableOnNonContinuation),
            (.plainText, .enableOnNonContinuation),
            (.diff, .disableOnNonContinuation),     // opposite of code!
            (.markdown, .disableOnDone),             // different mechanism entirely
            (.bash, .noCheck),                       // no check at all
            (.media, .noCheck),
        ]

        for (kind, expected) in behaviors {
            let actual = StreamingRenderPolicy.cellReuseAutoFollowBehavior(for: kind)
            #expect(actual == expected, "Cell reuse auto-follow for \(kind)")
        }

        // Verify the inconsistency: 3 different behaviors across 5 strategy types
        let uniqueBehaviors = Set(behaviors.prefix(5).map(\.1))
        #expect(uniqueBehaviors.count >= 3,
            """
            At least 3 different auto-follow behaviors exist across 5 strategy \
            types. A unified policy should pick ONE behavior for cell reuse.
            """)
    }

    // MARK: - Scroll reset behavior matrix

    @Test("scroll reset behavior matrix: strategies disagree on when to reset")
    func scrollResetBehaviorMatrix() {
        let behaviors: [(StreamingRenderPolicy.ContentKind, StreamingRenderPolicy.ScrollResetBehavior)] = [
            (.code(language: .known), .onlyWhenNotStreaming),
            (.diff, .onlyWhenNotStreaming),
            (.plainText, .always),                   // different from code!
            (.markdown, .onlyWhenNotAutoFollowing),   // different mechanism
            (.bash, .noReset),
            (.media, .noReset),
        ]

        for (kind, expected) in behaviors {
            let actual = StreamingRenderPolicy.scrollResetBehavior(for: kind)
            #expect(actual == expected, "Scroll reset behavior for \(kind)")
        }

        let uniqueBehaviors = Set(behaviors.prefix(4).map(\.1))
        #expect(uniqueBehaviors.count >= 3,
            """
            At least 3 different scroll reset behaviors exist across 4 text-based \
            strategy types. Code/diff guard with !isStreaming, text always resets, \
            markdown guards with !autoFollow.
            """)
    }
}

// MARK: - Threshold Constant Parity Tests

@Suite("StreamingRenderPolicy threshold constants")
@MainActor
struct StreamingRenderPolicyThresholdTests {

    @Test("line threshold is 80")
    func lineThreshold() {
        #expect(StreamingRenderPolicy.deferredHighlightLineThreshold == 80)
    }

    @Test("byte threshold is 4KB")
    func byteThreshold() {
        #expect(StreamingRenderPolicy.deferredHighlightByteThreshold == 4096)
    }

    @Test("long-line byte threshold is 160")
    func longLineByteThreshold() {
        #expect(StreamingRenderPolicy.deferredHighlightLongLineByteThreshold == 160)
    }

    @Test("unknown language multiplier is 2x")
    func unknownLanguageMultiplier() {
        #expect(StreamingRenderPolicy.unknownLanguageThresholdMultiplier == 2)
    }
}

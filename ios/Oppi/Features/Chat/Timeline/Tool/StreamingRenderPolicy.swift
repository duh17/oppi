import Foundation

// MARK: - StreamingRenderPolicy

/// Centralized policy for streaming render decisions.
///
/// All render strategies (code, text, diff, bash, markdown) query this
/// policy to determine the render tier (cheap/deferred/full) instead of
/// making independent `isStreaming` decisions. One place to tune
/// thresholds, one place to test tier logic.
///
/// Auto-follow and scroll-reset behavior remain per-strategy for now
/// (documented here as behavioral metadata for future unification).
@MainActor
enum StreamingRenderPolicy {

    // MARK: - Render Tier

    /// What level of rendering work to perform for a content update.
    enum RenderTier: String, Sendable, Equatable {
        /// Plain text append, no parsing. Used during streaming.
        case cheap
        /// Show placeholder, schedule async upgrade. Used for large non-streaming
        /// content that would block the main thread.
        case deferred
        /// Full rendering: syntax highlight, markdown parse, diff compute.
        case full
    }

    // MARK: - Content Kind

    /// Discriminated content type for policy decisions.
    enum ContentKind: Sendable, Equatable {
        case code(language: CodeLanguageCategory)
        // periphery:ignore - exhaustive switch coverage; tested in StreamingRenderPolicyTests
        case markdown
        case diff
        case plainText
        case bash
        /// Read-media, plot, and other embedded views — always full.
        // periphery:ignore - exhaustive switch coverage; tested in StreamingRenderPolicyTests
        case media

        /// Whether this content kind has a deferred path in the current
        /// implementation. Only code does.
        var supportsDeferredRendering: Bool {
            switch self {
            case .code: true
            case .markdown, .diff, .plainText, .bash, .media: false
            }
        }
    }

    /// Coarse language category for threshold decisions.
    /// Code strategy uses different thresholds for known vs unknown vs nil.
    enum CodeLanguageCategory: Sendable, Equatable {
        /// A recognized language (swift, python, etc.)
        case known
        /// `.unknown` — detected as code but language not identified
        case unknown
        /// `nil` — no language information at all
        case none
    }

    // MARK: - Thresholds (mirrored from ToolRowCodeRenderStrategy)

    /// Line count at which known-language code defers highlighting.
    static let deferredHighlightLineThreshold = 80

    /// Byte count at which known-language code defers highlighting.
    static let deferredHighlightByteThreshold = 4 * 1024

    /// Per-line byte count at which known-language code defers highlighting.
    static let deferredHighlightLongLineByteThreshold = 160

    /// Multiplier applied to all thresholds for `.unknown` language.
    /// Unknown language highlighting is cheaper (no keyword matching), so we
    /// tolerate larger content before deferring.
    static let unknownLanguageThresholdMultiplier = 2

    // MARK: - Tier Decision

    /// Determines the render tier for a content update.
    ///
    /// This mirrors the current scattered behavior:
    /// - Streaming → always `.cheap` (all strategies agree here)
    /// - Not streaming + code + large → `.deferred` (only code strategy)
    /// - Not streaming + everything else → `.full`
    ///
    /// - Parameters:
    ///   - isStreaming: Whether the tool is still receiving content.
    ///   - contentKind: What type of content is being rendered.
    ///   - byteCount: Total byte count of the content.
    ///   - lineCount: Total line count of the content.
    ///   - maxLineByteCount: Byte count of the longest single line.
    /// - Returns: The render tier to use.
    static func tier(
        isStreaming: Bool,
        contentKind: ContentKind,
        byteCount: Int,
        lineCount: Int,
        maxLineByteCount: Int = 0
    ) -> RenderTier {
        // Media/embedded views are always fully rendered — they have no
        // streaming path (renderExpandedReadMediaMode/renderExpandedPlotMode
        // don't take an isStreaming parameter at all).
        if case .media = contentKind {
            return .full
        }

        // All text-based strategies agree: streaming → cheap
        if isStreaming {
            return .cheap
        }

        // Only code has a deferred path in the current implementation
        if case .code(let languageCategory) = contentKind {
            return codeTier(
                languageCategory: languageCategory,
                byteCount: byteCount,
                lineCount: lineCount,
                maxLineByteCount: maxLineByteCount
            )
        }

        // Text, markdown, diff, bash: always full when not streaming
        return .full
    }

    /// Code-specific tier logic, mirroring `ToolRowCodeRenderStrategy.shouldDeferHighlight`.
    private static func codeTier(
        languageCategory: CodeLanguageCategory,
        byteCount: Int,
        lineCount: Int,
        maxLineByteCount: Int
    ) -> RenderTier {
        switch languageCategory {
        case .none:
            // nil language → shouldDeferHighlight returns false → always full
            return .full

        case .unknown:
            // .unknown uses 2x thresholds
            let multiplier = unknownLanguageThresholdMultiplier
            if byteCount >= deferredHighlightByteThreshold * multiplier
                || lineCount >= deferredHighlightLineThreshold * multiplier
                || maxLineByteCount >= deferredHighlightLongLineByteThreshold * multiplier {
                return .deferred
            }
            return .full

        case .known:
            if lineCount >= deferredHighlightLineThreshold
                || byteCount >= deferredHighlightByteThreshold
                || maxLineByteCount >= deferredHighlightLongLineByteThreshold {
                return .deferred
            }
            return .full
        }
    }

    // MARK: - Signature Inclusion

    /// Whether `isStreaming` is included in the render signature hash for
    /// the given content kind.
    ///
    /// All text-based strategies include `isStreaming` in their signature
    /// so the streaming→done transition forces a re-render (upgrading from
    /// cheap plain text to full highlighting/parsing).
    ///
    /// Media has no streaming concept and no signature-based re-render gate.
    static func signatureIncludesStreamingFlag(for contentKind: ContentKind) -> Bool {
        switch contentKind {
        case .code, .plainText, .diff, .bash, .markdown:
            return true
        case .media:
            return false
        }
    }

    // MARK: - Auto-Follow Behavior

    /// Describes how a strategy handles auto-follow on cell reuse during streaming.
    enum CellReuseAutoFollowBehavior: String, Sendable, Equatable {
        /// Enables auto-follow when content is not a continuation (code, text).
        case enableOnNonContinuation
        /// Disables auto-follow when content is not a continuation (diff).
        case disableOnNonContinuation
        /// Disables auto-follow based on done state, not continuation (markdown).
        case disableOnDone
        /// No continuation check at all (bash).
        case noCheck
    }

    /// Returns how the given content kind handles auto-follow when a cell is
    /// reused during streaming and the new content is NOT a continuation of
    /// the previous content.
    ///
    /// This exposes a real inconsistency: code and text enable auto-follow
    /// for the new content, but diff disables it, and bash doesn't check.
    static func cellReuseAutoFollowBehavior(for contentKind: ContentKind) -> CellReuseAutoFollowBehavior {
        switch contentKind {
        case .code:
            return .enableOnNonContinuation
        case .plainText:
            return .enableOnNonContinuation
        case .diff:
            return .disableOnNonContinuation
        case .markdown:
            return .disableOnDone
        case .bash:
            return .noCheck
        case .media:
            return .noCheck
        }
    }

    // MARK: - Scroll Reset Behavior

    /// Describes when a strategy resets scroll position on re-render.
    // periphery:ignore - used by StreamingRenderPolicyTests via @testable import
    enum ScrollResetBehavior: String, Sendable, Equatable {
        /// Resets only when `!isStreaming` (code, diff).
        case onlyWhenNotStreaming
        /// Always resets on re-render, no streaming guard (text).
        case always
        /// Resets only when not auto-following (markdown).
        case onlyWhenNotAutoFollowing
        /// No scroll reset logic (bash output uses auto-follow only).
        case noReset
    }

    /// Returns how the given content kind handles scroll position reset
    /// when a re-render occurs.
    ///
    /// Inconsistency: text always resets (even during streaming rerenders
    /// triggered by signature changes), while code/diff guard against it.
    static func scrollResetBehavior(for contentKind: ContentKind) -> ScrollResetBehavior {
        switch contentKind {
        case .code, .diff:
            return .onlyWhenNotStreaming
        case .plainText:
            return .always
        case .markdown:
            return .onlyWhenNotAutoFollowing
        case .bash:
            return .noReset
        case .media:
            return .noReset
        }
    }

    // MARK: - Content Profile

    /// Content size profile, matching `ToolRowCodeRenderStrategy.HighlightProfile`.
    struct ContentProfile: Sendable, Equatable {
        let byteCount: Int
        let lineCount: Int
        let maxLineByteCount: Int

        /// Build a profile by scanning UTF-8 bytes. Matches the code strategy's
        /// `highlightProfile(for:)` implementation.
        static func from(text: String) -> Self {
            var byteCount = 0
            var lineCount = 1
            var currentLineByteCount = 0
            var maxLineByteCount = 0

            for byte in text.utf8 {
                byteCount += 1
                if byte == 0x0A { // newline
                    maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
                    currentLineByteCount = 0
                    lineCount += 1
                } else {
                    currentLineByteCount += 1
                }
            }

            maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
            return Self(
                byteCount: byteCount,
                lineCount: lineCount,
                maxLineByteCount: maxLineByteCount
            )
        }
    }
}

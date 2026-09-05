import Foundation

// MARK: - StreamingRenderPolicy

/// Centralized policy for streaming render decisions.
///
/// All render strategies (code, text, diff, bash, markdown) query this
/// policy to determine the render tier (cheap/deferred/full) instead of
/// making independent `isStreaming` decisions. One place to tune
/// thresholds, one place to test tier logic.
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

    // MARK: - Resource pressure

    /// Injected iOS thermal/power snapshot. The timeline controller owns the
    /// current value; policy functions stay pure so tests can drive the matrix.
    struct ResourcePressure: Equatable, Sendable {
        var thermalState: ProcessInfo.ThermalState
        var isLowPowerModeEnabled: Bool

        static let nominal = ResourcePressure(
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        )
        static let fair = ResourcePressure(
            thermalState: .fair,
            isLowPowerModeEnabled: false
        )
        static let serious = ResourcePressure(
            thermalState: .serious,
            isLowPowerModeEnabled: false
        )
        static let critical = ResourcePressure(
            thermalState: .critical,
            isLowPowerModeEnabled: false
        )

        static func current(processInfo: ProcessInfo = .processInfo) -> ResourcePressure {
            ResourcePressure(
                thermalState: processInfo.thermalState,
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
            )
        }
    }

    /// Coarse work-admission level derived from thermal state and Low Power Mode.
    enum WorkAdmission: Int, Sendable, Comparable {
        case nominal = 0
        case serious = 1
        case critical = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Who is asking for the work. Speculative is runway/prefetch; explicit is
    /// an existing user action such as expansion or full-screen.
    enum WorkConsumer: Sendable, Equatable {
        case speculative
        case visible
        case explicit
    }

    enum DecorativeWork: Sendable, Equatable {
        case syntaxHighlight
        case mermaidDiagram
        case latexDiagram
        case rasterImage
        case offscreenMarkdownParse
    }

    enum DecorativeDecision: Sendable, Equatable {
        case allow
        case reducedDetail
        case deferToPlain
        case refuse
    }

    /// Destination pixel scale for internal raster work. Serious/critical use
    /// half detail so decode/vImage work shrinks rather than moving to another queue.
    static let seriousImageDetailScale: CGFloat = 0.5

    static func workAdmission(for pressure: ResourcePressure) -> WorkAdmission {
        let thermal: WorkAdmission
        switch pressure.thermalState {
        case .nominal, .fair:
            thermal = .nominal
        case .serious:
            thermal = .serious
        case .critical:
            thermal = .critical
        @unknown default:
            thermal = .critical
        }
        if pressure.isLowPowerModeEnabled {
            return max(thermal, .serious)
        }
        return thermal
    }

    static func admitsSpeculativeRunwayWork(for pressure: ResourcePressure) -> Bool {
        workAdmission(for: pressure) == .nominal
    }

    static func imageDetailScale(for pressure: ResourcePressure) -> CGFloat {
        workAdmission(for: pressure) == .nominal ? 1 : seriousImageDetailScale
    }

    static func decision(
        for work: DecorativeWork,
        pressure: ResourcePressure,
        consumer: WorkConsumer
    ) -> DecorativeDecision {
        let admission = workAdmission(for: pressure)
        if consumer == .speculative {
            return admission == .nominal ? .allow : .refuse
        }

        switch work {
        case .offscreenMarkdownParse:
            return admission == .nominal ? .allow : .refuse

        case .rasterImage:
            switch admission {
            case .nominal:
                return .allow
            case .serious:
                return .reducedDetail
            case .critical:
                return consumer == .explicit ? .reducedDetail : .refuse
            }

        case .syntaxHighlight:
            switch admission {
            case .nominal:
                return .allow
            case .serious:
                return .deferToPlain
            case .critical:
                return consumer == .explicit ? .deferToPlain : .refuse
            }

        case .mermaidDiagram, .latexDiagram:
            switch admission {
            case .nominal:
                return .allow
            case .serious:
                return consumer == .explicit ? .allow : .deferToPlain
            case .critical:
                return consumer == .explicit ? .allow : .refuse
            }
        }
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
    ///   - pressure: Injected thermal/power snapshot. Defaults to nominal so
    ///     existing call sites keep current behavior until they pass one.
    ///   - consumer: Visible timeline work vs an explicit user action.
    /// - Returns: The render tier to use.
    static func tier(
        isStreaming: Bool,
        contentKind: ContentKind,
        byteCount: Int,
        lineCount: Int,
        maxLineByteCount: Int = 0,
        pressure: ResourcePressure = .nominal,
        consumer: WorkConsumer = .visible
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

        switch workAdmission(for: pressure) {
        case .nominal:
            break
        case .serious:
            // Plain/live text first. Serious defers syntax-color even on an
            // expanded tool; explicit full-screen/export uses other surfaces.
            switch contentKind {
            case .code, .markdown:
                return .cheap
            default:
                break
            }
        case .critical:
            if consumer != .explicit {
                return .cheap
            }
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

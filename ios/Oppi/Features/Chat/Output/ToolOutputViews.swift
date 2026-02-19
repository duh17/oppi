import Foundation
import SwiftUI

// MARK: - Async Tool Output

/// Renders tool output with async image extraction and ANSI parsing.
///
/// All expensive work (regex scanning, ANSI parsing, image decoding) runs
/// off the main thread via `.task(id:)`. The body only shows cached results.
struct AsyncToolOutput: View {
    let output: String
    let isError: Bool
    var filePath: String? = nil
    var startLine: Int = 1

    @State private var parsed: ParsedToolOutput?

    private var parseKey: String {
        let prefix = String(output.prefix(64))
        let suffix = String(output.suffix(64))
        return "\(output.utf8.count):\(filePath ?? ""):\(prefix):\(suffix)"
    }

    /// Use a full-fidelity fallback while background parsing runs. This keeps
    /// expanded rows visually stable when cells are reused during scrolling.
    private var effectiveParsed: ParsedToolOutput {
        parsed ?? ParsedToolOutput(
            images: [],
            audio: [],
            strippedText: output,
            isReadFile: filePath != nil,
            isReadWithMedia: false,
            structured: nil
        )
    }

    var body: some View {
        let model = effectiveParsed

        Group {
            if model.isReadWithMedia {
                ToolOutputMedia(
                    images: model.images,
                    audio: model.audio,
                    strippedText: model.strippedText,
                    isError: isError
                )
            } else if model.isReadFile, let filePath {
                FileContentView(content: output, filePath: filePath, startLine: startLine)
            } else if let structured = model.structured {
                StructuredToolOutputView(value: structured, isError: isError)
            } else {
                ToolOutputMedia(
                    images: model.images,
                    audio: model.audio,
                    strippedText: model.strippedText,
                    isError: isError
                )
            }
        }
        .transaction { tx in
            tx.animation = nil
        }
        .task(id: parseKey) {
            if let cached = ParsedToolOutputCache.shared.value(forKey: parseKey) {
                parsed = cached
                return
            }

            let output = self.output
            let isReadFile = self.filePath != nil
            let computed = await Task.detached(priority: .userInitiated) {
                ParsedToolOutput.parse(output, isReadFile: isReadFile)
            }.value

            ParsedToolOutputCache.shared.set(computed, forKey: parseKey)
            parsed = computed
        }
    }
}

// MARK: - Parsed Output

/// Pre-parsed tool output — all expensive work done off main thread.
private struct ParsedToolOutput: Sendable {
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
    let strippedText: String
    let isReadFile: Bool
    let isReadWithMedia: Bool
    let structured: JSONValue?

    static func parse(_ output: String, isReadFile: Bool) -> ParsedToolOutput {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = output
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let structured = parseStructuredJSON(strippedText, isReadFile: isReadFile, hasMedia: !images.isEmpty || !audio.isEmpty)

        return ParsedToolOutput(
            images: images,
            audio: audio,
            strippedText: strippedText,
            isReadFile: isReadFile,
            isReadWithMedia: isReadFile && (!images.isEmpty || !audio.isEmpty),
            structured: structured
        )
    }

    private static func parseStructuredJSON(_ text: String, isReadFile: Bool, hasMedia: Bool) -> JSONValue? {
        if isReadFile || hasMedia {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }

        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// In-memory cache for parsed tool output to avoid repeated async re-parsing
/// when expanded rows scroll off/on screen and cells are reused.
private final class ParsedToolOutputCache: @unchecked Sendable {
    static let shared = ParsedToolOutputCache()

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 256
    }

    func value(forKey key: String) -> ParsedToolOutput? {
        cache.object(forKey: key as NSString)?.value
    }

    func set(_ value: ParsedToolOutput, forKey key: String) {
        cache.setObject(Box(value), forKey: key as NSString)
    }

    private final class Box {
        let value: ParsedToolOutput

        init(_ value: ParsedToolOutput) {
            self.value = value
        }
    }
}

// MARK: - Tool Output Media

/// Renders pre-extracted media blocks + ANSI-parsed text.
private struct ToolOutputMedia: View {
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
    let strippedText: String
    let isError: Bool

    @State private var ansiAttributed: AttributedString?

    private var renderText: String {
        String(strippedText.prefix(2000))
    }

    private var fallbackText: String {
        ANSIParser.strip(renderText)
    }

    private var ansiKey: String {
        let prefix = String(renderText.prefix(64))
        let suffix = String(renderText.suffix(64))
        return "\(isError):\(renderText.utf8.count):\(prefix):\(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !strippedText.isEmpty {
                if let ansiAttributed {
                    Text(ansiAttributed)
                        .textSelection(.enabled)
                } else {
                    Text(fallbackText)
                        .font(.caption.monospaced())
                        .foregroundStyle(isError ? .themeRed : .themeFg)
                        .textSelection(.enabled)
                }
            }

            ForEach(images) { image in
                AsyncImageBlob(base64: image.base64, mimeType: image.mimeType)
            }

            ForEach(Array(audio.enumerated()), id: \.offset) { index, clip in
                AsyncAudioBlob(
                    id: "audio-\(index)-\(clip.base64.prefix(24))",
                    base64: clip.base64,
                    mimeType: clip.mimeType
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: ansiKey) {
            guard !renderText.isEmpty else {
                ansiAttributed = nil
                return
            }

            let text = renderText
            let shouldTintError = isError
            ansiAttributed = await Task.detached(priority: .userInitiated) {
                ANSIParser.attributedString(
                    from: text,
                    baseForeground: shouldTintError ? .themeRed : .themeFg
                )
            }.value
        }
        .contextMenu {
            if !strippedText.isEmpty {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = strippedText
                }
            }
        }
    }
}

// MARK: - Structured Tool Output

/// Generic renderer for structured JSON outputs from custom extensions.
private struct StructuredToolOutputView: View {
    let value: JSONValue
    let isError: Bool

    private var prettyJSON: String {
        guard let data = try? prettyEncoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return value.summary(maxLength: 4_000)
        }
        return String(text.prefix(20_000))
    }

    private var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    var body: some View {
        Text(prettyJSON)
            .font(.caption.monospaced())
            .foregroundStyle(isError ? .themeRed : .themeFg)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.themeBgDark)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = prettyJSON
                }
            }
    }
}

// MARK: - Async Image Blob

/// Async image decoder — decodes base64 off main thread.
struct AsyncImageBlob: View {
    let base64: String
    let mimeType: String?

    @State private var decoded: UIImage?
    @State private var decodeFailed = false
    @State private var showFullScreen = false

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { showFullScreen = true }
                    .contextMenu {
                        Button("Copy Image", systemImage: "doc.on.doc") {
                            UIPasteboard.general.image = decoded
                        }
                        Button("Save to Photos", systemImage: "square.and.arrow.down") {
                            PhotoLibrarySaver.save(decoded)
                        }
                        ShareLink(item: Image(uiImage: decoded), preview: SharePreview("Image"))
                    }
                    .fullScreenCover(isPresented: $showFullScreen) {
                        ZoomableImageView(image: decoded)
                    }
            } else if decodeFailed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text("Image preview unavailable")
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                            if let mimeType {
                                Text(mimeType)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.themeComment.opacity(0.7))
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: ImageDecodeCache.decodeKey(for: base64, maxPixelSize: 1600)) {
            decodeFailed = false
            decoded = await Task.detached(priority: .userInitiated) {
                ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600)
            }.value
            if decoded == nil {
                decodeFailed = true
            }
        }
    }
}

// MARK: - Async Audio Blob

/// Async audio decoder + inline playback row for data URI audio blocks.
struct AsyncAudioBlob: View {
    let id: String
    let base64: String
    let mimeType: String?

    @Environment(AudioPlayerService.self) private var audioPlayer

    @State private var decodedData: Data?
    @State private var decodeFailed = false

    private var isLoading: Bool {
        audioPlayer.loadingItemID == id
    }

    private var isPlaying: Bool {
        audioPlayer.playingItemID == id
    }

    private var title: String {
        mimeType ?? "audio"
    }

    private var subtitle: String {
        guard let decodedData else { return "Preparing audio…" }
        return ToolCallFormatting.formatBytes(decodedData.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.themePurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            Spacer()

            if decodeFailed {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if decodedData == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    guard let decodedData else { return }
                    audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.themePurple)
                        } else if isPlaying {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                                .foregroundStyle(.themePurple)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.themeBgHighlight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: base64.prefix(32)) {
            decodeFailed = false
            decodedData = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            }.value
            if decodedData == nil {
                decodeFailed = true
            }
        }
    }
}

// MARK: - Async Diff View

/// Computes LCS diff off main thread, then renders.
struct AsyncDiffView: View {
    let oldText: String
    let newText: String
    let filePath: String?
    var showHeader: Bool = true
    var precomputedLines: [DiffLine]? = nil

    @State private var ready = false

    var body: some View {
        if ready {
            DiffContentView(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                showHeader: showHeader,
                precomputedLines: precomputedLines
            )
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(precomputedLines == nil ? "Computing diff…" : "Loading diff…")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .padding(8)
            .task {
                if precomputedLines == nil {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                ready = true
            }
        }
    }
}

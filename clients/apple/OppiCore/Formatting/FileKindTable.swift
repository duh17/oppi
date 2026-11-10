import Foundation

/// The one table of file extensions the app knows: which kind each opens as,
/// the MIME type the media players and image decoders are told, and whether
/// the viewer paints it by loading its text into a web view.
///
/// Extensions not listed here are source code (`SyntaxLanguage.detect`) or
/// plain text. `FileKind.detect` is the entry point for a path; the lookups
/// below serve callers that hold only an extension.
enum FileKindTable {
    struct Row: Sendable {
        let extensions: [String]
        let kind: FileKind
        /// What a player or decoder is told when it has only the extension.
        let mimeType: String?
        /// The viewer loads the file's text into a web view (HTML and SVG).
        let rendersAsWebString: Bool

        init(_ extensions: [String], _ kind: FileKind, mimeType: String? = nil, rendersAsWebString: Bool = false) {
            self.extensions = extensions
            self.kind = kind
            self.mimeType = mimeType
            self.rendersAsWebString = rendersAsWebString
        }
    }

    static let rows: [Row] = [
        // Document renderers
        Row(["tex", "latex"], .latex),
        Row(["org"], .orgMode),
        Row(["mmd", "mermaid"], .mermaid),
        Row(["dot", "gv"], .graphviz),
        Row(["md", "mdx", "markdown"], .markdown),
        Row(["html", "htm"], .html, rendersAsWebString: true),
        Row(["csv"], .csv),
        Row(["tsv"], .tsv),
        Row(["geojson"], .geojson),
        Row(["topojson"], .topojson),

        // Images
        Row(["jpg", "jpeg"], .image, mimeType: "image/jpeg"),
        Row(["png"], .image, mimeType: "image/png"),
        Row(["gif"], .image, mimeType: "image/gif"),
        Row(["webp"], .image, mimeType: "image/webp"),
        Row(["ico"], .image, mimeType: "image/x-icon"),
        Row(["bmp"], .image, mimeType: "image/bmp"),
        Row(["tif", "tiff"], .image, mimeType: "image/tiff"),
        Row(["heic"], .image, mimeType: "image/heic"),
        Row(["heif"], .image, mimeType: "image/heif"),
        Row(["svg"], .image, mimeType: "image/svg+xml", rendersAsWebString: true),

        // Audio
        Row(["wav"], .audio, mimeType: "audio/wav"),
        Row(["mp3"], .audio, mimeType: "audio/mpeg"),
        Row(["m4a", "m4b", "aac"], .audio, mimeType: "audio/mp4"),
        Row(["flac"], .audio, mimeType: "audio/flac"),
        Row(["ogg"], .audio, mimeType: "audio/ogg"),
        Row(["opus"], .audio, mimeType: "audio/opus"),
        Row(["caf"], .audio, mimeType: "audio/x-caf"),
        // Audio the app can tell a player about but does not open as audio.
        Row(["aif", "aiff", "aifc"], .plain, mimeType: "audio/aiff"),
        Row(["oga"], .plain, mimeType: "audio/ogg"),

        // Video
        Row(["mp4", "m4v"], .video, mimeType: "video/mp4"),
        Row(["mov"], .video, mimeType: "video/quicktime"),
        Row(["webm"], .video, mimeType: "video/webm"),
        Row(["avi"], .video, mimeType: "video/x-msvideo"),

        // Documents and scenes the phone renders itself
        Row(["pdf"], .pdf),
        Row(["usdz"], .usdz),
        Row(["epub"], .book),

        // Binary
        Row(["bin", "gz", "zip", "tar", "bz2", "xz", "7z", "rar",
             "dmg", "iso", "img",
             "car", "nib", "mobileprovision", "p12", "cer",
             "dylib", "so", "a", "o", "exe", "dll",
             "woff", "woff2", "ttf", "otf", "eot"], .binary),
    ]

    private static let rowsByExtension: [String: Row] = {
        var table: [String: Row] = [:]
        for row in rows {
            for ext in row.extensions where table[ext] == nil {
                table[ext] = row
            }
        }
        return table
    }()

    /// The row for a lowercased extension without its dot.
    static func row(forExtension ext: String) -> Row? {
        rowsByExtension[ext]
    }

    /// The MIME type for an extension, in any case, with or without the player's
    /// category: `image/`, `audio/`, or `video/`.
    static func mimeType(forExtension ext: String?, prefix: String) -> String? {
        guard let mime = rowsByExtension[(ext ?? "").lowercased()]?.mimeType, mime.hasPrefix(prefix) else {
            return nil
        }
        return mime
    }

    /// Whether the viewer paints this path by loading its text into a web view.
    static func rendersAsWebString(path: String) -> Bool {
        rowsByExtension[(path as NSString).pathExtension.lowercased()]?.rendersAsWebString ?? false
    }
}

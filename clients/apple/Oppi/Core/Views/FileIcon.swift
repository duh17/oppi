import SwiftUI
import UIKit

/// SF Symbol and color for a file path, based on extension or well-known filename.
///
/// Used in review rows, session changes, and anywhere a file needs a
/// recognizable icon at a glance. Colors are kept to a handful of buckets
/// — the icon shape does the heavy lifting for identification.
enum FileIconTint: Equatable, Sendable {
    case comment, blue, cyan, orange, yellow, red, purple, green

    var style: ThemeShapeStyle {
        switch self {
        case .comment: .themeComment
        case .blue: .themeBlue
        case .cyan: .themeCyan
        case .orange: .themeOrange
        case .yellow: .themeYellow
        case .red: .themeRed
        case .purple: .themePurple
        case .green: .themeGreen
        }
    }

    var snapshotColor: Color {
        switch self {
        case .comment: .themeComment
        case .blue: .themeBlue
        case .cyan: .themeCyan
        case .orange: .themeOrange
        case .yellow: .themeYellow
        case .red: .themeRed
        case .purple: .themePurple
        case .green: .themeGreen
        }
    }
}

struct FileIcon: Equatable, Sendable {
    let symbolName: String
    let tint: FileIconTint
    /// Asset catalog image name. When set, preferred over `symbolName`.
    let assetName: String?

    var color: Color { tint.snapshotColor }

    init(symbolName: String, tint: FileIconTint, assetName: String? = nil) {
        self.symbolName = symbolName
        self.tint = tint
        self.assetName = assetName
    }

    /// Returns a SwiftUI Image using the asset catalog icon when available,
    /// falling back to the SF Symbol.
    var image: Image {
        if let assetName, UIImage(named: assetName) != nil {
            return Image(assetName)
                .resizable()
        }
        return Image(systemName: symbolName)
    }

    /// Whether this icon uses a custom asset (not an SF Symbol).
    var isAssetImage: Bool {
        if let assetName, UIImage(named: assetName) != nil {
            return true
        }
        return false
    }

    /// Returns a properly-sized icon view with correct aspect ratio.
    ///
    /// Asset images get `.scaledToFit()` so they don't stretch to fill the frame.
    /// SF Symbols get font-based sizing. The `size` sets both width and height of the frame.
    ///
    /// For icons inside a larger background (e.g. 28pt rounded rect), use a smaller `size`
    /// for the icon and add an outer `.frame()` + `.background()`:
    /// ```
    /// icon.iconView(size: 18)
    ///     .frame(width: 28, height: 28)
    ///     .background(...)
    /// ```
    @ViewBuilder
    func iconView(size: CGFloat, font: Font? = nil) -> some View {
        if isAssetImage {
            image  // .resizable() already applied
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(tint.style)
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbolName)
                .font(font ?? .system(size: max(9, size * 0.6), weight: .medium))
                .foregroundStyle(tint.style)
                .frame(width: size, height: size)
        }
    }

    /// Resolve icon for a file path. Checks well-known filenames first,
    /// then extension, then falls back to a generic doc icon.
    static func forPath(_ path: String) -> Self {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        // Well-known filenames (checked first — overrides extension)
        if let icon = wellKnownFilename(filename) { return icon }

        // Dotfiles and hidden configs
        if filename.hasPrefix("."), let icon = dotfileIcon(filename) { return icon }

        // Extension-based
        if !ext.isEmpty, let icon = extensionIcon(ext) { return icon }

        return Self(symbolName: "doc.text", tint: .comment)
    }

    // MARK: - Well-Known Filenames

    private static func wellKnownFilename(_ name: String) -> Self? {
        switch name {
        // Package manifests
        case "package.swift", "package.resolved",
             "package.json", "composer.json",
             "podfile", "gemfile", "cargo.toml",
             "go.mod", "pubspec.yaml", "build.gradle",
             "build.gradle.kts", "requirements.txt",
             "setup.py", "pyproject.toml", "pipfile":
            return Self(symbolName: "shippingbox.fill", tint: .blue)

        // Lock files
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
             "podfile.lock", "gemfile.lock", "cargo.lock",
             "go.sum", "composer.lock", "pipfile.lock",
             "shrinkwrap.yaml", "packages.resolved":
            return Self(symbolName: "lock.fill", tint: .comment)

        // Build / project
        case "dockerfile", "containerfile":
            return Self(symbolName: "shippingbox.fill", tint: .cyan)
        case "makefile", "gnumakefile", "cmakelists.txt",
             "justfile", "rakefile", "gulpfile.js",
             "gruntfile.js", "webpack.config.js",
             "rollup.config.js", "vite.config.ts",
             "vite.config.js":
            return Self(symbolName: "hammer.fill", tint: .orange)

        // Project config
        case "project.yml", "project.yaml", "project.pbxproj",
             "xcodeproj", "xcworkspace":
            return Self(symbolName: "wrench.and.screwdriver", tint: .comment)

        // Tool config (JSON-based)
        case "tsconfig.json", "jsconfig.json",
             "biome.json", "deno.json", "deno.jsonc",
             ".swiftlint.yml", "swiftlint.yml",
             "babel.config.js", "babel.config.json",
             ".babelrc", ".browserslistrc":
            return Self(symbolName: "gearshape.fill", tint: .comment)

        // License
        case "license", "licence", "license.md", "licence.md",
             "license.txt", "licence.txt":
            return Self(symbolName: "doc.text", tint: .comment)

        default:
            return nil
        }
    }

    // MARK: - Dotfiles / Hidden Configs

    private static func dotfileIcon(_ name: String) -> Self? {
        switch name {
        case ".gitignore", ".dockerignore", ".npmignore", ".slugignore":
            return Self(symbolName: "eye.slash", tint: .comment)
        case ".gitattributes", ".gitmodules":
            return Self(symbolName: "arrow.triangle.branch", tint: .comment)
        case ".env", ".env.local", ".env.development",
             ".env.production", ".env.test", ".env.example":
            return Self(symbolName: "key.fill", tint: .yellow)
        case ".editorconfig", ".prettierrc", ".prettierrc.json",
             ".prettierrc.yml", ".eslintrc", ".eslintrc.json",
             ".eslintrc.yml", ".eslintrc.js":
            return Self(symbolName: "gearshape.fill", tint: .comment)
        default:
            return nil
        }
    }

    // MARK: - Extension-Based

    private static func extensionIcon(_ ext: String) -> Self? {
        switch ext {
        // Swift
        case "swift":
            return Self(symbolName: "swift", tint: .orange, assetName: "lang-swift")

        // TypeScript
        case "ts", "tsx", "mts", "cts":
            return Self(symbolName: "t.square.fill", tint: .blue, assetName: "lang-typescript")

        // JavaScript
        case "js", "jsx", "mjs", "cjs":
            return Self(symbolName: "j.square.fill", tint: .yellow, assetName: "lang-nodejs")

        // Python
        case "py", "pyi", "pyw":
            return Self(symbolName: "p.square.fill", tint: .cyan, assetName: "lang-python")

        // Go
        case "go":
            return Self(symbolName: "g.square.fill", tint: .cyan, assetName: "lang-go")

        // Rust
        case "rs":
            return Self(symbolName: "r.square.fill", tint: .orange, assetName: "lang-rust")

        // Ruby
        case "rb", "erb":
            return Self(symbolName: "r.square.fill", tint: .red, assetName: "lang-ruby")

        // Shell
        case "sh", "bash", "zsh", "fish", "ksh", "csh":
            return Self(symbolName: "terminal.fill", tint: .green)

        // C
        case "c", "h":
            return Self(symbolName: "c.square.fill", tint: .cyan)

        // C++
        case "cpp", "cc", "cxx", "hpp", "hxx", "hh":
            return Self(symbolName: "c.square.fill", tint: .purple)

        // Java
        case "java":
            return Self(symbolName: "cup.and.saucer.fill", tint: .red)

        // Kotlin
        case "kt", "kts":
            return Self(symbolName: "k.square.fill", tint: .purple)

        // Zig
        case "zig":
            return Self(symbolName: "z.square.fill", tint: .orange, assetName: "lang-zig")

        // HTML / XML / markup
        case "html", "htm", "xml", "xhtml", "svg", "plist", "xib",
             "storyboard":
            return Self(symbolName: "chevron.left.forwardslash.chevron.right", tint: .orange)

        // CSS
        case "css", "scss", "less", "sass":
            return Self(symbolName: "paintbrush.fill", tint: .blue)

        // JSON
        case "json", "jsonl", "geojson", "jsonc":
            return Self(symbolName: "curlybraces", tint: .yellow)

        // YAML
        case "yaml", "yml":
            return Self(symbolName: "list.bullet.rectangle", tint: .red)

        // TOML
        case "toml":
            return Self(symbolName: "list.bullet.rectangle", tint: .comment)

        // SQL
        case "sql", "sqlite", "db":
            return Self(symbolName: "cylinder.fill", tint: .blue)

        // Markdown
        case "md", "mdx", "markdown", "rst":
            return Self(symbolName: "doc.richtext", tint: .blue, assetName: "lang-markdown")

        // Images
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp",
             "tiff", "tif", "heic", "heif", "avif":
            return Self(symbolName: "photo.fill", tint: .purple)

        // Audio
        case "wav", "mp3", "m4a", "aac", "flac", "ogg", "opus",
             "caf", "aiff", "wma":
            return Self(symbolName: "waveform", tint: .purple)

        // Video
        case "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv",
             "flv":
            return Self(symbolName: "film", tint: .purple)

        // PDF
        case "pdf":
            return Self(symbolName: "doc.richtext", tint: .red)

        // Archives
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz":
            return Self(symbolName: "doc.zipper", tint: .comment)

        // Fonts
        case "ttf", "otf", "woff", "woff2":
            return Self(symbolName: "textformat", tint: .purple)

        // Certificates / keys
        case "pem", "cert", "crt", "cer", "p12", "pfx":
            return Self(symbolName: "lock.shield.fill", tint: .yellow)

        // Protobuf
        case "proto":
            return Self(symbolName: "network", tint: .cyan)

        // GraphQL
        case "graphql", "gql":
            return Self(symbolName: "point.3.connected.trianglepath.dotted", tint: .purple)

        // Env / INI
        case "env", "ini", "cfg", "conf":
            return Self(symbolName: "gearshape.fill", tint: .comment)

        // Log
        case "log":
            return Self(symbolName: "doc.text.magnifyingglass", tint: .comment)

        // Diff / patch
        case "diff", "patch":
            return Self(symbolName: "plus.forwardslash.minus", tint: .green)

        // Text
        case "txt", "text":
            return Self(symbolName: "doc.text", tint: .comment)

        // Wasm
        case "wasm", "wat":
            return Self(symbolName: "cpu", tint: .purple)

        // R
        case "r", "rmd":
            return Self(symbolName: "r.square.fill", tint: .blue)

        // Lua
        case "lua":
            return Self(symbolName: "l.square.fill", tint: .blue)

        // Dart
        case "dart":
            return Self(symbolName: "d.square.fill", tint: .cyan)

        // Elixir / Erlang
        case "ex", "exs", "erl", "hrl":
            return Self(symbolName: "e.square.fill", tint: .purple)

        // Scala
        case "scala", "sc":
            return Self(symbolName: "s.square.fill", tint: .red)

        // Haskell
        case "hs", "lhs":
            return Self(symbolName: "h.square.fill", tint: .purple)

        // Perl
        case "pl", "pm":
            return Self(symbolName: "p.square.fill", tint: .cyan)

        default:
            return nil
        }
    }
}

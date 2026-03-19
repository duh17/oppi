import SwiftUI

/// SF Symbol and color for a file path, based on extension or well-known filename.
///
/// Used in review rows, session changes, and anywhere a file needs a
/// recognizable icon at a glance. Colors are kept to a handful of buckets
/// — the icon shape does the heavy lifting for identification.
struct FileIcon: Equatable, Sendable {
    let symbolName: String
    let color: Color

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

        return Self(symbolName: "doc.text", color: .themeComment)
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
            return Self(symbolName: "shippingbox.fill", color: .themeBlue)

        // Lock files
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
             "podfile.lock", "gemfile.lock", "cargo.lock",
             "go.sum", "composer.lock", "pipfile.lock",
             "shrinkwrap.yaml", "packages.resolved":
            return Self(symbolName: "lock.fill", color: .themeComment)

        // Build / project
        case "dockerfile", "containerfile":
            return Self(symbolName: "shippingbox.fill", color: .themeCyan)
        case "makefile", "gnumakefile", "cmakelists.txt",
             "justfile", "rakefile", "gulpfile.js",
             "gruntfile.js", "webpack.config.js",
             "rollup.config.js", "vite.config.ts",
             "vite.config.js":
            return Self(symbolName: "hammer.fill", color: .themeOrange)

        // Project config
        case "project.yml", "project.yaml", "project.pbxproj",
             "xcodeproj", "xcworkspace":
            return Self(symbolName: "wrench.and.screwdriver", color: .themeComment)

        // Tool config (JSON-based)
        case "tsconfig.json", "jsconfig.json",
             "biome.json", "deno.json", "deno.jsonc",
             ".swiftlint.yml", "swiftlint.yml",
             "babel.config.js", "babel.config.json",
             ".babelrc", ".browserslistrc":
            return Self(symbolName: "gearshape.fill", color: .themeComment)

        // License
        case "license", "licence", "license.md", "licence.md",
             "license.txt", "licence.txt":
            return Self(symbolName: "doc.text", color: .themeComment)

        default:
            return nil
        }
    }

    // MARK: - Dotfiles / Hidden Configs

    private static func dotfileIcon(_ name: String) -> Self? {
        switch name {
        case ".gitignore", ".dockerignore", ".npmignore", ".slugignore":
            return Self(symbolName: "eye.slash", color: .themeComment)
        case ".gitattributes", ".gitmodules":
            return Self(symbolName: "arrow.triangle.branch", color: .themeComment)
        case ".env", ".env.local", ".env.development",
             ".env.production", ".env.test", ".env.example":
            return Self(symbolName: "key.fill", color: .themeYellow)
        case ".editorconfig", ".prettierrc", ".prettierrc.json",
             ".prettierrc.yml", ".eslintrc", ".eslintrc.json",
             ".eslintrc.yml", ".eslintrc.js":
            return Self(symbolName: "gearshape.fill", color: .themeComment)
        default:
            return nil
        }
    }

    // MARK: - Extension-Based

    private static func extensionIcon(_ ext: String) -> Self? {
        switch ext {
        // Swift
        case "swift":
            return Self(symbolName: "swift", color: .themeOrange)

        // TypeScript
        case "ts", "tsx", "mts", "cts":
            return Self(symbolName: "t.square.fill", color: .themeBlue)

        // JavaScript
        case "js", "jsx", "mjs", "cjs":
            return Self(symbolName: "j.square.fill", color: .themeYellow)

        // Python
        case "py", "pyi", "pyw":
            return Self(symbolName: "p.square.fill", color: .themeCyan)

        // Go
        case "go":
            return Self(symbolName: "g.square.fill", color: .themeCyan)

        // Rust
        case "rs":
            return Self(symbolName: "r.square.fill", color: .themeOrange)

        // Ruby
        case "rb", "erb":
            return Self(symbolName: "r.square.fill", color: .themeRed)

        // Shell
        case "sh", "bash", "zsh", "fish", "ksh", "csh":
            return Self(symbolName: "terminal.fill", color: .themeGreen)

        // C
        case "c", "h":
            return Self(symbolName: "c.square.fill", color: .themeCyan)

        // C++
        case "cpp", "cc", "cxx", "hpp", "hxx", "hh":
            return Self(symbolName: "c.square.fill", color: .themePurple)

        // Java
        case "java":
            return Self(symbolName: "cup.and.saucer.fill", color: .themeRed)

        // Kotlin
        case "kt", "kts":
            return Self(symbolName: "k.square.fill", color: .themePurple)

        // Zig
        case "zig":
            return Self(symbolName: "z.square.fill", color: .themeOrange)

        // HTML / XML / markup
        case "html", "htm", "xml", "xhtml", "svg", "plist", "xib",
             "storyboard":
            return Self(symbolName: "chevron.left.forwardslash.chevron.right", color: .themeOrange)

        // CSS
        case "css", "scss", "less", "sass":
            return Self(symbolName: "paintbrush.fill", color: .themeBlue)

        // JSON
        case "json", "jsonl", "geojson", "jsonc":
            return Self(symbolName: "curlybraces", color: .themeYellow)

        // YAML
        case "yaml", "yml":
            return Self(symbolName: "list.bullet.rectangle", color: .themeRed)

        // TOML
        case "toml":
            return Self(symbolName: "list.bullet.rectangle", color: .themeComment)

        // SQL
        case "sql", "sqlite", "db":
            return Self(symbolName: "cylinder.fill", color: .themeBlue)

        // Markdown
        case "md", "mdx", "markdown", "rst":
            return Self(symbolName: "doc.richtext", color: .themeBlue)

        // Images
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp",
             "tiff", "tif", "heic", "heif", "avif":
            return Self(symbolName: "photo.fill", color: .themePurple)

        // Audio
        case "wav", "mp3", "m4a", "aac", "flac", "ogg", "opus",
             "caf", "aiff", "wma":
            return Self(symbolName: "waveform", color: .themePurple)

        // Video
        case "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv",
             "flv":
            return Self(symbolName: "film", color: .themePurple)

        // PDF
        case "pdf":
            return Self(symbolName: "doc.richtext", color: .themeRed)

        // Archives
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz":
            return Self(symbolName: "doc.zipper", color: .themeComment)

        // Fonts
        case "ttf", "otf", "woff", "woff2":
            return Self(symbolName: "textformat", color: .themePurple)

        // Certificates / keys
        case "pem", "cert", "crt", "cer", "p12", "pfx":
            return Self(symbolName: "lock.shield.fill", color: .themeYellow)

        // Protobuf
        case "proto":
            return Self(symbolName: "network", color: .themeCyan)

        // GraphQL
        case "graphql", "gql":
            return Self(symbolName: "point.3.connected.trianglepath.dotted", color: .themePurple)

        // Env / INI
        case "env", "ini", "cfg", "conf":
            return Self(symbolName: "gearshape.fill", color: .themeComment)

        // Log
        case "log":
            return Self(symbolName: "doc.text.magnifyingglass", color: .themeComment)

        // Diff / patch
        case "diff", "patch":
            return Self(symbolName: "plus.forwardslash.minus", color: .themeGreen)

        // Text
        case "txt", "text":
            return Self(symbolName: "doc.text", color: .themeComment)

        // Wasm
        case "wasm", "wat":
            return Self(symbolName: "cpu", color: .themePurple)

        // R
        case "r", "rmd":
            return Self(symbolName: "r.square.fill", color: .themeBlue)

        // Lua
        case "lua":
            return Self(symbolName: "l.square.fill", color: .themeBlue)

        // Dart
        case "dart":
            return Self(symbolName: "d.square.fill", color: .themeCyan)

        // Elixir / Erlang
        case "ex", "exs", "erl", "hrl":
            return Self(symbolName: "e.square.fill", color: .themePurple)

        // Scala
        case "scala", "sc":
            return Self(symbolName: "s.square.fill", color: .themeRed)

        // Haskell
        case "hs", "lhs":
            return Self(symbolName: "h.square.fill", color: .themePurple)

        // Perl
        case "pl", "pm":
            return Self(symbolName: "p.square.fill", color: .themeCyan)

        default:
            return nil
        }
    }
}

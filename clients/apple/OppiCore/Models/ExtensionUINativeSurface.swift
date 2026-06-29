import Foundation

struct ExtensionUINativeSurface: Sendable, Equatable, Identifiable, Decodable {
    let version: Int
    let id: String
    let source: String
    let presentation: ExtensionUINativePresentation
    let blocks: [ExtensionUINativeBlock]
    let fallback: ExtensionUINativeFallback?

    var hasVisibleContent: Bool {
        hasRenderableContent
    }

    var nativeDisplayBlocks: [ExtensionUINativeBlock] {
        blocks.compactMap(\.nativeDisplayBlock)
    }

    var fallbackDisplayLines: [String] {
        if let lines = fallback?.lines {
            let normalizedLines = lines
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !normalizedLines.isEmpty {
                return normalizedLines
            }
        }

        let fallbackText = fallback?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackText.isEmpty {
            return fallbackText.components(separatedBy: .newlines)
        }

        guard !blocks.isEmpty, nativeDisplayBlocks.isEmpty else {
            return []
        }

        let blockTypes = Array(Set(blocks.flatMap(\.nonDisplayableFallbackIdentities))).sorted()
        let suffix = blockTypes.isEmpty ? "" : ": \(blockTypes.joined(separator: ", "))"
        return ["Unsupported extension surface\(suffix)"]
    }

    var hasRenderableContent: Bool {
        !nativeDisplayBlocks.isEmpty || !fallbackDisplayLines.isEmpty
    }
}

struct ExtensionUINativePresentation: Sendable, Equatable, Decodable {
    let style: String
    let title: String?
    let subtitle: String?
}

struct ExtensionUINativeFallback: Sendable, Equatable, Decodable {
    let text: String?
    let lines: [String]?
}

struct ExtensionUIAccessibility: Sendable, Equatable, Decodable {
    let label: String?
    let value: String?
    let hint: String?
}

struct ExtensionUITextSpan: Sendable, Equatable, Decodable {
    let text: String
    let role: String?
    let traits: [String]?
    let link: String?
}

struct ExtensionUIActivityRow: Sendable, Equatable, Decodable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let detail: String?
    let state: String?
    let progress: Double?
    let link: String?
    let children: [ExtensionUIActivityRow]?
}

struct ExtensionUIBlockBase: Sendable, Equatable {
    let id: String?
    let accessibility: ExtensionUIAccessibility?
}

enum ExtensionUINativeBlock: Sendable, Equatable, Decodable, Identifiable {
    case text(base: ExtensionUIBlockBase, spans: [ExtensionUITextSpan])
    case markdown(base: ExtensionUIBlockBase, markdown: String)
    case section(base: ExtensionUIBlockBase, title: String?, subtitle: String?, blocks: [ExtensionUINativeBlock])
    case activityList(base: ExtensionUIBlockBase, rows: [ExtensionUIActivityRow])
    case progress(base: ExtensionUIBlockBase, label: String?, value: Double?, indeterminate: Bool?)
    case terminal(base: ExtensionUIBlockBase, lines: [[ExtensionUITextSpan]])
    case code(base: ExtensionUIBlockBase, language: String?, text: String)
    case divider(base: ExtensionUIBlockBase)
    case spacer(base: ExtensionUIBlockBase, size: String?)
    case unsupported(base: ExtensionUIBlockBase, type: String?)

    var id: String {
        switch self {
        case .text(let base, _),
             .markdown(let base, _),
             .section(let base, _, _, _),
             .activityList(let base, _),
             .progress(let base, _, _, _),
             .terminal(let base, _),
             .code(let base, _, _),
             .divider(let base),
             .spacer(let base, _),
             .unsupported(let base, _):
            return base.id ?? fallbackIdentity
        }
    }

    var fallbackIdentity: String {
        switch self {
        case .text: return "text"
        case .markdown: return "markdown"
        case .section: return "section"
        case .activityList: return "activityList"
        case .progress: return "progress"
        case .terminal: return "terminal"
        case .code: return "code"
        case .divider: return "divider"
        case .spacer: return "spacer"
        case .unsupported(_, let type): return type ?? "unsupported"
        }
    }

    var accessibility: ExtensionUIAccessibility? {
        switch self {
        case .text(let base, _),
             .markdown(let base, _),
             .section(let base, _, _, _),
             .activityList(let base, _),
             .progress(let base, _, _, _),
             .terminal(let base, _),
             .code(let base, _, _),
             .divider(let base),
             .spacer(let base, _),
             .unsupported(let base, _):
            return base.accessibility
        }
    }

    var nativeDisplayBlock: ExtensionUINativeBlock? {
        switch self {
        case .section(let base, let title, let subtitle, let blocks):
            let displayableChildren = blocks.compactMap(\.nativeDisplayBlock)
            let hasHeader = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard hasHeader || !displayableChildren.isEmpty else { return nil }
            return .section(
                base: base,
                title: title,
                subtitle: subtitle,
                blocks: displayableChildren
            )
        case .unsupported:
            return nil
        default:
            return self
        }
    }

    var isNativeDisplayable: Bool {
        nativeDisplayBlock != nil
    }

    var nonDisplayableFallbackIdentities: [String] {
        switch self {
        case .section(_, let title, let subtitle, let blocks):
            if nativeDisplayBlock != nil {
                return []
            }
            let childIdentities = blocks.flatMap(\.nonDisplayableFallbackIdentities)
            if !childIdentities.isEmpty {
                return childIdentities
            }
            let hasHeader = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasHeader ? [] : [fallbackIdentity]
        case .unsupported:
            return [fallbackIdentity]
        default:
            return []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, accessibility
        case spans, markdown, title, subtitle, blocks
        case rows, label, value, indeterminate, lines
        case language, text, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type)
        let base = ExtensionUIBlockBase(
            id: try c.decodeIfPresent(String.self, forKey: .id),
            accessibility: try c.decodeIfPresent(ExtensionUIAccessibility.self, forKey: .accessibility)
        )

        switch type {
        case "text":
            self = .text(base: base, spans: (try? c.decode([ExtensionUITextSpan].self, forKey: .spans)) ?? [])
        case "markdown":
            self = .markdown(base: base, markdown: (try? c.decode(String.self, forKey: .markdown)) ?? "")
        case "section":
            self = .section(
                base: base,
                title: try c.decodeIfPresent(String.self, forKey: .title),
                subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                blocks: (try? c.decode([ExtensionUINativeBlock].self, forKey: .blocks)) ?? []
            )
        case "activityList":
            self = .activityList(base: base, rows: (try? c.decode([ExtensionUIActivityRow].self, forKey: .rows)) ?? [])
        case "progress":
            self = .progress(
                base: base,
                label: try c.decodeIfPresent(String.self, forKey: .label),
                value: try c.decodeIfPresent(Double.self, forKey: .value),
                indeterminate: try c.decodeIfPresent(Bool.self, forKey: .indeterminate)
            )
        case "terminal":
            self = .terminal(base: base, lines: (try? c.decode([[ExtensionUITextSpan]].self, forKey: .lines)) ?? [])
        case "code":
            self = .code(
                base: base,
                language: try c.decodeIfPresent(String.self, forKey: .language),
                text: (try? c.decode(String.self, forKey: .text)) ?? ""
            )
        case "divider":
            self = .divider(base: base)
        case "spacer":
            self = .spacer(base: base, size: try c.decodeIfPresent(String.self, forKey: .size))
        default:
            self = .unsupported(base: base, type: type)
        }
    }
}

import Foundation

/// Server-authored origin for a server-global Pi resource.
///
/// The server owns this classification so clients never infer it from a path.
enum ServerResourceProvenanceKind: String, Codable, Sendable, Equatable {
    case builtIn
    case piAgent
    case agents
    case userSettings
    case package
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ServerResourceProvenance: Codable, Sendable, Equatable {
    let kind: ServerResourceProvenanceKind
    let label: String
}

enum ServerSkillState: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ServerSkillSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
    let provenance: ServerResourceProvenance
    let path: String?
    /// Safe package identity supplied by the server. Never derive this from a path.
    let packageName: String?
    let state: ServerSkillState
    let loadError: String?
    let warnings: [String]
    /// Server-authoritative capability; never infer editability from a path.
    let editable: Bool

    init(
        id: String,
        name: String,
        description: String,
        provenance: ServerResourceProvenance,
        path: String?,
        packageName: String? = nil,
        state: ServerSkillState,
        loadError: String?,
        warnings: [String],
        editable: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.provenance = provenance
        self.path = path
        self.packageName = packageName
        self.state = state
        self.loadError = loadError
        self.warnings = warnings
        self.editable = editable
    }
}

struct ServerSkillDetail: Codable, Sendable, Equatable {
    let summary: ServerSkillSummary
    let skillMarkdown: String
    let files: [String]
}

struct ServerSkillsCatalog: Codable, Sendable, Equatable {
    let skills: [ServerSkillSummary]
}

enum ServerExtensionKind: String, Codable, Sendable, Equatable {
    case builtIn
    case file
    case directory
    case package
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ServerToolSummary: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let description: String?
    let defaultEnabled: Bool?

    var id: String { name }

    init(name: String, description: String? = nil, defaultEnabled: Bool? = nil) {
        self.name = name
        self.description = description
        self.defaultEnabled = defaultEnabled
    }
}

enum ServerExtensionState: String, Codable, Sendable, Equatable {
    case on
    case off
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ServerExtensionSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let kind: ServerExtensionKind
    let provenance: ServerResourceProvenance
    let path: String?
    /// Safe package identity supplied by the server. Never derive this from a path.
    let packageName: String?
    let state: ServerExtensionState
    let loadError: String?
    let warnings: [String]
    let isRemovable: Bool
    let contributedTools: [String]?
    let contributedToolDetails: [ServerToolSummary]?
    /// A plugin, a classic Pi extension, or both. Absent from servers that predate plugins.
    let kinds: [ServerExtensionRowKind]?
    /// The layer the row loads from. Absent from servers that predate plugins.
    let source: ServerExtensionSource?
    /// The row's plugin, when it is one.
    let plugin: ServerPluginSummary?

    init(
        id: String,
        name: String,
        description: String?,
        kind: ServerExtensionKind,
        provenance: ServerResourceProvenance,
        path: String?,
        packageName: String? = nil,
        state: ServerExtensionState,
        loadError: String?,
        warnings: [String],
        isRemovable: Bool,
        contributedTools: [String]? = nil,
        contributedToolDetails: [ServerToolSummary]? = nil,
        kinds: [ServerExtensionRowKind]? = nil,
        source: ServerExtensionSource? = nil,
        plugin: ServerPluginSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.provenance = provenance
        self.path = path
        self.packageName = packageName
        self.state = state
        self.loadError = loadError
        self.warnings = warnings
        self.isRemovable = isRemovable
        self.contributedTools = contributedTools
        self.contributedToolDetails = contributedToolDetails
        self.kinds = kinds
        self.source = source
        self.plugin = plugin
    }
}

extension ServerExtensionSummary {
    /// A classic Pi extension (perhaps also a plugin): what a classic Pi session, and so an
    /// Agent's extension selection, can load. A server that predates plugins lists only those.
    var isPiExtension: Bool { kinds?.contains(.piExtension) ?? true }

    /// Shipped with the server. A server that predates plugins says so only in `kind`.
    var isBuiltIn: Bool { source.map { $0 == .builtIn } ?? (kind == .builtIn) }
}

/// What an extension-list row is: a plugin (durable sessions), a classic Pi extension, or both.
enum ServerExtensionRowKind: String, Codable, Sendable, Equatable {
    case plugin
    case piExtension = "pi-extension"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The layer an extension-list row loads from.
enum ServerExtensionSource: String, Codable, Sendable, Equatable {
    case builtIn = "built-in"
    case owner
    case project
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A plugin as the server's plugin host holds it, and what its extension contributes.
struct ServerPluginSummary: Codable, Sendable, Equatable {
    /// Its installed extension's name; nil when it never loaded.
    let extensionName: String?
    /// A built-in the server cannot run without: it cannot be disabled.
    let required: Bool
    /// Whether workspace sessions select it.
    let enabled: Bool
    let runtimes: [String]
    let tools: [String]
    let hooks: [ServerPluginHook]
    let sections: [String]
    let wraps: [ServerPluginWrap]
    let tasks: [String]
    /// Why its last load or reload failed.
    let loadError: String?
    /// A failed reload left its previous code running.
    let kept: Bool

    private enum CodingKeys: String, CodingKey {
        case extensionName = "extension"
        case required, enabled, runtimes, tools, hooks, sections, wraps, tasks, loadError, kept
    }
}

extension ServerPluginSummary {
    /// Lenient: a field a later server leaves out decodes as empty or false instead of failing the
    /// whole extension list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            extensionName: try container.decodeIfPresent(String.self, forKey: .extensionName),
            required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? false,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            runtimes: try container.decodeIfPresent([String].self, forKey: .runtimes) ?? [],
            tools: try container.decodeIfPresent([String].self, forKey: .tools) ?? [],
            hooks: try container.decodeIfPresent([ServerPluginHook].self, forKey: .hooks) ?? [],
            sections: try container.decodeIfPresent([String].self, forKey: .sections) ?? [],
            wraps: try container.decodeIfPresent([ServerPluginWrap].self, forKey: .wraps) ?? [],
            tasks: try container.decodeIfPresent([String].self, forKey: .tasks) ?? [],
            loadError: try container.decodeIfPresent(String.self, forKey: .loadError),
            kept: try container.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        )
    }
}

/// A plugin's hook handlers on one task.
struct ServerPluginHook: Codable, Sendable, Equatable {
    let task: String
    let handlers: [String]
}

/// What one plugin wrap targets: a tool or a prompt section.
struct ServerPluginWrap: Codable, Sendable, Equatable {
    let tool: String?
    let section: String?

    init(tool: String? = nil, section: String? = nil) {
        self.tool = tool
        self.section = section
    }
}

/// What one plugin reload did (`POST /server/resources/extensions/reload`).
struct ServerPluginReloadReport: Codable, Sendable, Equatable {
    struct Plugin: Codable, Sendable, Equatable {
        let name: String
        /// Its facet file.
        let entry: String
    }

    struct Issue: Codable, Sendable, Equatable {
        /// The file or folder that failed.
        let entry: String
        let message: String
        let plugin: String?
    }

    /// Installed from this reload.
    let loaded: [Plugin]
    /// Failed this time; their previous code stays installed.
    let kept: [Plugin]
    /// Extension names no plugin provides any more: uninstalled.
    let removed: [String]
    let skipped: [Issue]
    let errors: [Issue]
}

struct ServerExtensionDetail: Codable, Sendable, Equatable {
    let summary: ServerExtensionSummary
    let contributedTools: [String]?
    let contributedToolDetails: [ServerToolSummary]?
    let contributedCommands: [String]?
    /// What its tools tell the model: its plugin's, then its classic extension's. Absent from
    /// servers that predate them, and when neither is loaded.
    let toolDefinitions: [ServerToolDefinition]?
    /// Its plugin's prompt sections. Absent from servers that predate them and for a row
    /// without a loaded plugin.
    let promptSections: [ServerPromptSection]?

    init(
        summary: ServerExtensionSummary,
        contributedTools: [String]? = nil,
        contributedToolDetails: [ServerToolSummary]? = nil,
        contributedCommands: [String]? = nil,
        toolDefinitions: [ServerToolDefinition]? = nil,
        promptSections: [ServerPromptSection]? = nil
    ) {
        self.summary = summary
        self.contributedTools = contributedTools
        self.contributedToolDetails = contributedToolDetails
        self.contributedCommands = contributedCommands
        self.toolDefinitions = toolDefinitions
        self.promptSections = promptSections
    }
}

/// One tool as the model sees it, from an extension's detail.
struct ServerToolDefinition: Codable, Sendable, Hashable {
    /// Which sessions it reaches: a plugin's durable sessions, or a classic extension's Pi sessions.
    enum Origin: String, Codable, Sendable, Hashable {
        case plugin
        case piExtension = "pi-extension"
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = Self(rawValue: try container.decode(String.self)) ?? .unknown
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let name: String
    let description: String?
    /// The arguments' JSON Schema; absent when the server could not send it whole.
    let parameters: JSONValue?
    /// A classic tool's line in Pi's default prompt's tool list.
    let promptSnippet: String?
    /// A classic tool's bullets in Pi's default prompt's guidelines.
    let promptGuidelines: [String]?
    let from: Origin

    init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        promptSnippet: String? = nil,
        promptGuidelines: [String]? = nil,
        from: Origin
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.promptSnippet = promptSnippet
        self.promptGuidelines = promptGuidelines
        self.from = from
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, parameters, promptSnippet, promptGuidelines, from
    }

    /// Lenient: a field a later server leaves out decodes as absent, an origin it adds as unknown.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            parameters: try container.decodeIfPresent(JSONValue.self, forKey: .parameters),
            promptSnippet: try container.decodeIfPresent(String.self, forKey: .promptSnippet),
            promptGuidelines: try container.decodeIfPresent([String].self, forKey: .promptGuidelines),
            from: try container.decodeIfPresent(Origin.self, forKey: .from) ?? .unknown
        )
    }
}

/// One of a plugin's prompt sections, from an extension's detail.
struct ServerPromptSection: Codable, Sendable, Hashable {
    let name: String
    /// The section as its plugin writes it, before other plugins' wraps; nil when it is
    /// written for each conversation.
    let text: String?
    /// Written for each conversation: there is no one text to show.
    let perConversation: Bool

    init(name: String, text: String? = nil, perConversation: Bool) {
        self.name = name
        self.text = text
        self.perConversation = perConversation
    }

    private enum CodingKeys: String, CodingKey {
        case name, text, perConversation
    }

    /// Lenient: without the flag, a section with no text is per conversation.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            text: text,
            perConversation: try container.decodeIfPresent(Bool.self, forKey: .perConversation) ?? (text == nil)
        )
    }
}

struct MobileOutputGuideConfiguration: Codable, Sendable, Equatable {
    let enabled: Bool
    let revision: Int
}

struct PiSystemPromptSnapshot: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable, Equatable {
        case file
        case `default`
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let source: Source
    let path: String
    let resolvedPath: String?
    let content: String
}

struct PiDefaultToolsSnapshot: Codable, Sendable, Equatable {
    let defaultTools: [String]?
}

struct ServerExtensionCatalog: Codable, Sendable, Equatable {
    let extensions: [ServerExtensionSummary]
    let builtInTools: [ServerToolSummary]
    /// Tools Pi extensions register off (`codemode`, `tool_search`); `defaultTools` turns them on.
    /// Absent from servers that predate discovery.
    let optionalTools: [ServerToolSummary]?
    /// Why no plugin is listed: the server could not load its plugins. Only on a list that asked
    /// for plugin rows.
    let pluginsUnavailable: String?

    init(
        extensions: [ServerExtensionSummary],
        builtInTools: [ServerToolSummary] = [],
        optionalTools: [ServerToolSummary]? = nil,
        pluginsUnavailable: String? = nil
    ) {
        self.extensions = extensions
        self.builtInTools = builtInTools
        self.optionalTools = optionalTools
        self.pluginsUnavailable = pluginsUnavailable
    }
}

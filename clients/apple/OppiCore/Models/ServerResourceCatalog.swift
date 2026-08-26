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
        contributedToolDetails: [ServerToolSummary]? = nil
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
    }
}

struct ServerExtensionDetail: Codable, Sendable, Equatable {
    let summary: ServerExtensionSummary
    let contributedTools: [String]?
    let contributedToolDetails: [ServerToolSummary]?
    let contributedCommands: [String]?

    init(
        summary: ServerExtensionSummary,
        contributedTools: [String]? = nil,
        contributedToolDetails: [ServerToolSummary]? = nil,
        contributedCommands: [String]? = nil
    ) {
        self.summary = summary
        self.contributedTools = contributedTools
        self.contributedToolDetails = contributedToolDetails
        self.contributedCommands = contributedCommands
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

    init(
        extensions: [ServerExtensionSummary],
        builtInTools: [ServerToolSummary] = []
    ) {
        self.extensions = extensions
        self.builtInTools = builtInTools
    }
}

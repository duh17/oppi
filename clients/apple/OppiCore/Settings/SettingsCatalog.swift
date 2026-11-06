import Foundation

/// A server route that holds settings: the raw value is its path. One case per
/// route in `protocol/settings.json`; a declaration names the route and the
/// field of its JSON document it owns.
enum SettingEndpoint: String, Hashable, Sendable, CaseIterable {
    /// `GET`/`PUT /server/metrics/settings`: `{ enabled, revision? }`.
    case serverMetrics = "/server/metrics/settings"
    /// `GET`/`PUT /server/mobile-output-guide`: `{ enabled, revision }`; a write carries `baseRevision`.
    case mobileOutputGuide = "/server/mobile-output-guide"
    /// `GET`/`PUT /server/durable-sessions/settings`: `{ enabled, revision }` (`experimental.serverDurable`).
    case durableSessions = "/server/durable-sessions/settings"

    /// The route's row in `protocol/settings.json`, where the server lists the
    /// setting's scope and whether its saves carry a revision.
    /// `SettingsCatalogContractTests` holds the declarations to that row.
    var registryKey: String {
        switch self {
        case .serverMetrics: "serverMetrics"
        case .mobileOutputGuide: "mobileOutputGuide"
        case .durableSessions: "durableSessions"
        }
    }
}

/// Which of Pi's settings files a Pi-owned setting is written to.
enum PiSettingsLevel: String, Hashable, Sendable {
    case global
    case project
}

/// Where a setting is stored, which decides the adapter that reads and writes
/// it and the scope the page says. The enum is the full set of places a
/// setting can live; a slice that needs one adds its adapter to
/// `SettingsStore` without reshaping a declaration.
enum SettingStorage: Hashable, Sendable {
    /// `UserDefaults` on this device. `perServer`: the value is kept per paired
    /// server (push enable, Live Activities, Dictation consent).
    case device(perServer: Bool)
    /// One field of a server route's document. `revisioned`: the route returns
    /// a `revision` and rejects a stale write with `409 revision_conflict`.
    case server(SettingEndpoint, revisioned: Bool)
    /// One field of a workspace.
    case workspace(field: String)
    /// This device's own value, kept on the server.
    case deviceOnServer(SettingEndpoint, field: String)
    /// Pi's own settings file, read and written through a server route.
    case piOwned(SettingEndpoint, level: PiSettingsLevel)

    /// The scope a page says for a setting kept here. `serverName` and
    /// `workspaceName` are the visible server's and workspace's names; a
    /// missing one reads as a generic noun rather than an empty string.
    func scope(serverName: String?, workspaceName: String?) -> SettingsScope {
        let server = serverName ?? String(localized: "this server")
        switch self {
        case .device(let perServer):
            return perServer ? .deviceOnServer(server) : .device
        case .server, .piOwned:
            return .server(server)
        case .workspace:
            return .workspace(workspaceName ?? String(localized: "this workspace"))
        case .deviceOnServer:
            return .deviceOnServer(server)
        }
    }
}

/// When a change is written.
enum SaveMode: Hashable, Sendable {
    /// A single control writes as soon as it changes.
    case immediate
    /// Fields that validate together, saved by one Save on the named form.
    case draft(form: String)
}

/// The words a setting carries with it, so every row and page that shows it
/// says the same thing.
struct SettingCopy: Hashable, Sendable {
    /// The row's title.
    var title: String
    /// What the setting does, for the section's footer.
    var footer: String?
    /// Words a person must agree to before the setting turns on.
    var consent: String?

    init(title: String, footer: String? = nil, consent: String? = nil) {
        self.title = title
        self.footer = footer
        self.consent = consent
    }
}

/// One setting, declared once: its identity, where it is stored, what it
/// defaults to, what it accepts, when it saves, and what it says. Rows, the
/// store, and the contract test with the server all read this.
struct SettingDeclaration<Value: Codable & Equatable & Sendable>: Sendable {
    /// The kit identifier: the accessibility identifier of the row that shows
    /// it, `settings.<page>.<row>`.
    let id: String
    /// The storage key: a `UserDefaults` key, or a field of the endpoint's JSON.
    let key: String
    let storage: SettingStorage
    let `default`: Value
    /// The reason a value is refused, or `nil` when it is acceptable.
    let validate: @Sendable (Value) -> String?
    let save: SaveMode
    let copy: SettingCopy

    init(
        id: String,
        key: String,
        storage: SettingStorage,
        default defaultValue: Value,
        validate: @escaping @Sendable (Value) -> String? = { _ in nil },
        save: SaveMode = .immediate,
        copy: SettingCopy
    ) {
        self.id = id
        self.key = key
        self.storage = storage
        self.default = defaultValue
        self.validate = validate
        self.save = save
        self.copy = copy
    }

    /// The type-erased identity, for the catalog's list and the contract test.
    var descriptor: SettingDescriptor {
        SettingDescriptor(id: id, key: key, storage: storage)
    }
}

/// A declaration without its value type.
struct SettingDescriptor: Hashable, Sendable {
    let id: String
    let key: String
    let storage: SettingStorage
}

/// The one place Oppi's settings are declared. A setting that is not here has
/// no row, no store entry, and no server field to agree on. See
/// `dev/architecture-client.md`, "Settings pages".
enum SettingsCatalog {
    // MARK: - General (this device)

    /// Short taps as you use Oppi. A device setting on the existing
    /// `AppPreferenceStore` key and default, so `AppPreferences` and the store
    /// read one value.
    static let hapticFeedback = SettingDeclaration<Bool>(
        id: "settings.general.haptics",
        key: AppPreferenceStore.Interaction.hapticFeedbackEnabledKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Interaction.hapticFeedbackEnabledDefault,
        copy: SettingCopy(
            title: String(localized: "Haptic Feedback"),
            footer: String(localized: "Adds short taps as you use Oppi. Also follows your iOS System Haptics setting.")
        )
    )

    /// How long the screen stays on after a dictation or an agent's work stops.
    static let keepAwakeAfterActivity = SettingDeclaration<AppPreferenceStore.ScreenAwake.TimeoutPreset>(
        id: "settings.general.keepAwake",
        key: AppPreferenceStore.ScreenAwake.timeoutPresetKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.ScreenAwake.timeoutPresetDefault,
        copy: SettingCopy(
            title: String(localized: "Keep Awake After Activity"),
            footer: String(localized: "Oppi keeps the screen on while you dictate or an agent is working. This sets how long it stays on afterward.")
        )
    )

    /// Where web links open.
    static let openLinks = SettingDeclaration<AppPreferenceStore.Browser.LinkOpeningMode>(
        id: "settings.general.openLinks",
        key: AppPreferenceStore.Browser.linkOpeningModeKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Browser.linkOpeningModeDefault,
        copy: SettingCopy(title: String(localized: "Open Links"))
    )

    // MARK: - Appearance (this device)

    /// How the Pi mark is drawn everywhere: the official colors, or the theme
    /// foreground. A device setting on the `AppPreferenceStore` key the renderer reads.
    static let piIcon = SettingDeclaration<PiIconStyle>(
        id: "settings.appearance.piIcon",
        key: AppPreferenceStore.Appearance.piIconStyleKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Appearance.piIconStyleDefault,
        copy: SettingCopy(
            title: String(localized: "Pi Icon"),
            footer: String(localized: "Color uses the official Pi logo. Monochrome uses your theme's text color.")
        )
    )

    // MARK: - Editor

    /// Whether the editor writes a document as you type. Off (the default), nothing
    /// is written until a person saves it: Done asks, ⌘S and Vim's `:w` write, and a
    /// retry only resends bytes a person already confirmed. A device setting on the
    /// key `CodeEditorPreferences` stores, so the editor's "…" menu and this row show
    /// one value.
    static let autoSave = SettingDeclaration<Bool>(
        id: "settings.editor.autoSave",
        key: AppPreferenceStore.Editor.autoSaveKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Editor.autoSaveDefault,
        copy: SettingCopy(
            title: String(localized: "Auto-Save"),
            footer: String(localized: "Saves a file as you type. With it off, a file is written only when you save it: Done asks first, and ⌘S saves right away. Until then your edits stay on this device as a draft.")
        )
    )

    // MARK: - Terminal

    /// What the Terminal page lists: Rex's panes for every saved host, or the saved
    /// hosts themselves. A device choice, kept as `SSHTerminalPageMode`'s raw value;
    /// nothing stored (the empty default) means the page falls back to the first mode
    /// its experiments allow, so a stored value is always someone's choice.
    static let terminalPageMode = SettingDeclaration<String>(
        id: "settings.terminal.pageMode",
        key: AppPreferenceStore.Terminal.pageModeKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Terminal.pageModeDefault,
        copy: SettingCopy(
            title: String(localized: "Terminal Page"),
            footer: String(localized: "What the Terminal page lists. Rex shows every saved host's panes, one tap from that terminal; Shell shows the saved hosts. Chosen with the page's own mode button, and Rex is offered only while its experiment is on.")
        )
    )

    // MARK: - Experiments

    /// Rex: the Terminal tab's Rex sections, Rex sessions screens, Rex panes, and the
    /// Rex on your tailnet list. A device setting on the existing key, so
    /// `AppPreferenceStore.Experiments.rexEnabled` and this read one value, and a host
    /// saved with Multiplexer: Rex keeps that choice while it is off.
    static let experimentRex = SettingDeclaration<Bool>(
        id: "settings.experiments.rex",
        key: AppPreferenceStore.Experiments.rexKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Experiments.enabledDefault,
        copy: SettingCopy(
            title: String(localized: "Rex"),
            footer: String(localized: "Rex sessions and panes on the Terminal tab, including Rex on your tailnet. While off, a Rex host opens a plain shell and keeps its setting.")
        )
    )

    /// Herdr: its bar button (workspaces and agents) and opening a folder inside it.
    /// A device setting on the existing key, as Rex's is.
    static let experimentHerdr = SettingDeclaration<Bool>(
        id: "settings.experiments.herdr",
        key: AppPreferenceStore.Experiments.herdrKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Experiments.enabledDefault,
        copy: SettingCopy(
            title: String(localized: "Herdr"),
            footer: String(localized: "The Herdr button in the terminal, and Open Terminal Here inside Herdr. While off, a host that runs herdr opens a plain shell and keeps its command.")
        )
    )

    // MARK: - Server Metrics

    /// Whether the server samples its CPU, memory, and disk, for every device
    /// that uses it (`serverMetrics` in `protocol/settings.json`).
    static let serverMetricsEnabled = SettingDeclaration<Bool>(
        id: "server.metrics.enabled",
        key: "enabled",
        storage: .server(.serverMetrics, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Server Metrics"),
            footer: String(localized: "Samples this server's CPU, memory, and disk every 30 seconds. Samples stay on the server.")
        )
    )

    // MARK: - Mobile Output Guide

    /// Whether new and reloaded sessions on the server get Oppi's link and
    /// rich-content guide, for every device that uses it (`mobileOutputGuide`
    /// in `protocol/settings.json`; its saves require the base revision).
    static let mobileOutputGuideEnabled = SettingDeclaration<Bool>(
        id: "server.mobileOutputGuide.enabled",
        key: "enabled",
        storage: .server(.mobileOutputGuide, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Mobile Output Guide"),
            footer: String(localized: "Adds Oppi's link and rich-content guide to new sessions and to sessions you reload. Sessions running in a terminal aren't changed.")
        )
    )

    // MARK: - Durable Sessions

    /// Whether the server offers durable sessions to new creates, for every device that uses
    /// it (`durableSessions` in `protocol/settings.json`, stored as `experimental.serverDurable`).
    /// A save applies on the server at once; the connection's `durableSessions` capability
    /// follows it (`SettingsStore.liveServerAfterWrite`).
    static let durableSessionsEnabled = SettingDeclaration<Bool>(
        id: "server.durableSessions.enabled",
        key: "enabled",
        storage: .server(.durableSessions, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Durable Sessions"),
            footer: String(localized: "Lets new sessions on this server run on the durable engine, which saves each turn on the server and resumes interrupted work after a restart. When on, Quick Session shows a Classic / Durable switch. Durable sessions run only extensions that support them and have no session tree, export, or reload. Turning this off keeps sessions that are already durable working.")
        )
    )

    /// Whether Quick Session starts new sessions Durable on a server with Durable Sessions on.
    /// A device setting on the existing `AppPreferenceStore` key.
    static let startSessionsAsDurable = SettingDeclaration<Bool>(
        id: "server.durableSessions.startDurable",
        key: AppPreferenceStore.DurableSessions.startDurableKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.DurableSessions.startDurableDefault,
        copy: SettingCopy(
            title: String(localized: "Start Sessions as Durable"),
            footer: String(localized: "New sessions from Quick Session start Durable instead of Classic on servers that have Durable Sessions on. The switch in Quick Session still changes one session.")
        )
    )

    /// Every declared setting, type-erased. Ids and storage keys are unique
    /// across it (`SettingsCatalogTests`).
    static let all: [SettingDescriptor] = [
        hapticFeedback.descriptor,
        keepAwakeAfterActivity.descriptor,
        openLinks.descriptor,
        piIcon.descriptor,
        terminalPageMode.descriptor,
        experimentRex.descriptor,
        experimentHerdr.descriptor,
        serverMetricsEnabled.descriptor,
        mobileOutputGuideEnabled.descriptor,
        durableSessionsEnabled.descriptor,
        startSessionsAsDurable.descriptor,
        autoSave.descriptor,
    ]
}

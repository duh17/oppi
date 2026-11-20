import Foundation

/// A server route that holds settings: the raw value is its path. One case per
/// route in `protocol/settings.json`; a declaration names the route and the
/// field of its JSON document it owns.
enum SettingEndpoint: String, Hashable, Sendable, CaseIterable {
    /// `GET`/`PUT /server/metrics/settings`: `{ enabled, revision? }`.
    case serverMetrics = "/server/metrics/settings"
    /// `GET`/`PUT /server/mobile-output-guide`: `{ enabled, revision }`; a write carries `baseRevision`.
    case mobileOutputGuide = "/server/mobile-output-guide"
    /// `GET`/`PUT /server/oppi-docs-prompt`: `{ enabled, revision }`; a write may carry `baseRevision`.
    case oppiDocsPrompt = "/server/oppi-docs-prompt"
    /// `GET`/`PUT /server/oppi-cli-prompt`: `{ enabled, revision }`; a write may carry `baseRevision`.
    case oppiCliPrompt = "/server/oppi-cli-prompt"
    /// `GET`/`PUT /server/durable-sessions/settings`: `{ enabled, revision }` (`experimental.serverDurable`).
    case durableSessions = "/server/durable-sessions/settings"
    /// `GET`/`PUT /server/features`: one boolean per feature switch; a write names only the
    /// switches it changes.
    case features = "/server/features"

    /// The route's row in `protocol/settings.json`, where the server lists the
    /// setting's scope and whether its saves carry a revision.
    /// `SettingsCatalogContractTests` holds the declarations to that row.
    var registryKey: String {
        switch self {
        case .serverMetrics: "serverMetrics"
        case .mobileOutputGuide: "mobileOutputGuide"
        case .oppiDocsPrompt: "oppiDocsPrompt"
        case .oppiCliPrompt: "oppiCliPrompt"
        case .durableSessions: "durableSessions"
        case .features: "features"
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

    // MARK: - Privacy (this device)

    /// Whether Markdown images from public HTTPS sites load without a tap. The fetch
    /// limits (HTTPS, public hosts, size, content type) apply either way.
    static let remoteImages = SettingDeclaration<Bool>(
        id: "settings.privacy.loadRemoteImages",
        key: AppPreferenceStore.RemoteImages.autoloadKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.RemoteImages.autoloadDefault,
        copy: SettingCopy(
            title: String(localized: "Load Remote Images"),
            footer: String(localized: "Images from websites load without a tap. A website can see when you open the message, and a session that has been tricked could put private data in an image link.")
        )
    )

    // MARK: - Terminal

    /// What a tap on the terminal does when it opens nothing and no program takes
    /// the click: raise the keyboard, or leave typing to the bar's button.
    static let terminalTapMode = SettingDeclaration<AppPreferenceStore.Terminal.TapMode>(
        id: "settings.sshTerminal.tapMode",
        key: AppPreferenceStore.Terminal.tapModeKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Terminal.tapModeDefault,
        copy: SettingCopy(
            title: String(localized: "Tap in Terminal"),
            footer: String(localized: "Keyboard Button Only starts typing only from Type in Terminal on the bottom bar, so a tap to read never raises the keyboard. Tap Shows Keyboard raises it with a tap. Either way, a tap on a link opens it, and a program that takes mouse clicks, such as tmux or Herdr, gets the tap.")
        )
    )

    /// Whether the Terminal tab finds Rex on the tailnet by asking each of its
    /// computers, or lists only the Rex servers added by name.
    static let terminalFindsTailnetRex = SettingDeclaration<Bool>(
        id: "settings.sshTerminal.findsTailnetRex",
        key: AppPreferenceStore.Terminal.findsTailnetRexKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Terminal.findsTailnetRexDefault,
        copy: SettingCopy(
            title: String(localized: "Find Rex on Your Tailnet"),
            footer: String(localized: "While the Terminal tab shows, asks each computer of your own tailnet whether it runs Rex (a plain request to its Rex address) and lists the ones that do. Off, Oppi connects only to the Rex servers you add here or reach through a saved host, as Rex's own apps do. Needs Oppi's own Tailscale.")
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
            footer: String(localized: "Rex sessions and panes on the Terminal tab, including Rex on your tailnet. While off, a Rex host opens a plain shell and keeps its setting. A server can also turn Rex off for its windows in Server Settings › Features.")
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
            footer: String(localized: "The Herdr button in the terminal, and Open Terminal Here inside Herdr. While off, a host that runs herdr opens a plain shell and keeps its command. A server can also turn Herdr off for its windows in Server Settings › Features.")
        )
    )

    /// Calendar Events: this device's events beside runs in the Schedules calendar. Turning
    /// it on asks for calendar access (`DeviceCalendar`); events stay on this device.
    static let experimentCalendarEvents = SettingDeclaration<Bool>(
        id: "settings.experiments.calendarEvents",
        key: AppPreferenceStore.Experiments.calendarEventsKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Experiments.enabledDefault,
        copy: SettingCopy(
            title: String(localized: "Calendar Events"),
            footer: String(localized: "Shows this device's calendar events beside runs in Schedules. Events stay on this device; touch and hold one to schedule an agent for it, which sends its details to your server in that schedule's prompt.")
        )
    )

    /// New Panes: the side a new pane of `kind` opens on when nothing says
    /// (`PanePlacement`). Listed on Settings > Panes, which a wide window shows.
    static func newPaneSide(_ kind: AppPreferenceStore.NewPanes.Kind) -> SettingDeclaration<AppPreferenceStore.NewPanes.Side> {
        SettingDeclaration(
            id: "settings.panes.\(kind.rawValue)",
            key: AppPreferenceStore.NewPanes.key(kind),
            storage: .device(perServer: false),
            default: AppPreferenceStore.NewPanes.sideDefault(kind),
            copy: SettingCopy(
                title: kind.title,
                footer: String(localized: "Where a pane you open from a link or a button goes. Automatic puts it to the right in landscape and below in portrait. With no room on that side, it opens on the other.")
            )
        )
    }

    /// Godot Pane: Godot games from the server in a pane beside the chat. Nothing
    /// runs until a Godot pane opens; the engine then runs for the app's launch.
    static let experimentGodotPane = SettingDeclaration<Bool>(
        id: "settings.experiments.godotPane",
        key: AppPreferenceStore.Experiments.godotPaneKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Experiments.enabledDefault,
        copy: SettingCopy(
            title: String(localized: "Godot Pane"),
            footer: String(localized: "Adds Godot to a new pane’s choices: Godot projects in the server’s workspaces, played beside the chat. A new export reaches the pane by itself. Oppi plays one game per launch. A server can also turn it off in Server Settings › Features.")
        )
    )

    /// Live Activity: the Lock Screen card. While off, no server's card shows, Server
    /// Settings hides each server's switch, and every server is told this phone shows
    /// none; turning it on brings each server's saved choice back. Effects live in
    /// `SettingsStore.liveAfterWrite`.
    static let experimentLiveActivity = SettingDeclaration<Bool>(
        id: "settings.experiments.liveActivity",
        key: AppPreferenceStore.Experiments.liveActivityKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Experiments.enabledDefault,
        copy: SettingCopy(
            title: String(localized: "Live Activity"),
            footer: String(localized: "A Lock Screen card with how many agents are running and how many need you, turned on per server in Server Settings › Notifications. While off, no card shows and servers send none; each server's choice comes back when you turn it on.")
        )
    )

    /// The calendars whose events Schedules leaves out. Stored as the hidden ones, so a
    /// calendar added later shows until it is hidden.
    static let calendarEventsHiddenCalendars = SettingDeclaration<[String]>(
        id: "settings.experiments.calendarEvents.calendars",
        key: AppPreferenceStore.Experiments.calendarEventsHiddenKey,
        storage: .device(perServer: false),
        default: [],
        copy: SettingCopy(title: String(localized: "Calendars"))
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

    // MARK: - Prompt hints

    /// Whether new and reloaded host sessions on the server get the hint that points at
    /// Oppi's packaged docs (`oppiDocsPrompt` in `protocol/settings.json`). Opt-in.
    static let oppiDocsPromptEnabled = SettingDeclaration<Bool>(
        id: "server.oppiDocsPrompt.enabled",
        key: "enabled",
        storage: .server(.oppiDocsPrompt, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Oppi Docs Hint"),
            footer: String(localized: "Tells new sessions where Oppi's own documentation is, so they can answer questions about Oppi.")
        )
    )

    /// Whether new and reloaded host sessions on the server get the hint on driving other
    /// sessions with the `oppi` command (`oppiCliPrompt` in `protocol/settings.json`). Opt-in.
    static let oppiCliPromptEnabled = SettingDeclaration<Bool>(
        id: "server.oppiCliPrompt.enabled",
        key: "enabled",
        storage: .server(.oppiCliPrompt, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Oppi CLI Hint"),
            footer: String(localized: "Tells new sessions how to start, message, and stop other sessions with the oppi command.")
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

    // MARK: - Features

    /// One feature switch of the server, for every device that uses it (`features` in
    /// `protocol/settings.json`). Off hides the feature's entry points in this server's windows.
    static func feature(_ feature: ServerFeature) -> SettingDeclaration<Bool> {
        SettingDeclaration(
            id: "server.features.\(feature.rawValue)",
            key: feature.rawValue,
            storage: .server(.features, revisioned: false),
            default: true,
            copy: SettingCopy(title: feature.title)
        )
    }

    /// Every declared setting, type-erased. Ids and storage keys are unique
    /// across it (`SettingsCatalogTests`).
    static let all: [SettingDescriptor] = ServerFeature.allCases.map { feature($0).descriptor }
        + AppPreferenceStore.NewPanes.Kind.allCases.map { newPaneSide($0).descriptor } + [
        hapticFeedback.descriptor,
        keepAwakeAfterActivity.descriptor,
        openLinks.descriptor,
        piIcon.descriptor,
        terminalTapMode.descriptor,
        terminalFindsTailnetRex.descriptor,
        experimentRex.descriptor,
        experimentHerdr.descriptor,
        experimentCalendarEvents.descriptor,
        experimentLiveActivity.descriptor,
        calendarEventsHiddenCalendars.descriptor,
        serverMetricsEnabled.descriptor,
        mobileOutputGuideEnabled.descriptor,
        oppiDocsPromptEnabled.descriptor,
        oppiCliPromptEnabled.descriptor,
        durableSessionsEnabled.descriptor,
        startSessionsAsDurable.descriptor,
        autoSave.descriptor,
        remoteImages.descriptor,
    ]
}

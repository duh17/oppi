import SwiftUI
import UIKit

struct WorkspaceIconOption: Identifiable, Equatable {
    let symbolName: String
    let label: String

    var id: String { symbolName }
}

enum WorkspaceIconCatalog {
    static let options: [WorkspaceIconOption] = [
        .init(symbolName: "folder", label: "Folder"),
        .init(symbolName: "folder.fill", label: "Folder Filled"),
        .init(symbolName: "square.grid.2x2", label: "Workspace"),
        .init(symbolName: "rectangle.3.group", label: "Project"),
        .init(symbolName: "terminal", label: "Terminal"),
        .init(symbolName: "chevron.left.forwardslash.chevron.right", label: "Code"),
        .init(symbolName: "curlybraces", label: "Braces"),
        .init(symbolName: "command", label: "Command"),
        .init(symbolName: "hammer", label: "Build"),
        .init(symbolName: "wrench.and.screwdriver", label: "Tools"),
        .init(symbolName: "ant", label: "Debug"),
        .init(symbolName: "shippingbox", label: "Package"),
        .init(symbolName: "cube", label: "Module"),
        .init(symbolName: "server.rack", label: "Server"),
        .init(symbolName: "externaldrive", label: "Storage"),
        .init(symbolName: "cloud", label: "Cloud"),
        .init(symbolName: "network", label: "Network"),
        .init(symbolName: "globe", label: "Web"),
        .init(symbolName: "arrow.triangle.branch", label: "Branch"),
        .init(symbolName: "point.3.connected.trianglepath.dotted", label: "Graph"),
        .init(symbolName: "doc.text", label: "Docs"),
        .init(symbolName: "book.closed", label: "Book"),
        .init(symbolName: "text.page", label: "Text"),
        .init(symbolName: "checklist", label: "Checklist"),
        .init(symbolName: "tray.full", label: "Archive"),
        .init(symbolName: "brain", label: "AI"),
        .init(symbolName: "sparkles", label: "Sparkles"),
        .init(symbolName: "lightbulb", label: "Idea"),
        .init(symbolName: "bolt", label: "Fast"),
        .init(symbolName: "flame", label: "Hot"),
        .init(symbolName: "star", label: "Favorite"),
        .init(symbolName: "heart", label: "Heart"),
        .init(symbolName: "flag", label: "Flag"),
        .init(symbolName: "tag", label: "Tag"),
        .init(symbolName: "lock", label: "Secure"),
        .init(symbolName: "shield", label: "Shield"),
        .init(symbolName: "person.2", label: "Team"),
        .init(symbolName: "paintbrush", label: "Design"),
        .init(symbolName: "photo", label: "Media"),
        .init(symbolName: "music.note", label: "Audio"),
        .init(symbolName: "gamecontroller", label: "Game"),
        .init(symbolName: "graduationcap", label: "Learning"),
        .init(symbolName: "leaf", label: "Nature"),
        .init(symbolName: "cart", label: "Shop"),
    ]

    static func filtered(by query: String) -> [WorkspaceIconOption] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return options }

        return options.filter {
            $0.label.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.symbolName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    static func label(for symbolName: String) -> String? {
        options.first { $0.symbolName == symbolName }?.label
    }
}

// MARK: - WorkspaceIcon

struct WorkspaceIcon: View {
    let icon: IconChoice?
    let size: CGFloat
    var assetCache: IconAssetCache? = nil
    @Environment(\.iconAssetCache) private var environmentAssetCache
    @State private var loadedGenmoji: UIImage?
    @State private var activeLoadIdentity: IconAssetViewLoadIdentity?

    var body: some View {
        Group {
            switch icon ?? .defaultValue {
            case .emoji(let value):
                Text(value)
            case .symbol(let name) where UIImage(systemName: name) != nil:
                Image(systemName: name)
                    .foregroundStyle(.themeBlue)
            case .genmoji:
                if let loadedGenmoji {
                    Image(uiImage: loadedGenmoji)
                        .resizable()
                        .scaledToFit()
                } else {
                    defaultIcon
                }
            case .defaultValue, .symbol:
                defaultIcon
            }
        }
        .font(.system(size: size))
        .task(id: IconAssetLoadKey(
            assetId: icon?.assetId,
            cache: assetCache ?? environmentAssetCache
        )) {
            let cache = assetCache ?? environmentAssetCache
            let identity = IconAssetViewLoadIdentity(
                key: IconAssetLoadKey(assetId: icon?.assetId, cache: cache),
                requestID: UUID()
            )
            activeLoadIdentity = identity
            guard case .genmoji(let assetId, _) = icon,
                  let cache else {
                loadedGenmoji = nil
                return
            }
            await loadIconAssetForView(
                assetId: assetId,
                size: size * 2,
                cache: cache,
                identity: identity,
                currentIdentity: { activeLoadIdentity },
                assign: { loadedGenmoji = $0 }
            )
        }
    }

    private var defaultIcon: some View {
        Image(systemName: "square.grid.2x2")
            .foregroundStyle(.themeBlue)
    }
}

func draftIconChoice(_ value: String) -> IconChoice {
    switch AgentIconValue.classify(value) {
    case .emoji(let emoji): return .emoji(emoji)
    case .symbolCandidate(let name): return .symbol(name)
    case .invalid: return .defaultValue
    }
}

extension IconChoice {
    var draftText: String {
        switch self {
        case .emoji(let value): return value
        case .symbol(let name): return name
        case .defaultValue, .genmoji: return ""
        }
    }
}

struct WorkspaceIconPickerSelection: Equatable, Sendable {
    var value: IconChoice

    var draftText: String {
        get { value.draftText }
        set { value = draftIconChoice(newValue) }
    }

    var currentIconName: String {
        switch value {
        case .defaultValue:
            return "Default workspace icon"
        case .emoji(let emoji):
            return emoji
        case .symbol(let name):
            return WorkspaceIconCatalog.label(for: name) ?? name
        case .genmoji(_, let contentDescription):
            return contentDescription
        }
    }

    mutating func selectSymbol(_ symbolName: String) {
        value = .symbol(symbolName)
    }

    mutating func useDefault() {
        value = .defaultValue
    }
}

struct WorkspaceIconPicker: View {
    @Binding var selection: WorkspaceIconPickerSelection

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [WorkspaceIconOption] {
        WorkspaceIconCatalog.filtered(by: searchText)
    }

    var body: some View {
        List {
            Section("Current Icon") {
                HStack(spacing: 12) {
                    WorkspaceIcon(icon: selection.value, size: 28)
                        .frame(width: 44, height: 44)

                    Text(selection.currentIconName)
                        .font(currentIconNameUsesMonospacedFont ? .body.monospaced() : .body)
                        .foregroundStyle(.themeFg)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)

                Button {
                    selection.useDefault()
                } label: {
                    Label("Use Default Icon", systemImage: "arrow.counterclockwise")
                }
                .disabled(selection.value == .defaultValue)
                .accessibilityIdentifier("workspace.iconPicker.default")
            }

            Section {
                TextField("Emoji or SF Symbol name", text: $selection.draftText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("workspace.iconPicker.custom")
            } footer: {
                Text("Choose a symbol below, enter an emoji, or paste an SF Symbol name.")
            }

            Section("SF Symbols") {
                if filteredOptions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(filteredOptions) { option in
                            symbolButton(option)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Choose Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search symbols")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var currentIconNameUsesMonospacedFont: Bool {
        guard case .symbol(let name) = selection.value else { return false }
        return WorkspaceIconCatalog.label(for: name) == nil
    }

    private func symbolButton(_ option: WorkspaceIconOption) -> some View {
        let isSelected = selection.value == .symbol(option.symbolName)

        return Button {
            selection.selectSymbol(option.symbolName)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.symbolName)
                    .font(.title3)
                    .frame(width: 32, height: 28)

                Text(option.label)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isSelected ? .themeBlue : .themeFg)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 4)
            .background(.themeBlue.opacity(isSelected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.themeBlue.opacity(isSelected ? 0.7 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WorkspaceRuntimeIcon: View {
    let workspace: Workspace
    let size: CGFloat
    let frameSize: CGFloat
    var assetCache: IconAssetCache? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WorkspaceIcon(icon: workspace.icon, size: size, assetCache: assetCache)
                .frame(width: frameSize, height: frameSize)

            if workspace.runtime == .sandbox {
                WorkspaceSandboxMark(size: max(11, frameSize * 0.34))
                    .offset(x: frameSize * 0.05, y: frameSize * 0.05)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.runtime == .sandbox ? "Sandbox workspace" : "Workspace")
    }
}

struct WorkspaceSandboxMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.themeBg)
            .frame(width: size, height: size)
            .background(Circle().fill(.themeOrange))
            .overlay(Circle().stroke(Color.themeBg, lineWidth: 1))
            .accessibilityLabel("Sandbox")
    }
}

// MARK: - WorkspaceSelectionButton

struct WorkspaceSelectionButton: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

// MARK: - RuntimeBadge

struct RuntimeBadge: View {
    var compact: Bool = false
    var icon: ServerBadgeIcon = .defaultValue
    var tint: Color = .themeComment

    private var resolvedSymbolName: String {
        if UIImage(systemName: icon.symbolName) != nil {
            return icon.symbolName
        }
        return "desktopcomputer"
    }

    private var badgeSize: CGFloat {
        compact ? 20 : 24
    }

    private var symbolSize: CGFloat {
        compact ? 10 : 12
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))

            Circle()
                .stroke(tint.opacity(0.5), lineWidth: 1)

            Image(systemName: resolvedSymbolName)
                .font(.system(size: symbolSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: badgeSize, height: badgeSize)
        .accessibilityLabel("Server badge")
    }
}

enum ServerBadgeConnectionState: Sendable, Equatable {
    case connected
    case connecting
    case disconnected
    case syncFailed

    init(_ transportStatus: WebSocketClient.Status?) {
        switch transportStatus {
        case .connected:
            self = .connected
        case .connecting, .reconnecting:
            self = .connecting
        case .disconnected, nil:
            self = .disconnected
        }
    }

    init(_ presentation: WorkspaceServerStatusPresentation, hasSyncFailure: Bool = false) {
        if hasSyncFailure {
            self = .syncFailed
            return
        }

        switch presentation.state {
        case .live, .stale:
            self = .connected
        case .syncing:
            self = .connecting
        case .offline:
            self = .disconnected
        }
    }

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .syncFailed: return "Update Failed"
        }
    }

    var tintColor: Color {
        switch self {
        case .connected: return .themeGreen
        case .connecting: return .themeBlue
        case .disconnected, .syncFailed: return .themeRed
        }
    }
}

// MARK: - Workspace Server Status Presentation

struct WorkspaceServerStatusPresentation: Equatable, Sendable {
    let state: FreshnessState
    let label: String
    let isUnreachable: Bool

    static func derive(
        freshnessState: FreshnessState,
        freshnessLabel: String,
        isTransportConnected: Bool,
        hasCachedCatalog: Bool
    ) -> Self {
        derive(health: ServerHealth.derive(
            freshnessState: freshnessState,
            freshnessLabel: freshnessLabel,
            transportStates: [isTransportConnected ? .connected : .disconnected],
            hasCachedCatalog: hasCachedCatalog
        ))
    }

    static func derive(health: ServerHealth) -> Self {
        if health.freshnessState == .offline {
            switch health.transportState {
            case .connected:
                if health.hasCachedCatalog {
                    return Self(state: .stale, label: "Connected", isUnreachable: false)
                }
                return Self(state: .syncing, label: "Connecting", isUnreachable: false)

            case .connecting:
                return Self(state: .syncing, label: "Connecting", isUnreachable: false)

            case .disconnected:
                return Self(
                    state: .offline,
                    label: health.freshnessLabel,
                    isUnreachable: true
                )
            }
        }

        return Self(
            state: health.freshnessState,
            label: health.freshnessLabel,
            isUnreachable: false
        )
    }
}

// MARK: - RuntimeStatusBadge

// periphery:ignore - future navigation bar badge; not yet integrated into ChatView
/// Environment icon whose tint reflects session + sync state.
struct RuntimeStatusBadge: View {
    enum SyncState {
        case live
        case syncing
        case offline
        case stale

        var accessibilityText: String {
            switch self {
            case .live: return "Live"
            case .syncing: return "Syncing"
            case .offline: return "Offline"
            case .stale: return "Stale"
            }
        }
    }

    let statusColor: Color
    var syncState: SyncState = .live
    var icon: ServerBadgeIcon = .defaultValue

    private var badgeTint: Color {
        switch syncState {
        case .live: return statusColor
        case .syncing: return .themeBlue
        case .offline: return .themeRed
        case .stale: return .themeOrange
        }
    }

    var body: some View {
        RuntimeBadge(compact: true, icon: icon, tint: badgeTint)
            .frame(width: 24, height: 24)
            .accessibilityLabel("\(syncState.accessibilityText) session status")
    }
}

// periphery:ignore - extension on RuntimeStatusBadge.SyncState; suppressed with parent type
extension RuntimeStatusBadge.SyncState {
    init(_ freshness: FreshnessState) {
        switch freshness {
        case .live:
            self = .live
        case .syncing:
            self = .syncing
        case .offline:
            self = .offline
        case .stale:
            self = .stale
        }
    }
}

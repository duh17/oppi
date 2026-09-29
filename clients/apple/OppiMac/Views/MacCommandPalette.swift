import SwiftUI

enum MacCommandPaletteMode: Equatable, Sendable {
    /// ⌘K: commands and sessions.
    case all
    /// ⌘P: sessions only.
    case sessions
}

struct MacCommandPaletteItem: Identifiable {
    enum Kind {
        case command(MacAppCommand)
        case session(MacSelectedSessionTarget)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let systemImage: String
    let shortcut: String?
    let isEnabled: Bool
    /// Extra words matched after the title (category, workspace, keywords).
    let keywords: String

    var isSession: Bool {
        if case .session = kind { return true }
        return false
    }
}

/// Fuzzy ranking for the palette. Subsequence match with bonuses for word
/// starts, consecutive runs, and prefixes; title matches beat keyword matches.
enum MacCommandPaletteSearch {
    static func score(query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var needleIndex = 0
        var previousMatch: Int?
        for (index, character) in haystack.enumerated() where needleIndex < needle.count {
            guard character == needle[needleIndex] else { continue }
            score += 1
            let atWordStart = index == 0 || !haystack[index - 1].isLetter && !haystack[index - 1].isNumber
            if atWordStart { score += 6 }
            if let previousMatch, previousMatch == index - 1 { score += 4 }
            if let previousMatch { score -= min(3, index - previousMatch - 1) }
            previousMatch = index
            needleIndex += 1
        }
        guard needleIndex == needle.count else { return nil }
        let loweredQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        let loweredText = text.lowercased()
        if loweredText.hasPrefix(loweredQuery) {
            score += 20
        } else if loweredText.contains(loweredQuery) {
            score += 10
        }
        return score
    }

    static func score(query: String, item: MacCommandPaletteItem) -> Int? {
        let titleScore = score(query: query, in: item.title).map { $0 + 8 }
        let keywordScore = score(query: query, in: "\(item.title) \(item.keywords)")
        switch (titleScore, keywordScore) {
        case let (title?, keyword?): return max(title, keyword)
        case let (title?, nil): return title
        case let (nil, keyword?): return keyword
        case (nil, nil): return nil
        }
    }

    /// Empty query keeps the given order (commands, then sessions in Home
    /// order). Enabled items always sort before disabled ones.
    static func rank(_ items: [MacCommandPaletteItem], query: String) -> [MacCommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let scored: [(offset: Int, item: MacCommandPaletteItem, score: Int)] = items.enumerated().compactMap {
            guard let score = trimmed.isEmpty ? 0 : score(query: trimmed, item: $0.element) else {
                return nil
            }
            return ($0.offset, $0.element, score)
        }
        return scored.sorted { lhs, rhs in
            if lhs.item.isEnabled != rhs.item.isEnabled { return lhs.item.isEnabled }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.offset < rhs.offset
        }.map(\.item)
    }

    static func moveSelection(_ selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, selection + delta))
    }
}

/// Uses the menu bar's dispatch snapshot so palette enablement and actions
/// match the menus exactly.
struct MacCommandPaletteHost: View {
    let mode: MacCommandPaletteMode
    let dispatch: MacAppCommandDispatch
    let sessions: [MacSelectedSessionTarget]
    let openSession: (MacSelectedSessionTarget) -> Void
    let splitSession: (MacSelectedSessionTarget) -> Void
    /// Closes before running an item; the item decides where focus goes.
    let dismiss: () -> Void
    /// Esc or click outside: close and hand focus back.
    let cancel: () -> Void

    var body: some View {
        MacCommandPaletteView(
            mode: mode,
            items: items(dispatch: dispatch),
            run: { item, split in
                dismiss()
                // Let the palette's field resign before the action moves focus.
                DispatchQueue.main.async {
                    switch item.kind {
                    case .command(let command):
                        dispatch.perform(command)
                    case .session(let target):
                        split ? splitSession(target) : openSession(target)
                    }
                }
            },
            dismiss: cancel
        )
    }

    private func items(dispatch: MacAppCommandDispatch) -> [MacCommandPaletteItem] {
        let sessionItems = sessions.map { target in
            let session = target.summary.session
            let workspace = session.workspaceName ?? ""
            return MacCommandPaletteItem(
                id: "session:\(target.sessionId)",
                kind: .session(target),
                title: session.displayTitle,
                subtitle: [workspace, MacCommandPalettePaint.statusText(session.status)]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                systemImage: MacCommandPalettePaint.statusSymbol(session.status),
                shortcut: nil,
                isEnabled: true,
                keywords: "\(workspace) \(session.model ?? "") \(session.status.rawValue)"
            )
        }
        guard mode == .all else { return sessionItems }
        let commandItems = MacAppCommand.allCases
            .filter { $0 != .commandPalette }
            .map { command in
                MacCommandPaletteItem(
                    id: "command:\(command.rawValue)",
                    kind: .command(command),
                    title: command.title.replacingOccurrences(of: "…", with: ""),
                    subtitle: command.category.rawValue,
                    systemImage: command.systemImage,
                    shortcut: MacKeybindingStore.shared.shortcut(for: command)?.displayString,
                    isEnabled: dispatch.isEnabled(command),
                    keywords: "\(command.category.rawValue) \(command.searchKeywords)"
                )
            }
        return commandItems + sessionItems
    }
}

enum MacCommandPalettePaint {
    static func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .busy: "Working"
        case .starting: "Starting"
        case .ready: "Idle"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .error: "Error"
        }
    }

    static func statusSymbol(_ status: SessionStatus) -> String {
        switch status {
        case .busy, .starting: "bolt.circle"
        case .ready: "bubble.left.circle"
        case .stopping, .stopped: "stop.circle"
        case .error: "exclamationmark.circle"
        }
    }
}

private struct MacCommandPaletteView: View {
    let mode: MacCommandPaletteMode
    let items: [MacCommandPaletteItem]
    let run: (MacCommandPaletteItem, _ split: Bool) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [MacCommandPaletteItem] {
        MacCommandPaletteSearch.rank(items, query: query)
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                searchField(results: results)
                Divider()
                resultList(results)
                Divider()
                footer
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 72)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac.commandPalette")
        }
        .onAppear {
            // The composer's NSTextView resigns in the same update; claim the
            // field on the next turn so AppKit does not keep first responder.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func searchField(results: [MacCommandPaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .sessions ? "arrow.right.circle" : "command")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                mode == .sessions ? "Go to session…" : "Type a command or session…",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 19))
            .focused($isFieldFocused)
            .onKeyPress(phases: .down) { press in
                handleKey(press, results: results)
            }
            .accessibilityIdentifier("mac.commandPalette.query")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func resultList(_ results: [MacCommandPaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if results.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selection)
                            .id(item.id)
                            .onTapGesture {
                                selection = index
                                commit(item, split: false)
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: results.count < 8)
            .onChange(of: selection) { _, index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id)
            }
        }
    }

    private func row(_ item: MacCommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
        .opacity(item.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerHint("↑↓", "Navigate")
            footerHint("↩", "Open")
            footerHint("⌘↩", "Open in Split")
            footerHint("esc", "Close")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(label)
        }
    }

    private func handleKey(_ press: KeyPress, results: [MacCommandPaletteItem]) -> KeyPress.Result {
        let control = press.modifiers.contains(.control)
        switch press.key {
        case .downArrow:
            selection = MacCommandPaletteSearch.moveSelection(selection, by: 1, count: results.count)
            return .handled
        case .upArrow:
            selection = MacCommandPaletteSearch.moveSelection(selection, by: -1, count: results.count)
            return .handled
        case .escape:
            dismiss()
            return .handled
        case .return:
            guard results.indices.contains(selection) else { return .handled }
            commit(results[selection], split: press.modifiers.contains(.command))
            return .handled
        default:
            break
        }
        // Emacs-style ⌃N / ⌃P move the selection in every preset.
        if control, let base = press.keybindingChord, case .character(let character) = base.key {
            if character == "n" {
                selection = MacCommandPaletteSearch.moveSelection(selection, by: 1, count: results.count)
                return .handled
            }
            if character == "p" {
                selection = MacCommandPaletteSearch.moveSelection(selection, by: -1, count: results.count)
                return .handled
            }
        }
        return .ignored
    }

    private func commit(_ item: MacCommandPaletteItem, split: Bool) {
        guard item.isEnabled else { return }
        run(item, split && item.isSession)
    }
}

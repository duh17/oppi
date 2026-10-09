import SwiftUI
import UIKit

struct SSHTerminalView: View {
    let channel: SSHTerminalChannel
    let reconnect: () -> Void
    let editHost: () -> Void
    /// Saved profile label (`user@host`). Reports never supply this.
    var hostLabel: String = ""
    @Environment(\.themeID) private var themeID
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingPaste: String?
    @State private var pasteConfirmation = false
    @State private var pasteFailure: String?
    @State private var detached = false
    @State private var pasteNotice: String?
    @State private var pasteNoticeTask: Task<Void, Never>?
    @State private var keyboardRequest = 0
    @State private var composerFocusRequest = 0
    @State private var rawKeyboard = false
    @State private var herdr = HerdrMonitor()
    @State private var showsHerdr = false
    @State private var detector = SSHTerminalAgentDetector()
    @State private var keymap = SSHTerminalKeymapLoader()
    /// The user's choice; dropped when the detected mode changes.
    @State private var modeOverride: SSHTerminalInputMode?
    @State private var resignRawKeyboardRequest = 0
    /// Focus the chat bar once the raw keyboard is down and the bar is mounted.
    @State private var focusComposerAfterRaw = false
    @State private var topBarHidden = false
    /// The background closed a live terminal; returning reconnects it.
    @State private var reconnectOnReturn = false
    /// Floats over the grid: a row in the stack would resize the remote terminal.
    @State private var copyNotice: String?
    /// Which notice floats over the grid, and what the person folded away.
    @State private var attention = SSHTerminalAttention()

    private var detectedMode: SSHTerminalInputMode? {
        detector.mode(programStatus: channel.programStatus, herdr: herdr.snapshot)
    }
    /// A shell gets direct typing until a probe finds an agent.
    private var inputMode: SSHTerminalInputMode { modeOverride ?? detectedMode ?? .terminal }
    /// Whose key bindings the strips offer: the foreground program, or the
    /// agent in Herdr's focused pane.
    private var keymapProgram: String? {
        switch detector.foreground {
        case nil: nil
        case .shell: "shell"
        case .agent(let name): name
        case .herdr: herdr.snapshot?.focusedAgent?.agent ?? "shell"
        }
    }

    private var herdrAttentionCount: Int { herdr.snapshot?.needsAttention ?? 0 }

    @ViewBuilder
    private var terminalActionMenuItems: some View {
        if inputMode == .chat {
            Button("Type in Terminal", systemImage: "keyboard", action: showTerminalKeyboard)
                .accessibilityIdentifier("sshTerminal.useTerminalInput")
        } else {
            Button("Use Chat Bar", systemImage: "text.bubble", action: showChatBar)
                .accessibilityIdentifier("sshTerminal.useChatBar")
        }
        Button("Edit Host", systemImage: "pencil", action: editHost)
        if channel.connected {
            Button("Hide Bar", systemImage: "chevron.up") { setTopBarHidden(true) }
                .accessibilityIdentifier("sshTerminal.hideBar")
            Button("Disconnect", systemImage: "xmark", role: .destructive) { channel.close(reason: "Closed by you.") }
                .accessibilityIdentifier("sshTerminal.disconnect")
        } else if !channel.connecting {
            Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
        }
    }

    /// The grid, its rows and overlays, and the toolbar. Split from `body` so
    /// the type checker handles each half.
    private var terminalScreen: some View {
        VStack(spacing: 0) {
            // A healthy connection shows no status row; the terminal gets the space.
            if channel.connecting || !channel.connected || channel.networkChanged {
                HStack(spacing: 6) {
                    if channel.connecting || channel.networkChanged {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "xmark.circle").foregroundStyle(.themeRed)
                    }
                    Text(statusText).lineLimit(2)
                    Spacer(minLength: 4)
                    if !channel.connected && !channel.connecting {
                        Button("Reconnect", action: reconnect).accessibilityIdentifier("sshTerminal.reconnect")
                    }
                }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4).foregroundStyle(.themeFg)
                // Without .contain the identifier replaces Reconnect's own.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sshTerminal.status")
            }
            if !channel.inputNotice.isEmpty {
                Text(channel.inputNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.inputNotice")
            }
            if let pasteNotice {
                Text(pasteNotice).font(.footnote).foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("sshTerminal.pasteNotice")
            }
            SSHTerminalSurface(channel: channel, themeID: themeID, keyboardRequest: keyboardRequest,
                               resignRequest: resignRawKeyboardRequest, tapTypesInTerminal: inputMode == .terminal,
                               keyActions: keymap.actions,
                               paste: requestPaste, followChanged: { detached = !$0 },
                               rawKeyboardChanged: { rawKeyboard = $0 },
                               focusComposer: { composerFocusRequest += 1 },
                               useChatBar: showChatBar)
                .clipped()
                .overlay(alignment: .top) {
                    // The grid's row count is its height. An in-flow banner would
                    // shrink that height and resize the remote PTY, so the notice
                    // floats. The handle stays above it when the bar is hidden.
                    VStack(spacing: 8) {
                        if topBarHidden, channel.connected {
                            SSHTerminalTopBarHandle(show: { setTopBarHidden(false) })
                        }
                        if let notice = visibleNotice {
                            SSHTerminalNoticeCard(notice: notice, hostLabel: hostLabel, frameChanged: { attention.cardFrame = $0 }) {
                                attention.dismiss(notice.key)
                            }
                            // A new notice is a new card: a drag in flight belongs
                            // to the old one and can only dismiss that one.
                            .id(notice.key)
                            .transition(SSHTerminalNoticeCard.transition(
                                card: attention.cardFrame, glyph: attention.glyphFrame.rect, reduceMotion: reduceMotion
                            ))
                        }
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth, value: visibleNotice?.key)
                }
                .overlay(alignment: .bottom) {
                    if let copyNotice {
                        Label(copyNotice, systemImage: "doc.on.clipboard")
                            .font(.footnote).foregroundStyle(.themeFg)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .themedSurface(.floatingControl, in: Capsule())
                            .padding(8)
                            .transition(.opacity)
                            .accessibilityIdentifier("sshTerminal.copyNotice")
                    }
                }
                .animation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion), value: copyNotice)
                .overlay(alignment: .bottomTrailing) {
                    if detached {
                        Button("Back to Live", systemImage: "arrow.down.to.line") {
                            channel.engine.backToLive()
                            detached = false
                        }.buttonStyle(.borderedProminent).padding(8)
                            .accessibilityIdentifier("sshTerminal.backToLive")
                    }
                }
            // An agent gets the chat bar; a shell gets direct typing. The chat
            // bar's keyboard button and Type in Terminal both stay in direct
            // typing until Use Chat Bar or a foreground change.
            if inputMode == .chat && !rawKeyboard {
                SSHTerminalComposer(channel: channel, focusRequest: composerFocusRequest,
                                    profile: keymap.profile, userFile: keymap.userFile) {
                    showTerminalKeyboard()
                }
            }
        }
        .background(.themeBg)
        .navigationTitle(channel.title.isEmpty ? "SSH Terminal" : channel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let rollup = programRollup, let headline = rollup.headline {
                ToolbarItem(placement: .topBarTrailing) {
                    SSHTerminalStatusGlyph(
                        status: headline,
                        style: .toolbar,
                        root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) },
                        summary: rollup.summaryText,
                        hostLabel: hostLabel,
                        rows: programStatusRows,
                        frameBox: attention.glyphFrame
                    )
                }
            }
            if herdr.available {
                ToolbarItem(placement: .topBarTrailing) {
                    // A badge overlay does not survive the rail's glyph rendering, so
                    // attention shows as an orange tint and a count in the title.
                    Button(
                        herdrAttentionCount > 0 ? "Herdr agents (\(herdrAttentionCount))" : "Herdr agents",
                        systemImage: "square.grid.2x2"
                    ) { showsHerdr = true }
                    .tint(herdrAttentionCount > 0 ? .themeOrange : nil)
                    .accessibilityLabel("Herdr agents")
                    .accessibilityValue(herdr.snapshot.map { "\($0.needsAttention) need you" } ?? "")
                    .accessibilityIdentifier("sshTerminal.herdr")
                }
            }
            // System overflow on iOS 27 (vertical rail aware); labeled Menu before that.
            if #available(iOS 27.0, *) {
                ToolbarOverflowMenu { terminalActionMenuItems }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        terminalActionMenuItems
                    } label: {
                        Label("Terminal actions", systemImage: "ellipsis")
                    }
                    .accessibilityLabel("Terminal actions")
                    .accessibilityIdentifier("sshTerminal.menu")
                }
            }
        }
    }

    var body: some View {
        terminalScreen
        .sheet(isPresented: $showsHerdr) {
            HerdrAgentsView(monitor: herdr, channel: channel)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: showsHerdr) { _, open in herdr.watching = open }
        .onChange(of: detector.foreground) { _, foreground in herdr.attached = foreground == .herdr }
        .onChange(of: detectedMode) { _, mode in
            modeOverride = nil
            // Starting an agent from the raw keyboard moves typing to the chat bar.
            if mode == .chat && rawKeyboard {
                focusComposerAfterRaw = true
                resignRawKeyboardRequest += 1
            }
        }
        .onChange(of: rawKeyboard) { _, raw in
            guard !raw, focusComposerAfterRaw else { return }
            focusComposerAfterRaw = false
            if inputMode == .chat { composerFocusRequest += 1 }
        }
        .onChange(of: channel.connected) { _, connected in if !connected { topBarHidden = false } }
        .modifier(SSHTerminalAttentionFeedback(notice: visibleNotice, bell: channel.alerts.bell) { attention.dismiss($0) })
        // One poller per connected generation; it ends with the connection.
        .task(id: channel.connected) {
            guard channel.connected else { return }
            await herdr.run(on: channel)
        }
        .task(id: channel.connected) {
            guard channel.connected else { return }
            await detector.run(on: channel)
        }
        .task(id: [channel.connected ? "connected" : "closed", keymapProgram ?? ""]) {
            await keymap.load(program: channel.connected ? keymapProgram : nil, on: channel)
        }
        // The terminal paints with the app theme, not the system appearance.
        // Keep the bar's title and back chevron legible against it in both.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.themeBg, for: .navigationBar)
        .toolbarColorScheme(themeID.preferredColorScheme, for: .navigationBar)
        // Scrolling must not show or hide this bar: visibility changes the
        // row count and resizes the remote terminal. Hide Bar and the top
        // handle are the only switches. A broken connection always shows it.
        .toolbarVisibility(topBarHidden && channel.connected ? .hidden : .visible, for: .navigationBar)
        .task { await channel.watchNetwork() }
        .onDisappear {
            pasteNoticeTask?.cancel()
            channel.close(reason: "Terminal dismissed.")
        }
        .onChange(of: scenePhase) { _, phase in scenePhaseChanged(phase) }
        // App Lock's cover can come and go (cancel, leave again) before the
        // unlock that lets the reconnect run, so the flag waits for it here.
        .onChange(of: AppLockService.shared.isLocked) { _, locked in
            if !locked { reconnectAfterReturn() }
        }
        .onChange(of: channel.copies) { _, _ in showCopyNotice() }
        .task(id: channel.copies) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copyNotice = nil }
        }
        .alert("Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?", isPresented: $pasteConfirmation) {
            Button("Cancel", role: .cancel) { pendingPaste = nil }
            Button("Paste") {
                guard let text = pendingPaste else { return }
                pendingPaste = nil
                do { try channel.paste(text, confirmed: true) } catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
            }
        } message: { Text("This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.") }
        .alert("Paste Not Sent", isPresented: Binding(get: { pasteFailure != nil }, set: { if !$0 { pasteFailure = nil } })) {
            Button("OK", role: .cancel) { pasteFailure = nil }
        } message: { Text(pasteFailure ?? "") }
    }

    /// Done and error read as Idle while on screen, Stopped once the channel has closed.
    private var programIsStopped: Bool { !channel.connected && !channel.connecting }

    private var programRollup: SessionStatusRollup? {
        SSHTerminalProgramStatusPresentation.rollup(
            store: channel.programStatus,
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
        )
    }

    /// The highest-priority notice the person has not folded away.
    private var visibleNotice: SSHTerminalNotice? {
        attention.notice(from: SSHTerminalAttention.candidates(
            programStatus: channel.programStatus, alerts: channel.alerts, isStopped: programIsStopped
        ))
    }

    private var programStatusRows: [SSHTerminalStatusRow] {
        SSHTerminalProgramStatusPresentation.detailRows(
            store: channel.programStatus,
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
        )
    }

    private var statusText: String {
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private var pasteLineCount: Int { SSHTerminalEngine.pasteLineCount(pendingPaste ?? "") }

    /// Chat bar keyboard button and Type in Terminal: stay in direct typing and
    /// open the keyboard. A later tap opens it again, even if the app wants clicks.
    private func showTerminalKeyboard() {
        modeOverride = .terminal
        keyboardRequest += 1
    }

    private func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Close rather than silently losing bytes while suspended.
            // Host tmux or Herdr preserves the remote work.
            guard channel.connected else { return }
            reconnectOnReturn = true
            channel.close(reason: "Oppi went to the background.")
        case .active:
            reconnectAfterReturn()
        default:
            break
        }
    }

    private func showCopyNotice() {
        let count = channel.lastCopyLength
        copyNotice = "Copied \(count) \(count == 1 ? "character" : "characters")"
    }

    /// A fresh sign-in, with the same Face ID or password approval as
    /// Reconnect. The flag stays set until App Lock no longer covers Oppi.
    private func reconnectAfterReturn() {
        guard reconnectOnReturn, scenePhase == .active, !AppLockService.shared.requiresUnlock() else { return }
        reconnectOnReturn = false
        reconnect()
    }

    private func setTopBarHidden(_ hidden: Bool) {
        guard hidden != topBarHidden else { return }
        withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
            topBarHidden = hidden
        }
    }

    /// Use Chat Bar, from the menu or the terminal keyboard. Clears a typing
    /// override when the foreground program already wants the chat bar.
    private func showChatBar() {
        modeOverride = detectedMode == .chat ? nil : .chat
        focusComposerAfterRaw = true
        resignRawKeyboardRequest += 1
    }

    private func showPasteNotice(_ text: String) {
        pasteNotice = text
        pasteNoticeTask?.cancel()
        pasteNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { pasteNotice = nil }
        }
    }

    private func requestPaste() {
        guard channel.connected else { channel.send(Data()); return }
        // Nil when the clipboard holds no text or iOS refused the read.
        guard let text = UIPasteboard.general.string else {
            showPasteNotice("Nothing pasted \u{2014} the clipboard has no text, or paste access was not allowed.")
            return
        }
        guard text.utf8.count <= SSHTerminalEngine.maximumPasteBytes else {
            pasteFailure = "Pastes are limited to 64 KiB."
            return
        }
        if SSHTerminalEngine.pasteNeedsConfirmation(text) {
            pendingPaste = text
            pasteConfirmation = true
        } else {
            do { try channel.paste(text) } catch { pasteFailure = "Paste was not sent. \(error.localizedDescription)" }
        }
    }
}

/// Showing or hiding the navigation bar resizes the remote terminal, so a
/// history drag must not do it. A pull counts only when it is long enough and
/// mostly vertical. Finger down is show; finger up is hide. The reveal handle
/// commits show only.
enum SSHTerminalTopBarGesture {
    /// Shorter than a nav-bar height. The old 24pt scroll threshold resized
    /// the terminal on an ordinary history nudge.
    static let minimumTravel: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.35

    enum Action: Equatable {
        case show
        case hide
    }

    static func action(translation: CGSize) -> Action? {
        let vertical = translation.height
        guard abs(vertical) >= minimumTravel else { return nil }
        guard abs(vertical) > abs(translation.width) * dominanceRatio else { return nil }
        return vertical > 0 ? .show : .hide
    }
}

/// The way back after Hide Bar. A tap shows the bar; a downward pull does too.
/// It is not a scroll catcher: a short or sideways drag leaves the bar hidden.
private struct SSHTerminalTopBarHandle: View {
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.themeFg)
                .frame(width: 52, height: 22)
                .themedSurface(.floatingControl, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show terminal bar")
        .accessibilityHint("Shows the host name, Herdr, and terminal actions")
        .accessibilityIdentifier("sshTerminal.showBar")
        // The commit distance, not a short slip, so a tap still reaches the button.
        .simultaneousGesture(
            DragGesture(minimumDistance: SSHTerminalTopBarGesture.minimumTravel)
                .onEnded { value in
                    guard SSHTerminalTopBarGesture.action(translation: value.translation) == .show else { return }
                    show()
                }
        )
    }
}

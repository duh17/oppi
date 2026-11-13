import UIKit

/// The bottom bar's Dictate button: the composer's dictation pipeline
/// (`ComposerShared`, `VoiceInputManager.shared`) with the terminal's shell as
/// the text it fills. The engine is the person's Voice preference (on-device or
/// server), read again at every start, and the microphone permission prompts
/// are the manager's own.
///
/// The words reach the shell once, when the take stops: `type` gets the final
/// transcript, sent like the keyboard's own dictation (no Return). Nothing is
/// typed while the person speaks. A shell line cannot be edited like a text
/// field: rewriting a guess means backspacing over what the program echoed,
/// and a program that moved the cursor, drew a suggestion, or redrew its input
/// box (an agent's TUI) would lose its own text to those backspaces. The server
/// engine also revises words it already showed until the take ends. Typing the
/// settled take once keeps the line free of half-heard words.
///
/// A take belongs to the terminal on screen: switching terminals or leaving the
/// screen drops it (`release`), so its words never land in a shell the person
/// no longer sees.
@MainActor
final class SSHTerminalDictation {
    static let owner = ComposerShared.VoiceInputOwner.terminal

    let manager: VoiceInputManager
    /// Types the take's text into the terminal.
    var type: (String) -> Void = { _ in }
    /// A take that could not start, with the reason.
    var startFailed: (String) -> Void = { _ in }
    private var generation: Int?

    init(manager: VoiceInputManager = .shared) {
        self.manager = manager
    }

    /// What the button draws. Read in `updateProperties`, so Observation
    /// redraws the button as the take moves.
    var presentation: ComposerShared.MicButtonPresentation {
        ComposerShared.micButtonPresentation(for: manager, owner: Self.owner)
    }

    /// This terminal's take failed while it ran; the manager clears it on its own timer.
    var captureFailure: VoiceCaptureFailure? {
        ComposerShared.captureFailure(manager, owner: Self.owner)
    }

    /// The button's one action: start a take, stop the one running (typing its
    /// words), or cancel one still starting. Another owner's take blocks it.
    func toggle(connection: ServerConnection?) async {
        guard ComposerShared.canControlVoiceInput(manager, owner: Self.owner) else { return }
        switch ComposerShared.micTapAction(for: manager.state) {
        case .start:
            await start(connection: connection)
        case .stop:
            // No text before the take: `setText` gets the take alone, and only when it is not empty.
            await ComposerShared.stopVoiceInput(
                manager: manager,
                setText: { [weak self] in self?.type($0) },
                getTextBeforeRecording: { nil },
                setTextBeforeRecording: { _ in }
            )
        case .cancelPreparing:
            await ComposerShared.cancelVoiceInput(
                manager: manager, setTextBeforeRecording: { _ in }, setSuppressKeyboard: { _ in }
            )
        case .ignore:
            break
        }
    }

    private func start(connection: ServerConnection?) async {
        do {
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: nil,
                owner: Self.owner,
                baseText: "",
                setTextBeforeRecording: { _ in },
                setSuppressKeyboard: { _ in },
                getFocusRequestID: { 0 },
                setFocusRequestID: { _ in },
                prepare: { [weak self] in self?.claim(connection: connection) }
            )
        } catch is CancellationError {
        } catch {
            startFailed(error.localizedDescription)
        }
    }

    /// Points the shared manager at this server (the server engine's
    /// credentials and dictionary) and at the current engine preference.
    private func claim(connection: ServerConnection?) {
        manager.loadPreferences()
        let serverId = connection?.currentServerId ?? connection?.credentials.map { "\($0.host):\($0.port)" } ?? ""
        generation = ComposerShared.prepareStandaloneVoiceInput(
            manager: manager,
            serverId: serverId,
            credentials: connection?.credentials,
            connection: connection,
            playbackInterrupter: connection?.audioPlayer,
            ownedGeneration: generation
        )
    }

    /// Drops this terminal's take, if one runs, and gives the manager back.
    func release() {
        let take = ComposerShared.takeIdentityForDismissedComposer(manager: manager, generation: generation)
        if let generation {
            manager.endComposer(generation: generation)
            self.generation = nil
        }
        let manager = manager
        Task { await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: take) }
    }
}

/// Dictate in the bar's pill: the mic at rest, and the composer's own mic
/// chrome (`MicButtonChromeView`: the dictation orb or ring, per Settings)
/// in its place while a take starts, listens, or finishes. The button is one
/// control and one accessibility element whatever it draws, so a tap, the
/// pill's touch strip, and VoiceOver all reach `onTap`, which stops a take
/// that listens.
final class SSHTerminalDictateButton: UIControl {
    /// The orb's side: the pill's height less a little air.
    private static let orbDiameter: CGFloat = SSHTerminalGlassPill.height - 4

    var onTap: () -> Void = {}

    private let rest = SSHTerminalPillButton(
        systemName: SSHTerminalBarAction.dictate.symbol,
        label: SSHTerminalBarAction.dictate.accessibilityLabel,
        identifier: ""
    )
    private let mic = MicButtonChromeView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for part in [rest, mic] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            part.isUserInteractionEnabled = false
            part.isAccessibilityElement = false
            addSubview(part)
        }
        mic.isHidden = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = SSHTerminalBarAction.dictate.accessibilityIdentifier
        accessibilityLabel = SSHTerminalBarAction.dictate.accessibilityLabel
        showsLargeContentViewer = true
        largeContentTitle = accessibilityLabel
        largeContentImage = UIImage(systemName: SSHTerminalBarAction.dictate.symbol)
        addAction(UIAction { [weak self] _ in self?.onTap() }, for: .touchUpInside)
        // Below required: a hidden item in the pill's stack collapses to zero.
        let width = widthAnchor.constraint(equalToConstant: SSHTerminalGlassPill.itemWidth)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: SSHTerminalGlassPill.height),
            rest.leadingAnchor.constraint(equalTo: leadingAnchor),
            rest.trailingAnchor.constraint(equalTo: trailingAnchor),
            rest.topAnchor.constraint(equalTo: topAnchor),
            rest.bottomAnchor.constraint(equalTo: bottomAnchor),
            mic.centerXAnchor.constraint(equalTo: centerXAnchor),
            mic.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.82 : (isEnabled ? 1 : 0.45) }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.45 }
    }

    /// Whether the take shows as the orb (starting, listening, or finishing).
    var showsTake: Bool { !mic.isHidden }

    func apply(tint: UIColor) {
        rest.apply(tint: tint)
    }

    /// Draws `presentation` (this terminal's take, from `SSHTerminalDictation`).
    /// A take another screen owns leaves the mic dimmed.
    func apply(presentation: ComposerShared.MicButtonPresentation, colors: ComposerThemeColors) {
        let active = presentation.isRecording || presentation.isPreparing || presentation.isProcessing
        rest.isHidden = active
        mic.isHidden = !active
        isEnabled = presentation.isEnabled
        if active {
            mic.colors = colors
            mic.apply(presentation: presentation, accentColor: colors.blue, diameter: Self.orbDiameter)
        }
        accessibilityLabel = if presentation.isProcessing {
            String(localized: "Finishing dictation")
        } else if active {
            String(localized: "Stop dictation")
        } else {
            SSHTerminalBarAction.dictate.accessibilityLabel
        }
        accessibilityValue = active ? presentation.accessibilityValue : nil
        largeContentTitle = accessibilityLabel
    }
}

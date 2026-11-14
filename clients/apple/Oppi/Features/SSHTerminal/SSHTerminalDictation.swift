import UIKit

/// The bottom bar's Dictate button: the composer's dictation pipeline
/// (`ComposerShared`, `VoiceInputManager.shared`) with the terminal's shell as
/// the text it fills. The engine is the person's Voice preference (on-device or
/// server), read again at every start, and the microphone permission prompts
/// are the manager's own.
///
/// Words reach the shell while the person speaks, but only once they are
/// stable (`SSHTerminalDictationCommitter`): `type` gets each stable stretch,
/// sent like the keyboard's own dictation (no Return), and the words still
/// changing show in `provisional` above the bar, untyped. Stop types the rest
/// of the final transcript. Nothing typed is ever taken back: a shell line
/// cannot be edited like a text field, since backspacing over a guess would
/// also erase what a program drew there (a suggestion, an agent's redrawn
/// input box), so a later revision of typed words is not applied.
///
/// A take belongs to the terminal on screen: switching terminals or leaving the
/// screen drops it (`release`), so no more of its words land in a shell the
/// person no longer sees.
@MainActor @Observable
final class SSHTerminalDictation {
    static let owner = ComposerShared.VoiceInputOwner.terminal

    @ObservationIgnored let manager: VoiceInputManager
    /// Types the take's text into the terminal.
    @ObservationIgnored var type: (String) -> Void = { _ in }
    /// A take that could not start, with the reason.
    @ObservationIgnored var startFailed: (String) -> Void = { _ in }
    /// The words of the running take not typed yet, which the recogniser may
    /// still change. Empty between takes.
    private(set) var provisional = ""
    @ObservationIgnored private var generation: Int?
    /// The running take's typing, from its start until Stop types the rest or the take ends.
    @ObservationIgnored private var live: SSHTerminalDictationCommitter?
    /// The last report `live` heard, so a refresh that changes nothing is not
    /// counted as the recogniser repeating itself.
    @ObservationIgnored private var lastHeard: VoiceInputManager.RecognizedTranscript?
    /// The manager has run this terminal's take since `live` began.
    @ObservationIgnored private var heldTake = false
    /// Which take `follow` follows, so one take's late change cannot start a
    /// second loop beside the next take's.
    @ObservationIgnored private var followedTake = 0
    /// Stop is waiting for the final transcript; the take's end is Stop's to handle.
    @ObservationIgnored private var stopping = false

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
            stopping = true
            var final = ""
            await ComposerShared.stopVoiceInput(
                manager: manager, setText: { final = $0 }, getTextBeforeRecording: { nil }, setTextBeforeRecording: { _ in }
            )
            stopping = false
            finish(final)
        case .cancelPreparing:
            endLive()
            await ComposerShared.cancelVoiceInput(
                manager: manager, setTextBeforeRecording: { _ in }, setSuppressKeyboard: { _ in }
            )
        case .ignore:
            break
        }
    }

    private func start(connection: ServerConnection?) async {
        live = SSHTerminalDictationCommitter()
        followedTake += 1
        follow(take: followedTake)
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
            endLive()
        } catch {
            endLive()
            startFailed(error.localizedDescription)
        }
    }

    /// Feeds each new report of this terminal's take to `live` and types what
    /// became stable, until the take ends.
    private func follow(take: Int) {
        guard live != nil, take == followedTake else { return }
        let heard = withObservationTracking {
            ComposerShared.ownsVoiceInput(manager, owner: Self.owner) ? manager.recognizedTranscript : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(take: take) }
        }
        if let heard {
            heldTake = true
            guard heard != lastHeard, var committer = live else { return }
            lastHeard = heard
            let chunk = committer.hear(heard.text, settled: heard.settledCount)
            live = committer
            provisional = committer.provisional
            if !chunk.isEmpty { type(chunk) }
        } else if heldTake, !stopping {
            // The take ended without Stop (it failed, or another screen took the
            // microphone): what was typed stays, and nothing more is.
            endLive()
        }
    }

    /// Stop's end of the take: types what of `final` is not in the shell yet.
    private func finish(_ final: String) {
        guard var committer = live else { return }
        endLive()
        let tail = committer.finish(final)
        if !tail.isEmpty { type(tail) }
    }

    private func endLive() {
        live = nil
        lastHeard = nil
        heldTake = false
        if !provisional.isEmpty { provisional = "" }
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
        endLive()
        let take = ComposerShared.takeIdentityForDismissedComposer(manager: manager, generation: generation)
        if let generation {
            manager.endComposer(generation: generation)
            self.generation = nil
        }
        let manager = manager
        Task { await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: take) }
    }
}

/// What of a running take reaches the shell, and when. A recogniser revises
/// the end of what it heard, and a shell line cannot take typed words back, so
/// a word is typed only once it is stable:
///
/// - the recogniser settled it (`settled`: on-device final results, the
///   server's committed segments), or
/// - it was the same, with the same words before it and another after it, in
///   the last `agreement` reports.
///
/// Each `hear` returns the text between the last typed word and the newest
/// stable one, spaces and punctuation as the recogniser wrote them, and
/// `provisional` keeps the words after it. Words stay as typed: when the
/// recogniser later revises one, typing goes on after the part of the new text
/// that lines up with what was typed (`resume`), so a corrected, merged, or
/// split word is neither typed twice nor skipped past its neighbours. Text that
/// only grew onto the last typed word (a comma, a full stop, a changed
/// capital) is added to it. A line break or control character stops live
/// typing there; `finish` types the rest of the final transcript, which goes
/// through the paste confirmation.
///
/// Chinese and Japanese write no spaces, so each of their characters is a word
/// of its own.
struct SSHTerminalDictationCommitter {
    /// Reports a word must survive, unchanged and followed by another, to be
    /// typed before the recogniser settles it.
    static let agreement = 3

    /// The stable start of the take that the shell has, as the recogniser
    /// spelled it when it last moved. After a revision of typed words it is
    /// spelled as the recogniser revised it, not as the shell shows it.
    private(set) var typed = ""
    /// The take's words that are not typed yet, as last heard.
    private(set) var provisional = ""
    private var recent: [[Substring]] = []

    /// A report of the whole take so far, whose first `settled` characters the
    /// recogniser will not revise. Returns the text to type now.
    mutating func hear(_ text: String, settled: Int) -> String {
        let words = Self.words(in: text)
        recent.append(words.map { text[$0] })
        if recent.count > Self.agreement { recent.removeFirst() }
        let settledEnd = text.index(text.startIndex, offsetBy: max(0, min(settled, text.count)))
        var stable = max(words.prefix { $0.upperBound <= settledEnd }.count, Self.agreedWords(recent))
        let typable = text.firstIndex(where: Self.isControl) ?? text.endIndex
        while stable > 0, words[stable - 1].upperBound > typable { stable -= 1 }
        var untyped = Self.resume(after: typed, in: text, words: words)
        var chunk = ""
        if stable > 0, untyped < words[stable - 1].upperBound {
            let end = words[stable - 1].upperBound
            chunk = String(text[untyped..<end])
            typed = String(text[..<end])
            untyped = end
        }
        provisional = text[untyped...].trimmingCharacters(in: .whitespacesAndNewlines)
        return chunk
    }

    /// The final transcript: returns the rest of it to type.
    mutating func finish(_ text: String) -> String {
        let words = Self.words(in: text)
        provisional = ""
        guard let end = words.last?.upperBound else { return "" }
        let resume = Self.resume(after: typed, in: text, words: words)
        guard resume < end else { return "" }
        typed = String(text[..<end])
        return String(text[resume..<end])
    }

    /// Where the text not typed yet starts in `text`: just past the stretch
    /// that lines up with `typed`. A word revised after it was typed stays as
    /// typed, so the rest of that word is skipped and typing resumes at the
    /// space after it.
    static func resume(after typed: String, in text: String, words: [Range<String.Index>]) -> String.Index {
        if text.hasPrefix(typed) { return text.index(text.startIndex, offsetBy: typed.count) }
        let (end, exact) = alignedEnd(of: typed, in: text)
        // Same letters (only the case changed): what follows grew onto the typed word.
        if exact { return end }
        if let word = words.first(where: { $0.lowerBound < end && end < $0.upperBound }) { return word.upperBound }
        // Back to the end of the last word before it, so the space before the next word is typed.
        return words.last { $0.upperBound <= end }?.upperBound ?? text.startIndex
    }

    /// The end of the start of `text` closest to `typed`, letters compared
    /// without case, and whether they match exactly. Past their shared start,
    /// an edit distance in which `text` may end anywhere: revisions are near
    /// the end of what was typed, so the table stays small.
    private static func alignedEnd(of typed: String, in text: String) -> (String.Index, exact: Bool) {
        let a = typed.map { $0.lowercased() }
        let b = text.map { $0.lowercased() }
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        guard shared < a.count else { return (text.index(text.startIndex, offsetBy: shared), true) }
        var previous = Array(0...(b.count - shared))
        var current = previous
        for i in shared..<a.count {
            current[0] = i - shared + 1
            for j in shared..<b.count {
                let column = j - shared + 1
                current[column] = min(
                    previous[column - 1] + (a[i] == b[j] ? 0 : 1),
                    previous[column] + 1,
                    current[column - 1] + 1
                )
            }
            swap(&previous, &current)
        }
        let best = previous.indices.min { previous[$0] < previous[$1] } ?? 0
        return (text.index(text.startIndex, offsetBy: shared + best), false)
    }

    /// Leading words every one of the last `agreement` reports has, each
    /// followed by another word in all of them.
    private static func agreedWords(_ recent: [[Substring]]) -> Int {
        guard recent.count == agreement, let shortest = recent.map(\.count).min() else { return 0 }
        var count = 0
        while count < shortest - 1, recent.allSatisfy({ $0[count] == recent[0][count] }) { count += 1 }
        return count
    }

    /// The words of `text`: runs between spaces, with each Chinese or Japanese
    /// character a word of its own.
    static func words(in text: String) -> [Range<String.Index>] {
        var words: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isWhitespace || isUnspaced(character) {
                if let open = start { words.append(open..<index) }
                start = nil
                if !character.isWhitespace { words.append(index..<next) }
            } else if start == nil {
                start = index
            }
            index = next
        }
        if let open = start { words.append(open..<text.endIndex) }
        return words
    }

    /// Han, kana, CJK punctuation, and full-width forms.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        return switch scalar.value {
        case 0x3000...0x30FF, 0x31F0...0x31FF, 0xFF00...0xFFEF: true
        default: false
        }
    }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
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

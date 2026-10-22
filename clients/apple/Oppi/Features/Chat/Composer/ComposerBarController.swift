import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// A Live Voice call running in the chat input bar. The mic slot shows the dictation ring
/// or orb, live, and a tap mutes; the field shows what the user is saying until it is sent;
/// End takes the send slot, with Send beside it once something is typed.
@MainActor
struct ComposerLiveVoiceCall {
    static let muteIdentifier = "chat.liveVoice.mute"
    static let endIdentifier = "chat.liveVoice.end"
    static let stateIdentifier = "chat.liveVoice.state"

    /// False after a failed call: the reason stays in the field until End.
    var isLive: Bool
    var isConnecting: Bool
    var isMuted: Bool
    /// The agent's reply is playing; the orb follows its voice in the agent's color.
    var isSpeaking: Bool
    /// The placeholder: the call's state, an approval to answer, or why it failed.
    var status: String
    /// What the user is saying, read-only until the server sends it as their message.
    var transcript: String
    var meter: LiveVoiceAudioMeter
    var onToggleMute: () -> Void
    var onEnd: () -> Void
}

/// Snapshot the representable lowers into UIKit. No SwiftUI types.
@MainActor
struct ComposerBarContent {
    var text: String
    var textBeforeRecording: String?
    var pendingAttachments: [PendingAttachment]
    var pendingRepoPointers: [PendingFileReference]
    var isBusy: Bool
    var busyStreamingBehavior: StreamingBehavior
    var isSending: Bool
    var pendingReviewCommentCount: Int
    var placeholderOverride: String?
    var allowsEmptySubmit: Bool
    var sendProgressText: String?
    var isStopping: Bool
    var voiceInputManager: VoiceInputManager?
    /// Non-nil adds Live Voice to the mic button's long-press menu; tap stays dictation.
    var onLiveVoiceSelected: (() -> Void)? = nil
    /// Non-nil while a Live Voice call runs in this bar.
    var liveVoiceCall: ComposerLiveVoiceCall? = nil
    var showForceStop: Bool
    var isForceStopInFlight: Bool
    var askRequest: AskRequest?
    var slashCommands: [SlashCommand]
    var fileSuggestions: [FileSuggestion]
    var appliesOuterPadding: Bool
    var alwaysShowActionRow: Bool
    var allowsExpansion: Bool
    var allowsAttachments: Bool
    var attachmentButtonPlacement: ComposerAttachmentButtonPlacement
    var actionRowMinimumHeight: CGFloat
    var showsAccessoryRow: Bool
    var autocorrectionEnabled: Bool
    var inputAccessibilityIdentifier: String
    var sendAccessibilityIdentifier: String
    var actionRow: ComposerActionRow
    var colors: ComposerThemeColors
    var reduceMotion: Bool
    var suppressKeyboard: Bool
    var focusRequestID: Int
    var keyboardLanguage: String?
    var keyStripHeight: CGFloat
    var mediaImportEpoch: UInt64
}

@MainActor
protocol ComposerBarHosting: AnyObject {
    var content: ComposerBarContent { get }
    func setText(_ text: String)
    func setTextBeforeRecording(_ value: String?)
    func setPendingAttachments(_ value: [PendingAttachment])
    func setPendingRepoPointers(_ value: [PendingFileReference])
    func setBusyStreamingBehavior(_ value: StreamingBehavior)
    func setSuppressKeyboard(_ value: Bool)
    func consumeFocusRequest()
    func setKeyboardLanguage(_ value: String?)
    func setInputFocused(_ value: Bool)
    func performSend()
    func performStop()
    func performForceStop()
    func performExpand()
    func submitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    )
    func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion)
    func startVoice(
        keyboardLanguage: String?,
        owner: ComposerShared.VoiceInputOwner,
        baseText: String
    ) async throws
    func stopVoice() async
    func cancelVoice() async
    func finishVoiceBeforeSubmit() async
    func handlePastedImages(_ images: [UIImage])
    func insertSlashCommand(_ command: SlashCommand)
    func insertFileSuggestion(_ suggestion: FileSuggestion)
    func removeAttachment(id: String)
    func removeRepoPointer(id: String)
    func importPhotoProviders(
        _ providers: [NSItemProvider],
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    )
    func addCapturedImage(_ image: UIImage)
    func applyCanvas(
        attachment: PendingAttachment,
        recognizedText: String,
        replacingAttachmentID: String?
    ) -> Bool
    func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    )
    func notifyFileSuggestionContext(for text: String)
    func discardFailedVoiceTake()
    func restoreKeyboardFromSuppression()
    var askAutoAdvanceController: AskInlineAutoAdvanceController? { get }
    /// The bar's fitted height changed outside the host's own update (the
    /// Ask card measured itself): measure the bar again.
    func barHeightDidChange()
}

extension ComposerBarHosting {
    var askAutoAdvanceController: AskInlineAutoAdvanceController? { nil }
    func barHeightDidChange() {}
}

/// Emoji / asset / symbol workspace mark plus the sandbox lock. UIKit counterpart
/// of `WorkspaceRuntimeIcon`.
enum WorkspaceRuntimeIconRenderer {
    static func render(
        workspace: Workspace,
        size: CGFloat,
        frameSize: CGFloat,
        colors: ComposerThemeColors
    ) -> UIImage {
        let icon = renderIcon(workspace.icon, size: size, colors: colors)
        let canvas = CGSize(width: frameSize, height: frameSize)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let origin = CGPoint(x: (frameSize - size) / 2, y: (frameSize - size) / 2)
            icon.draw(in: CGRect(origin: origin, size: CGSize(width: size, height: size)))
            if workspace.runtime == .sandbox {
                let markSize = max(11, frameSize * 0.34)
                let mark = sandboxMark(size: markSize, colors: colors)
                let x = frameSize - markSize + frameSize * 0.05
                let y = frameSize - markSize + frameSize * 0.05
                mark.draw(in: CGRect(x: x, y: y, width: markSize, height: markSize))
            }
        }
    }

    private static func renderIcon(_ icon: IconChoice?, size: CGFloat, colors: ComposerThemeColors) -> UIImage {
        switch AgentIconContent.resolve(icon) {
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .medium)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(colors.blue, renderingMode: .alwaysOriginal)
                ?? folder(size: size, colors: colors)
        case .text(let emoji):
            return renderText(emoji, size: size)
        case .genmoji, .fallback:
            return folder(size: size, colors: colors)
        }
    }

    private static func folder(size: CGFloat, colors: ComposerThemeColors) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .semibold)
        return UIImage(systemName: "folder", withConfiguration: configuration)?
            .withTintColor(colors.blue, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    private static func renderText(_ text: String, size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.78),
            ]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private static func sandboxMark(size: CGFloat, colors: ComposerThemeColors) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            colors.orange.setFill()
            UIBezierPath(ovalIn: rect).fill()
            colors.bg.setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.52, weight: .bold)
            let lock = UIImage(systemName: "lock.fill", withConfiguration: config)?
                .withTintColor(colors.bg, renderingMode: .alwaysOriginal)
            let lockSize = lock?.size ?? .zero
            lock?.draw(
                at: CGPoint(x: (size - lockSize.width) / 2, y: (size - lockSize.height) / 2)
            )
        }
    }
}

/// Thinking-level list plus optional "Save as Default". UIKit so the composer
/// never hosts SwiftUI inside a popover. The rows scroll inside whatever height
/// the popover gets: an iPhone in landscape leaves little room above the
/// keyboard, and every level must stay reachable.
final class ComposerThinkingPickerController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private var levels: [ThinkingLevel]
    private var selected: ThinkingLevel
    private var onSelect: (ThinkingLevel) -> Void
    private var onSaveDefault: (() -> Void)?
    private let colors: ComposerThemeColors
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) {
        self.levels = levels
        self.selected = selected
        self.colors = colors
        self.onSelect = onSelect
        self.onSaveDefault = onSaveDefault
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colors.bg
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "session.toolbar.thinking.scroll"
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        rebuild()
    }

    func apply(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) {
        self.levels = levels
        self.selected = selected
        self.onSelect = onSelect
        self.onSaveDefault = onSaveDefault
        rebuild()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for level in levels.reversed() {
            stack.addArrangedSubview(row(
                title: level.displayTitle,
                selected: level == selected,
                identifier: "session.toolbar.thinking.option.\(level.rawValue)",
                label: level.displayTitle
            ) { [weak self] in
                guard let self else { return }
                self.dismiss(animated: true)
                if level != self.selected {
                    self.onSelect(level)
                }
            })
        }
        if let onSaveDefault {
            let divider = UIView()
            divider.backgroundColor = colors.comment.withAlphaComponent(0.22)
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            let wrap = UIView()
            wrap.addSubview(divider)
            NSLayoutConstraint.activate([
                divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                divider.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
                divider.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
            ])
            stack.addArrangedSubview(wrap)
            stack.addArrangedSubview(row(
                title: "Save as Default",
                selected: false,
                identifier: "session.toolbar.thinking.saveDefault",
                label: "Save thinking level as default",
                showsCheck: false
            ) { [weak self] in
                self?.dismiss(animated: true)
                onSaveDefault()
            })
        }
        let rows = CGFloat(levels.count + (onSaveDefault == nil ? 0 : 1))
        preferredContentSize = CGSize(width: 220, height: 12 + rows * 44 + (onSaveDefault == nil ? 0 : 9))
    }

    private func row(
        title: String,
        selected: Bool,
        identifier: String,
        label: String,
        showsCheck: Bool = true,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.fg
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        config.title = title
        config.titleAlignment = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .body)
            return outgoing
        }
        if showsCheck {
            config.image = UIImage(systemName: "checkmark")
            config.imagePlacement = .trailing
            config.imagePadding = 10
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.configuration = config
            button.configuration?.image = selected
                ? UIImage(systemName: "checkmark")
                : UIImage()
        } else {
            button.configuration = config
        }
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = label
        button.accessibilityValue = selected ? "Selected" : ""
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

@MainActor
extension ComposerThinkingPickerController {
    /// The thinking levels beside a composer's thinking pill. One presentation
    /// for the bar, the expanded composer, and the stacked action controls, so
    /// their popovers cannot drift apart.
    static func present(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?,
        from presenter: UIViewController,
        sourceView: UIView
    ) {
        Router.present(
            make(levels: levels, selected: selected, colors: colors, onSelect: onSelect, onSaveDefault: onSaveDefault),
            presentation: .popover.arrowDirections(.down).keepsPopoverInCompactWidth(),
            from: presenter,
            sourceView: sourceView
        )
    }

    /// The same picker as a router modal slot: Quick Session's stacked action
    /// controls keep it live while it is open.
    static func liveScreen(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) -> RouterScreen {
        .liveController({
            make(levels: levels, selected: selected, colors: colors, onSelect: onSelect, onSaveDefault: onSaveDefault)
        }, update: { picker in
            picker.apply(levels: levels, selected: selected, onSelect: onSelect, onSaveDefault: onSaveDefault)
        })
    }

    /// The picker every thinking entry point builds, so the arguments that make
    /// it (and the `apply` that refreshes it) stay one list.
    static func make(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) -> ComposerThinkingPickerController {
        ComposerThinkingPickerController(
            levels: levels,
            selected: selected,
            colors: colors,
            onSelect: onSelect,
            onSaveDefault: onSaveDefault
        )
    }
}

/// Busy-mode list. Same chrome as thinking, identifiers `chat.busyMode.option.*`.
final class ComposerBusyModePickerController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private var selected: StreamingBehavior
    private var onSelect: (StreamingBehavior) -> Void
    private let colors: ComposerThemeColors

    init(
        selected: StreamingBehavior,
        colors: ComposerThemeColors,
        onSelect: @escaping (StreamingBehavior) -> Void
    ) {
        self.selected = selected
        self.colors = colors
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 190, height: 12 + 88)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colors.bg
        let stack = UIStackView(arrangedSubviews: [
            option(.steer, title: "Steering"),
            option(.followUp, title: "Follow-up"),
        ])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    private func option(_ behavior: StreamingBehavior, title: String) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.fg
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        config.title = title
        config.titleAlignment = .leading
        config.imagePlacement = .trailing
        config.imagePadding = 10
        config.image = behavior == selected ? UIImage(systemName: "checkmark") : UIImage()
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .body)
            return outgoing
        }
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = title
        button.accessibilityValue = behavior == selected ? "Selected" : ""
        button.accessibilityIdentifier = "chat.busyMode.option.\(behavior.rawValue)"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true)
            FeatureEducationTips.markBusySendModeUsed()
            if behavior != self.selected {
                self.onSelect(behavior)
            }
        }, for: .touchUpInside)
        return button
    }
}

/// Agent (and similar) popover list. UIKit so it can refresh while open without
/// `HostFactory.setContent` joining a SwiftUI update.
final class ComposerOptionListController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private var rows: [ComposerOptionRow]
    private var isLoading: Bool
    private var emptyMessage: String
    private var onSelect: (String) -> Void
    private let colors: ComposerThemeColors
    private let preferredWidth: CGFloat
    private let stack = UIStackView()

    init(
        rows: [ComposerOptionRow],
        isLoading: Bool,
        emptyMessage: String,
        colors: ComposerThemeColors,
        preferredWidth: CGFloat = 280,
        onSelect: @escaping (String) -> Void
    ) {
        self.rows = rows
        self.isLoading = isLoading
        self.emptyMessage = emptyMessage
        self.colors = colors
        self.preferredWidth = preferredWidth
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colors.bg
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        rebuild()
    }

    func apply(rows: [ComposerOptionRow], isLoading: Bool, emptyMessage: String, onSelect: @escaping (String) -> Void) {
        self.rows = rows
        self.isLoading = isLoading
        self.emptyMessage = emptyMessage
        self.onSelect = onSelect
        rebuild()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isLoading && rows.isEmpty {
            let label = UILabel()
            label.text = "Loading…"
            label.font = UIFont.preferredFont(forTextStyle: .subheadline)
            label.textColor = colors.comment
            label.numberOfLines = 0
            let pad = padded(label, h: 14, v: 12)
            stack.addArrangedSubview(pad)
        } else if rows.isEmpty {
            let label = UILabel()
            label.text = emptyMessage
            label.font = UIFont.preferredFont(forTextStyle: .subheadline)
            label.textColor = colors.comment
            label.numberOfLines = 0
            stack.addArrangedSubview(padded(label, h: 14, v: 12))
        } else {
            for row in rows {
                stack.addArrangedSubview(makeRow(row))
            }
        }
        let height = isLoading && rows.isEmpty
            ? 64
            : min(320, 16 + CGFloat(max(rows.count, 1)) * 52)
        preferredContentSize = CGSize(width: preferredWidth, height: height)
    }

    private func makeRow(_ row: ComposerOptionRow) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.fg
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.title = row.title
        config.subtitle = row.subtitle
        config.titleAlignment = .leading
        config.imagePlacement = .leading
        config.imagePadding = 10
        config.image = row.icon
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if row.isSelected {
            let check = UIImage(systemName: "checkmark")
            config.image = row.icon
            button.configuration = config
            let checkView = UIImageView(image: check)
            checkView.tintColor = colors.blue
            checkView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(checkView)
            NSLayoutConstraint.activate([
                checkView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
                checkView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        } else {
            button.configuration = config
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            outgoing.foregroundColor = self.colors.comment
            return outgoing
        }
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = row.accessibilityLabel ?? row.title
        if row.isSelected {
            button.accessibilityTraits.insert(.selected)
        }
        button.accessibilityIdentifier = row.accessibilityIdentifier
        let id = row.id
        button.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
            self?.onSelect(id)
        }, for: .touchUpInside)
        return button
    }

    private func padded(_ view: UIView, h: CGFloat, v: CGFloat) -> UIView {
        let wrap = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: h),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -h),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: v),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -v),
        ])
        return wrap
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

@MainActor
final class ComposerBarController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    weak var host: ComposerBarHosting?
    /// The mic disc's colors when its owner paints the bar over something other
    /// than the app's theme (the SSH terminal over a Ghostty theme). Nil keeps
    /// the app theme's palette.
    var micColors: ComposerThemeColors?

    var askClearing = AskComposerClearingState()
    var inlineVisualLineCount = 1
    var isFinishingVoiceBeforeSend = false
    var localMediaImportEpoch: UInt64 = 0
    var isInputFocused = false
    var canvasBackgroundImage: UIImage?
    var canvasReplacingAttachmentID: String?
    private var lastAskRequestID: String?
    private var lastSending = false
    /// The SwiftUI bar showed expand from the fourth visual line (its rounding
    /// counted one line ahead of a threshold of five); keep that feel.
    let expandVisibilityLineThreshold = 4
    let composerHorizontalPadding: CGFloat = 12
    /// Text inset above and below the draft; the placeholder sits on the same line.
    let textVerticalInset: CGFloat = 6

    let rootStack = UIStackView()
    let forceStopButton = ComposerForceStopButton()
    let slashPanel = ComposerSuggestionPanelView()
    let filePanel = ComposerSuggestionPanelView()
    let sendProgressView = ComposerSendProgressView()
    let failureView = ComposerDictationFailureView()
    let capsule = ComposerThemedPanelView()
    let capsuleStack = UIStackView()
    /// Ask slot: the UIKit Ask card at its natural height, capped; the card
    /// scrolls its rows inside the cap.
    let askContainer = UIView()
    var askHeightConstraint: NSLayoutConstraint?
    var askNaturalHeight: CGFloat = 0
    var askCard: AskCardViewController?
    var lastShowActionRow: Bool?
    let attachmentStrip = ComposerAttachmentStripView()
    let attachmentStripWrapper = UIView()
    let filePillStrip = ComposerFilePillStripView()
    let filePillStripWrapper = UIView()
    let textRow = UIStackView()
    let micButton = MicButtonChromeView()
    let placeholderLabel = UILabel()
    let textView = PastableUITextView()
    var textHeightConstraint: NSLayoutConstraint?
    let primaryButton = ComposerCircleActionButton()
    let endCallButton = ComposerCircleActionButton()
    let busyTipContainer = UIView()
    var busyTipHeightConstraint: NSLayoutConstraint?
    private var busyTipView: UIView?
    var busyTipNaturalHeight: CGFloat = 0
    let actionRowStack = UIStackView()
    var actionRowMinHeight: NSLayoutConstraint?
    let attachButton = ComposerGlassPillButton()
    let trailingAttachButton = ComposerGlassPillButton()
    let expandInActionRow = UIButton(type: .system)
    let busyModeButton = ComposerGlassPillButton()
    let keyStripContainer = UIView()
    var keyStripHeightConstraint: NSLayoutConstraint?
    private var keyStripView: UIView?
    let leadingScroll = ComposerPillScrollView()
    let leadingStack = ComposerPillStackView()
    let spacer = UIView()
    let trailingStack = ComposerPillStackView()
    var pillViews: [String: UIView] = [:]
    let overlayExpand = UIButton(type: .system)
    nonisolated(unsafe) private var inputModeObserver: NSObjectProtocol?
    var presentedPicker: UIViewController?
    var presentedActionID: String?
    private var presentedCover: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildHierarchy()
        installTextView()
        installActions()
        inputModeObserver = NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateKeyboardLanguage()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    deinit {
        if let inputModeObserver {
            NotificationCenter.default.removeObserver(inputModeObserver)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attemptFocusIfRequested()
    }

    override func updateProperties() {
        super.updateProperties()
        _ = AppLockService.shared.isLocked
        textView.hideFromAccessibility(whileLocked: AppLockService.shared.isLocked)
        if let manager = host?.content.voiceInputManager {
            _ = manager.state
            _ = manager.voiceSpectrum
            _ = manager.activeLanguageLabel
            _ = manager.routeIndicator
            _ = manager.transcriptPresentationRevision
            _ = manager.currentTranscript
            _ = manager.currentComposerCaptureFailure
        }
        applyMicChrome()
    }

    func sizeThatFits(width: CGFloat) -> CGSize {
        let targetWidth = max(width, 1)
        applyTextLayout(proposedWidth: targetWidth)
        if askCard != nil {
            let outer: CGFloat = host?.content.appliesOuterPadding == true ? 32 : 0
            measureAskCard(slotWidth: targetWidth - outer)
            applyAskViewport(notifyHost: false)
        }
        let target = CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height)
        return view.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    /// The bar's height with a one-line draft and none of the rows that come
    /// and go while composing: suggestions, attachments, file pills, Ask, the
    /// busy tip, send progress, and Stop. The action row counts while it
    /// shows (focus brings it, with the keyboard). A host that keeps its
    /// content's size while the draft grows (the SSH terminal) reserves this
    /// and lets the rest overlap.
    ///
    /// `fittedHeight` is `sizeThatFits(width:)` from this layout pass; the
    /// draft's growth and each shown transient row come off it. Nothing is
    /// hidden or resized to measure: the action row animates, and a stack
    /// view loses track of a hidden flag flipped under it.
    func restingHeight(fittedHeight: CGFloat, width: CGFloat) -> CGFloat {
        guard let host else { return fittedHeight }
        let control = ComposerInputMetrics.controlDiameter
        let draft = textHeightConstraint?.constant ?? oneLineTextHeight
        // The text row is as tall as its tallest item: the draft or a button.
        var transient = max(draft, control) - max(oneLineTextHeight, control)
        let rowWidth = max(width - (host.content.appliesOuterPadding ? 32 : 0), 1)
        func fitted(_ row: UIView) -> CGFloat {
            row.systemLayoutSizeFitting(
                CGSize(width: rowWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        // Above the capsule, each with the stack's spacing.
        for row in [forceStopButton, sendProgressView] as [UIView] where !row.isHidden {
            transient += fitted(row) + rootStack.spacing
        }
        for panel in [slashPanel, filePanel] where !panel.isHidden {
            transient += panel.measuredHeight + rootStack.spacing
        }
        // Inside the capsule, stacked without spacing.
        if !askContainer.isHidden { transient += askHeightConstraint?.constant ?? 0 }
        if !busyTipContainer.isHidden { transient += busyTipHeightConstraint?.constant ?? 0 }
        for strip in [attachmentStripWrapper, filePillStripWrapper] where !strip.isHidden {
            transient += fitted(strip)
        }
        return max(fittedHeight - transient, 0)
    }

    func apply() {
        guard let host else { return }
        let content = host.content
        if content.isSending && !lastSending {
            localMediaImportEpoch &+= 1
        }
        lastSending = content.isSending
        if content.askRequest?.id != lastAskRequestID {
            askClearing.applyRequestIDChange(content.askRequest?.id)
            lastAskRequestID = content.askRequest?.id
            DispatchQueue.main.async { [weak self] in
                self?.syncComposerTextWithActiveAskQuestion()
                self?.applyChrome()
            }
        }
        applyChrome()
        setNeedsUpdateProperties()
        attemptFocusIfRequested()
    }

    /// The tip view sizes nothing itself: the container's height follows
    /// `setBusyTipHeight`, and clips the tip while it is zero.
    func installBusyTip(_ tip: UIView?) {
        if busyTipView === tip { return }
        busyTipView?.removeFromSuperview()
        busyTipView = tip
        guard let tip else { return }
        tip.translatesAutoresizingMaskIntoConstraints = false
        busyTipContainer.addSubview(tip)
        NSLayoutConstraint.activate([
            tip.leadingAnchor.constraint(equalTo: busyTipContainer.leadingAnchor),
            tip.trailingAnchor.constraint(equalTo: busyTipContainer.trailingAnchor),
            tip.topAnchor.constraint(equalTo: busyTipContainer.topAnchor),
            tip.heightAnchor.constraint(equalToConstant: FeatureEducationTipBannerView.preferredHeight + 10),
        ])
    }

    /// The busy-mode tip's own height. It is zero while the tip is not
    /// presented (closed, already learned, or ineligible), so a busy bar never
    /// reserves an empty band for it.
    /// Returns whether the height changed.
    @discardableResult
    func setBusyTipHeight(_ height: CGFloat) -> Bool {
        let next = max(height, 0)
        guard abs(busyTipNaturalHeight - next) > 0.5 else { return false }
        busyTipNaturalHeight = next
        applyChrome()
        return true
    }

    func installKeyStrip(_ view: UIView?) {
        if keyStripView === view { return }
        keyStripView?.removeFromSuperview()
        keyStripView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        keyStripContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: keyStripContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: keyStripContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: keyStripContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: keyStripContainer.bottomAnchor),
        ])
    }
}

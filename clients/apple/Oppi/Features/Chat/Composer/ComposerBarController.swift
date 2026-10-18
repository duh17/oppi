import PhotosUI
import UIKit
import UniformTypeIdentifiers

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
    var askHeight: CGFloat
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
    func askSlotDidChangeHeight()
}

extension ComposerBarHosting {
    var askAutoAdvanceController: AskInlineAutoAdvanceController? { nil }
    func askSlotDidChangeHeight() {}
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
/// never hosts SwiftUI inside a popover.
final class ComposerThinkingPickerController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private var levels: [ThinkingLevel]
    private var selected: ThinkingLevel
    private var onSelect: (ThinkingLevel) -> Void
    private var onSaveDefault: (() -> Void)?
    private let colors: ComposerThemeColors
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
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
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

    private var askClearing = AskComposerClearingState()
    private var inlineVisualLineCount = 1
    private var isFinishingVoiceBeforeSend = false
    private var localMediaImportEpoch: UInt64 = 0
    private var isInputFocused = false
    private var canvasBackgroundImage: UIImage?
    private var canvasReplacingAttachmentID: String?
    private var lastAskRequestID: String?
    private var lastSending = false
    /// The SwiftUI bar showed expand from the fourth visual line (its rounding
    /// counted one line ahead of a threshold of five); keep that feel.
    private let expandVisibilityLineThreshold = 4
    private let composerHorizontalPadding: CGFloat = 12
    /// Text inset above and below the draft; the placeholder sits on the same line.
    private let textVerticalInset: CGFloat = 6

    private let rootStack = UIStackView()
    private let forceStopButton = ComposerForceStopButton()
    private let slashPanel = ComposerSuggestionPanelView()
    private let filePanel = ComposerSuggestionPanelView()
    private let sendProgressView = ComposerSendProgressView()
    private let failureView = ComposerDictationFailureView()
    private let capsule = ComposerThemedPanelView()
    private let capsuleStack = UIStackView()
    /// Ask slot: the UIKit Ask card at its natural height, capped; the card
    /// scrolls its rows inside the cap.
    private let askContainer = UIView()
    private var askHeightConstraint: NSLayoutConstraint?
    private var askNaturalHeight: CGFloat = 0
    private var askCard: AskCardViewController?
    private var lastShowActionRow: Bool?
    private let attachmentStrip = ComposerAttachmentStripView()
    private let attachmentStripWrapper = UIView()
    private let filePillStrip = ComposerFilePillStripView()
    private let filePillStripWrapper = UIView()
    private let textRow = UIStackView()
    private let micButton = MicButtonChromeView()
    private let placeholderLabel = UILabel()
    private let textView = PastableUITextView()
    private var textHeightConstraint: NSLayoutConstraint?
    private let primaryButton = ComposerCircleActionButton()
    private let busyTipContainer = UIView()
    private var busyTipHeightConstraint: NSLayoutConstraint?
    private var busyTipChild: UIViewController?
    private var busyTipNaturalHeight: CGFloat = 0
    private let actionRowStack = UIStackView()
    private var actionRowMinHeight: NSLayoutConstraint?
    private let attachButton = ComposerGlassPillButton()
    private let trailingAttachButton = ComposerGlassPillButton()
    private let expandInActionRow = UIButton(type: .system)
    private let busyModeButton = ComposerGlassPillButton()
    let keyStripContainer = UIView()
    private var keyStripHeightConstraint: NSLayoutConstraint?
    private var keyStripView: UIView?
    private let leadingScroll = ComposerPillScrollView()
    private let leadingStack = ComposerPillStackView()
    private let spacer = UIView()
    private let trailingStack = ComposerPillStackView()
    private var pillViews: [String: UIView] = [:]
    private let overlayExpand = UIButton(type: .system)
    nonisolated(unsafe) private var inputModeObserver: NSObjectProtocol?
    private var presentedPicker: UIViewController?
    private var presentedActionID: String?
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

    var askCurrentPage: Int {
        get { askClearing.currentPage }
        set {
            askClearing.currentPage = newValue
            syncComposerTextWithActiveAskQuestion()
        }
    }

    var askDraftAnswers: [String: AskAnswer] {
        get { askClearing.draftAnswers }
        set {
            askClearing.draftAnswers = newValue
            syncComposerTextWithActiveAskQuestion()
        }
    }

    var askSubmittedRequestID: String? { askClearing.submittedRequestID }

    func askFailed(for request: AskRequest) -> Bool {
        if case .failed(let id) = askClearing.submission.phase { return id == request.id }
        return false
    }

    /// Keeps the UIKit Ask card in the Ask slot in step with the host's request.
    private func refreshAskCard() {
        guard let host else { return }
        let content = host.content
        guard let request = content.askRequest else {
            removeAskCard()
            return
        }
        let card = askCard ?? installAskCard()
        card.autoAdvanceController = host.askAutoAdvanceController
        card.voiceInputManager = content.voiceInputManager
        card.onPageChange = { [weak self] page in
            self?.askCurrentPage = page
        }
        card.onAnswersChange = { [weak self] answers in
            self?.askDraftAnswers = answers
        }
        card.onSubmit = { [weak self] answers, complete in
            self?.submitAskResponse(request: request, answers: answers, completion: complete)
        }
        card.onIgnoreAll = { [weak self] complete in
            self?.submitAskResponse(request: request, answers: nil, completion: complete)
        }
        card.onHeightChange = { [weak self] height in
            self?.askNaturalHeight = height
            self?.applyAskViewport()
        }
        card.apply(
            request: request,
            currentPage: askClearing.currentPage,
            answers: askClearing.draftAnswers,
            submittedRequestID: askClearing.submittedRequestID,
            responseFailed: askFailed(for: request),
            colors: content.colors,
            reduceMotion: content.reduceMotion
        )
        measureAskCard(slotWidth: askContainer.bounds.width > 1
            ? askContainer.bounds.width
            : view.bounds.width - (content.appliesOuterPadding ? 32 : 0))
    }

    private func installAskCard() -> AskCardViewController {
        let card = AskCardViewController()
        addChild(card)
        card.view.translatesAutoresizingMaskIntoConstraints = false
        askContainer.addSubview(card.view)
        NSLayoutConstraint.activate([
            card.view.leadingAnchor.constraint(equalTo: askContainer.leadingAnchor),
            card.view.trailingAnchor.constraint(equalTo: askContainer.trailingAnchor),
            card.view.topAnchor.constraint(equalTo: askContainer.topAnchor),
            card.view.bottomAnchor.constraint(equalTo: askContainer.bottomAnchor),
        ])
        card.didMove(toParent: self)
        askCard = card
        return card
    }

    private func removeAskCard() {
        guard let card = askCard else { return }
        askCard = nil
        askNaturalHeight = 0
        card.tearDown()
        card.willMove(toParent: nil)
        card.view.removeFromSuperview()
        card.removeFromParent()
    }

    /// The card's natural height at the slot's width; the slot caps it.
    private func measureAskCard(slotWidth: CGFloat) {
        guard let askCard, slotWidth > 1 else { return }
        askCard.loadViewIfNeeded()
        askNaturalHeight = askCard.preferredHeight(for: slotWidth)
    }

    var presentedActionIDForTesting: String? { presentedActionID }

    func presentActionForTesting(id: String) {
        presentActionPopover(id: id)
    }

    func installBusyTip(_ child: UIViewController?) {
        embed(child, in: busyTipContainer, stored: &busyTipChild)
    }

    /// The hosted busy-mode tip's own height. It is zero while the tip is not
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

    private func embed(_ child: UIViewController?, in container: UIView, stored: inout UIViewController?) {
        if stored === child { return }
        stored?.willMove(toParent: nil)
        stored?.view.removeFromSuperview()
        stored?.removeFromParent()
        stored = child
        guard let child else { return }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.backgroundColor = .clear
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    // MARK: - Build

    private func buildHierarchy() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        capsuleStack.axis = .vertical
        capsuleStack.spacing = 0
        capsuleStack.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(capsuleStack)
        NSLayoutConstraint.activate([
            capsuleStack.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            capsuleStack.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            capsuleStack.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            capsuleStack.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
        ])

        let askHeight = askContainer.heightAnchor.constraint(equalToConstant: 0)
        askHeightConstraint = askHeight
        askHeight.isActive = true
        askContainer.isHidden = true
        askContainer.clipsToBounds = true

        textRow.axis = .horizontal
        textRow.alignment = .bottom
        textRow.spacing = 8
        textRow.isLayoutMarginsRelativeArrangement = true
        textRow.layoutMargins = UIEdgeInsets(
            top: 10,
            left: composerHorizontalPadding,
            bottom: 10,
            right: composerHorizontalPadding
        )

        let textContainer = UIView()
        placeholderLabel.numberOfLines = 0
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(placeholderLabel)
        textContainer.addSubview(textView)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: textVerticalInset),
            textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
        ])
        let textHeight = textView.heightAnchor.constraint(equalToConstant: oneLineTextHeight)
        textHeightConstraint = textHeight
        textHeight.isActive = true
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)

        textRow.addArrangedSubview(micButton)
        textRow.addArrangedSubview(textContainer)
        textRow.addArrangedSubview(primaryButton)
        micButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)

        let tipHeight = busyTipContainer.heightAnchor.constraint(equalToConstant: 0)
        busyTipHeightConstraint = tipHeight
        tipHeight.isActive = true
        busyTipContainer.isHidden = true
        busyTipContainer.clipsToBounds = true

        actionRowStack.axis = .horizontal
        actionRowStack.alignment = .center
        actionRowStack.spacing = 6
        actionRowStack.isLayoutMarginsRelativeArrangement = true
        actionRowStack.layoutMargins = UIEdgeInsets(
            top: 8,
            left: composerHorizontalPadding,
            bottom: 7,
            right: composerHorizontalPadding
        )
        let minHeight = actionRowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minHeight.priority = .defaultHigh
        actionRowMinHeight = minHeight
        minHeight.isActive = true

        leadingStack.axis = .horizontal
        leadingStack.alignment = .center
        leadingStack.spacing = 6
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingScroll.showsHorizontalScrollIndicator = false
        leadingScroll.alwaysBounceHorizontal = false
        leadingScroll.addSubview(leadingStack)
        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.leadingAnchor),
            leadingStack.trailingAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.trailingAnchor),
            leadingStack.topAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.topAnchor),
            leadingStack.bottomAnchor.constraint(equalTo: leadingScroll.contentLayoutGuide.bottomAnchor),
            leadingStack.heightAnchor.constraint(equalTo: leadingScroll.frameLayoutGuide.heightAnchor),
        ])
        // A scroll view has no intrinsic width, so beside the spacer its width is
        // ambiguous and Auto Layout may collapse it to zero, hiding every pill.
        // Prefer the pills' width; below the trailing stack's compression
        // resistance so a crowded row scrolls instead of squeezing Cancel.
        let leadingFitsContent = leadingScroll.frameLayoutGuide.widthAnchor.constraint(
            equalTo: leadingScroll.contentLayoutGuide.widthAnchor
        )
        leadingFitsContent.priority = UILayoutPriority(UILayoutPriority.defaultLow.rawValue - 1)
        leadingFitsContent.isActive = true
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 6
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        leadingScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyStripContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyStripContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keyHeight = keyStripContainer.heightAnchor.constraint(
            equalToConstant: ComposerInputMetrics.controlDiameter
        )
        keyStripHeightConstraint = keyHeight
        keyHeight.isActive = true
        keyStripContainer.isHidden = true

        actionRowStack.addArrangedSubview(attachButton)
        actionRowStack.addArrangedSubview(expandInActionRow)
        actionRowStack.addArrangedSubview(busyModeButton)
        actionRowStack.addArrangedSubview(keyStripContainer)
        actionRowStack.addArrangedSubview(leadingScroll)
        actionRowStack.addArrangedSubview(spacer)
        actionRowStack.addArrangedSubview(trailingStack)
        actionRowStack.addArrangedSubview(trailingAttachButton)
        attachButton.setContentHuggingPriority(.required, for: .horizontal)
        attachButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingAttachButton.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        embedStrip(attachmentStrip, in: attachmentStripWrapper, top: 8, bottom: 4)
        embedStrip(filePillStrip, in: filePillStripWrapper, top: 8, bottom: 4)

        capsuleStack.addArrangedSubview(askContainer)
        capsuleStack.addArrangedSubview(attachmentStripWrapper)
        capsuleStack.addArrangedSubview(filePillStripWrapper)
        capsuleStack.addArrangedSubview(textRow)
        capsuleStack.addArrangedSubview(busyTipContainer)
        capsuleStack.addArrangedSubview(actionRowStack)

        overlayExpand.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(overlayExpand)
        NSLayoutConstraint.activate([
            overlayExpand.topAnchor.constraint(equalTo: capsule.contentView.topAnchor, constant: 6),
            overlayExpand.trailingAnchor.constraint(
                equalTo: capsule.contentView.trailingAnchor,
                constant: -composerHorizontalPadding
            ),
            overlayExpand.widthAnchor.constraint(equalToConstant: ComposerInputMetrics.controlDiameter),
            overlayExpand.heightAnchor.constraint(equalToConstant: ComposerInputMetrics.controlDiameter),
        ])

        let capsuleMin = capsule.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        capsuleMin.priority = .defaultHigh
        capsuleMin.isActive = true

        for arranged in [forceStopButton, slashPanel, filePanel, sendProgressView, capsule] {
            rootStack.addArrangedSubview(arranged)
        }
        let minWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        minWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            minWidth,
        ])

        slashPanel.onSelectSlash = { [weak self] command in
            self?.host?.insertSlashCommand(command)
            self?.applyChrome()
        }
        filePanel.onSelectFile = { [weak self] suggestion in
            self?.host?.insertFileSuggestion(suggestion)
            self?.applyChrome()
        }
        attachmentStrip.onAnnotate = { [weak self] attachment in
            self?.canvasBackgroundImage = ComposerShared.image(forPendingAttachment: attachment)
            self?.canvasReplacingAttachmentID = attachment.id
            self?.presentCanvas()
        }
        attachmentStrip.onRemove = { [weak self] id in
            self?.host?.removeAttachment(id: id)
            self?.applyChrome()
        }
        filePillStrip.onRemove = { [weak self] id in
            self?.host?.removeRepoPointer(id: id)
            self?.applyChrome()
        }
        failureView.onRetry = { [weak self] in
            self?.handleMicTap()
        }
    }

    private func embedStrip(_ view: UIView, in wrapper: UIView, top: CGFloat, bottom: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: composerHorizontalPadding),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -composerHorizontalPadding),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom),
        ])
    }

    private func installTextView() {
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.textContainerInset = UIEdgeInsets(
            top: textVerticalInset,
            left: 0,
            bottom: textVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.isAccessibilityElement = true
        _ = textView.layoutManager
        textView.installKeyboardRestoreGesture()
        textView.onPasteImages = { [weak self] images in
            self?.host?.handlePastedImages(images)
        }
        textView.onCommandEnter = { [weak self] in self?.handleSend() }
        textView.onAlternateEnter = { [weak self] in self?.handleAlternateSend() }
        textView.onKeyboardRestoreRequest = { [weak self] in
            self?.host?.restoreKeyboardFromSuppression()
            self?.applyChrome()
        }
    }

    private func installActions() {
        micButton.addAction(UIAction { [weak self] _ in self?.handleMicTap() }, for: .touchUpInside)
        primaryButton.addAction(UIAction { [weak self] _ in self?.handlePrimaryAction() }, for: .touchUpInside)
        forceStopButton.addAction(UIAction { [weak self] _ in self?.host?.performForceStop() }, for: .touchUpInside)
        expandInActionRow.addAction(UIAction { [weak self] _ in self?.host?.performExpand() }, for: .touchUpInside)
        overlayExpand.addAction(UIAction { [weak self] _ in self?.host?.performExpand() }, for: .touchUpInside)
        busyModeButton.addAction(UIAction { [weak self] _ in self?.presentBusyModePicker() }, for: .touchUpInside)
        configureExpand(expandInActionRow)
        configureExpand(overlayExpand)
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.preferredMenuElementOrder = .priority
        attachButton.menu = attachmentMenu()
        trailingAttachButton.showsMenuAsPrimaryAction = true
        trailingAttachButton.preferredMenuElementOrder = .priority
        trailingAttachButton.menu = attachmentMenu()
        attachButton.accessibilityIdentifier = "chat.attach"
        attachButton.accessibilityLabel = "Add attachment"
        trailingAttachButton.accessibilityIdentifier = "chat.attach"
        trailingAttachButton.accessibilityLabel = "Add attachment"
        busyModeButton.accessibilityIdentifier = "chat.busyMode"
        busyModeButton.accessibilityLabel = "Busy send mode"
        micButton.accessibilityIdentifier = "chat.voiceInput"
        primaryButton.accessibilityIdentifier = "chat.send"
        expandInActionRow.accessibilityIdentifier = "chat.expand"
        overlayExpand.accessibilityIdentifier = "chat.expand"
    }

    private func configureExpand(_ button: UIButton) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "arrow.up.left.and.arrow.down.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        config.contentInsets = .zero
        button.configuration = config
        button.accessibilityLabel = "Expand composer"
        button.accessibilityHint = "Opens the full-screen message editor"
    }

    // MARK: - Apply

    private func applyChrome() {
        guard let host else { return }
        let content = host.content
        let colors = content.colors
        let padding = content.appliesOuterPadding ? UIEdgeInsets(top: 0, left: 16, bottom: 8, right: 16) : .zero
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.layoutMargins = padding

        capsule.apply(colors: colors)
        let context = ComposerAutocomplete.context(for: content.text, isBusy: content.isBusy)
        let slash: [SlashCommand]
        if case .slash(let query) = context {
            slash = ComposerAutocomplete.slashSuggestions(query: query, commands: content.slashCommands)
        } else {
            slash = []
        }
        slashPanel.apply(content: slash.isEmpty ? .empty : .slash(slash), colors: colors)
        let showFiles = !content.fileSuggestions.isEmpty && {
            if case .atFile = context { return true }
            return false
        }()
        filePanel.apply(
            content: showFiles ? .files(content.fileSuggestions) : .empty,
            colors: colors
        )

        sendProgressView.apply(text: content.sendProgressText, isSending: content.isSending, colors: colors)
        if let failure = ComposerShared.captureFailure(content.voiceInputManager, owner: .inlineComposer) {
            failureView.apply(message: failure.message, colors: colors)
            failureView.isHidden = false
        } else {
            failureView.isHidden = true
        }
        forceStopButton.isHidden = !content.showForceStop
        forceStopButton.apply(isInFlight: content.isForceStopInFlight, colors: colors)

        attachmentStrip.apply(
            attachments: content.pendingAttachments,
            colors: colors,
            allowsMutation: !content.isSending
        )
        attachmentStripWrapper.isHidden = content.pendingAttachments.isEmpty
        filePillStrip.apply(pointers: content.pendingRepoPointers, colors: colors)
        filePillStripWrapper.isHidden = content.pendingRepoPointers.isEmpty

        let showActionRow = ChatInputBar.shouldShowComposerActionRow(
            alwaysShowActionRow: content.alwaysShowActionRow,
            isBusy: content.isBusy,
            isInputFocused: isInputFocused,
            isKeyboardSuppressed: content.suppressKeyboard,
            hasAttachments: !content.pendingAttachments.isEmpty,
            hasRepoPointers: !content.pendingRepoPointers.isEmpty
        ) && content.showsAccessoryRow
        applyActionRowVisibility(showActionRow, minimumHeight: content.actionRowMinimumHeight, reduceMotion: content.reduceMotion)

        let showsBusy = ChatInputBar.showsBusyModeSelector(
            isBusy: content.isBusy,
            hasAskRequest: content.askRequest != nil
        )
        busyModeButton.isHidden = !showsBusy || !showActionRow
        if !showsBusy {
            // A tip shows once; each busy turn starts at zero until its tip
            // reports a height, so a tip left up by the last turn holds no space.
            busyTipNaturalHeight = 0
        }
        let tipHeight: CGFloat = showsBusy ? busyTipNaturalHeight : 0
        busyTipHeightConstraint?.constant = tipHeight
        busyTipContainer.isHidden = tipHeight <= 0
        busyModeButton.apply(
            title: content.busyStreamingBehavior == .steer ? "Steering" : "Follow-up",
            systemImage: nil,
            colors: colors,
            chevron: true
        )
        busyModeButton.accessibilityValue = content.busyStreamingBehavior == .steer ? "Steering" : "Follow-up"

        let leadingAttach = content.allowsAttachments && content.attachmentButtonPlacement == .leading
        let trailingAttach = content.allowsAttachments && content.attachmentButtonPlacement == .trailing
        attachButton.isHidden = !leadingAttach || !showActionRow
        trailingAttachButton.isHidden = !trailingAttach || !showActionRow
        attachButton.isEnabled = !content.isSending
        trailingAttachButton.isEnabled = !content.isSending
        attachButton.apply(title: nil, systemImage: "plus", colors: colors, symbolPointSize: 11)
        trailingAttachButton.apply(title: nil, systemImage: "plus", colors: colors, symbolPointSize: 11)

        overlayExpand.tintColor = colors.comment
        expandInActionRow.tintColor = colors.comment

        let keyHeight = content.keyStripHeight
        keyStripHeightConstraint?.constant = keyHeight
        keyStripContainer.isHidden = keyHeight <= 0 || !showActionRow
        spacer.isHidden = keyHeight > 0

        applyActionPills(content.actionRow, colors: colors, showActionRow: showActionRow)
        applyTextView(content: content, colors: colors)
        applyPrimaryButton(content: content, colors: colors)
        applyMicChrome()
        refreshPresentedPopover(content.actionRow)

        refreshAskCard()
        applyAskViewport()
    }

    private func applyActionRowVisibility(_ showActionRow: Bool, minimumHeight: CGFloat, reduceMotion: Bool) {
        // The row hugs its pills unless the surface asks for a taller row.
        let minHeight = showActionRow ? minimumHeight : 0
        let visibilityChanged = lastShowActionRow.map { $0 != showActionRow } ?? false
        lastShowActionRow = showActionRow
        let applyFlags = {
            self.actionRowStack.isHidden = !showActionRow
            self.actionRowMinHeight?.constant = minHeight
        }
        if visibilityChanged, !reduceMotion {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    applyFlags()
                    self.actionRowStack.layoutIfNeeded()
                }
            )
        } else {
            applyFlags()
        }
    }

    /// `notifyHost` is false while SwiftUI is already measuring the bar.
    private func applyAskViewport(notifyHost: Bool = true) {
        let hasAsk = host?.content.askRequest != nil
        let focused = isInputFocused && !(host?.content.suppressKeyboard ?? false)
        let cap = focused
            ? ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard
            : ExtensionNativeSurfaceLayout.expandedMaxHeight
        let natural = hasAsk ? max(askNaturalHeight, 0) : 0
        let slot = min(natural, cap)
        let slotChanged = askHeightConstraint?.constant != slot
        if slotChanged {
            askHeightConstraint?.constant = slot
        }
        askContainer.isHidden = !hasAsk || slot <= 0
        if slotChanged {
            view.invalidateIntrinsicContentSize()
            if notifyHost { host?.askSlotDidChangeHeight() }
        }
    }

    private func applyActionPills(_ row: ComposerActionRow, colors: ComposerThemeColors, showActionRow: Bool) {
        leadingScroll.isScrollEnabled = row.leadingScrolls
        fill(leadingStack, actions: row.leading, colors: colors)
        fill(trailingStack, actions: row.trailing, colors: colors)
        leadingScroll.isHidden = row.leading.isEmpty || !showActionRow
        trailingStack.isHidden = row.trailing.isEmpty || !showActionRow
        let keep = Set((row.leading + row.trailing).map(\.id))
        for (id, view) in pillViews where !keep.contains(id) {
            if isPresentedSource(view) { continue }
            view.removeFromSuperview()
            pillViews[id] = nil
        }
    }

    private func fill(_ stack: UIStackView, actions: [ComposerAction], colors: ComposerThemeColors) {
        let next = actions.map { pillView(for: $0, colors: colors) }
        for view in stack.arrangedSubviews {
            if next.contains(where: { $0 === view }) { continue }
            if isPresentedSource(view) { continue }
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in next.enumerated() {
            if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === view {
                continue
            }
            if view.superview === stack {
                stack.removeArrangedSubview(view)
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            } else if view.superview != nil {
                if isPresentedSource(view) { continue }
                view.removeFromSuperview()
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            } else {
                stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            }
        }
    }

    private func isPresentedSource(_ view: UIView) -> Bool {
        guard presentedPicker != nil, let presentedActionID else { return false }
        return pillViews[presentedActionID] === view
    }

    private func pillView(for action: ComposerAction, colors: ComposerThemeColors) -> UIView {
        let tint = action.tint ?? colors.fg
        let icon = image(for: action.icon, tint: tint)
        if let existing = pillViews[action.id] {
            configure(existing, action: action, icon: icon, tint: tint, colors: colors)
            return existing
        }
        let view: UIView
        switch action.chrome {
        case .toolbar:
            let button = ComposerToolbarPillButton()
            view = button
        case .chip:
            let button = ComposerActionChipButton()
            view = button
        case .cancel:
            let button = ComposerActionCancelButton()
            view = button
        }
        view.accessibilityIdentifier = action.id
        pillViews[action.id] = view
        configure(view, action: action, icon: icon, tint: tint, colors: colors)
        bindAction(view, id: action.id, kind: action.kind)
        return view
    }

    private func configure(
        _ view: UIView,
        action: ComposerAction,
        icon: UIImage?,
        tint: UIColor,
        colors: ComposerThemeColors
    ) {
        view.accessibilityLabel = action.accessibilityLabel
        view.accessibilityValue = action.accessibilityValue ?? ""
        switch action.chrome {
        case .toolbar:
            let button = view as? ComposerToolbarPillButton
            button?.apply(
                title: action.title,
                icon: icon,
                tint: tint,
                showsChevron: action.showsChevron,
                colors: colors
            )
        case .chip:
            (view as? ComposerActionChipButton)?.apply(
                title: action.title,
                systemImage: symbolName(action.icon),
                colors: colors
            )
        case .cancel:
            (view as? ComposerActionCancelButton)?.apply(colors: colors)
        }
        if let button = view as? UIButton, case .menu(let menu) = action.kind {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
    }

    private func bindAction(_ view: UIView, id: String, kind: ComposerAction.Kind) {
        guard let button = view as? UIButton else { return }
        switch kind {
        case .tap, .picker:
            button.showsMenuAsPrimaryAction = false
            button.addAction(UIAction { [weak self] _ in
                self?.performAction(id: id)
            }, for: .touchUpInside)
        case .menu:
            break
        }
    }

    private func performAction(id: String) {
        let actions = (host?.content.actionRow.leading ?? []) + (host?.content.actionRow.trailing ?? [])
        guard let action = actions.first(where: { $0.id == id }) else { return }
        switch action.kind {
        case .tap(let handler):
            handler.run()
        case .picker:
            presentActionPopover(id: id)
        case .menu:
            break
        }
    }

    private func image(for icon: ComposerAction.Icon?, tint: UIColor) -> UIImage? {
        switch icon {
        case .image(let image):
            return image
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
        case .monogram(let text):
            return renderMonogram(text, tint: tint)
        case nil:
            return nil
        }
    }

    private func symbolName(_ icon: ComposerAction.Icon?) -> String? {
        if case .symbol(let name) = icon { return name }
        return nil
    }

    private func renderMonogram(_ text: String, tint: UIColor) -> UIImage {
        let size: CGFloat = 11
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.8, weight: .heavy),
                .foregroundColor: tint,
            ]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private func applyTextView(content: ComposerBarContent, colors: ComposerThemeColors) {
        let display = composerDisplayText
        let visible = ComposerShared.visibleComposerText(display)
        placeholderLabel.text = content.placeholderOverride ?? ChatInputBar.composerPlaceholder(
            askRequest: content.askRequest,
            pendingReviewCommentCount: content.pendingReviewCommentCount,
            isBusy: content.isBusy,
            busyStreamingBehavior: content.busyStreamingBehavior
        )
        placeholderLabel.textColor = colors.comment
        placeholderLabel.isHidden = !visible.isEmpty
        let accent = content.isBusy ? colors.purple : colors.blue
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.tintColor = accent
        textView.accessibilityIdentifier = content.inputAccessibilityIdentifier
        applyComposerInputTraits(to: textView, autocorrectionEnabled: content.autocorrectionEnabled)
        textView.applyStyledText(
            visible,
            font: UIFont.preferredFont(forTextStyle: .body),
            baseColor: colors.fg,
            volatileSuffixLength: ComposerShared.volatileSuffixLength(
                manager: content.voiceInputManager,
                owner: .inlineComposer
            ),
            volatileColor: accent,
            volatileBackgroundColor: accent.withAlphaComponent(0.20),
            correctionRanges: ComposerShared.correctionRanges(
                manager: content.voiceInputManager,
                textBeforeRecording: content.textBeforeRecording,
                owner: .inlineComposer
            ),
            correctionUnderlineColor: colors.orange,
            scrollCaretToVisible: true
        )
        let allowRestore = ChatInputBar.allowKeyboardRestoreOnTap(
            voiceState: content.voiceInputManager?.state ?? .idle
        )
        if textView.allowsKeyboardRestoreOnTap != allowRestore {
            textView.setAllowKeyboardRestoreOnTap(allowRestore)
        }
        if textView.isKeyboardSuppressed != content.suppressKeyboard {
            textView.setKeyboardSuppressed(content.suppressKeyboard)
        }
        attemptFocusIfRequested()
        applyTextLayout(proposedWidth: view.bounds.width)
    }

    private func attemptFocusIfRequested() {
        guard let host, host.content.focusRequestID != 0 else { return }
        guard textView.window != nil else { return }
        if !textView.isFirstResponder {
            guard textView.becomeFirstResponder() else { return }
        }
        textView.moveCaretToEnd()
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, host.content.focusRequestID != 0 else { return }
            guard self.textView.isFirstResponder else { return }
            host.consumeFocusRequest()
        }
    }

    /// One line of body text plus its insets: the draft's resting height.
    private var oneLineTextHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + textVerticalInset * 2)
    }

    /// Measures the draft as laid out at `proposedWidth`, then sizes the text
    /// view and shows the expand control from that one measurement. Typed,
    /// dictated, pasted, and restored text all pass through here, so each
    /// reaches the expand threshold the same way.
    private func applyTextLayout(proposedWidth: CGFloat) {
        guard let host else { return }
        let content = host.content
        let maxLines = ChatInputBar.inlineTextMaxLines(
            hasAskRequest: content.askRequest != nil,
            hasAttachments: !content.pendingAttachments.isEmpty,
            hasRepoPointers: !content.pendingRepoPointers.isEmpty
        )
        let outer: CGFloat = content.appliesOuterPadding ? 32 : 0
        let rowPad: CGFloat = composerHorizontalPadding * 2
        let showsMic = !micButton.isHidden
        let mic: CGFloat = showsMic ? ComposerInputMetrics.controlDiameter + 8 : 0
        let send: CGFloat = ComposerInputMetrics.controlDiameter + 8
        let textWidth = proposedWidth - outer - rowPad - mic - send
        // Before the first layout pass the bar has no width; SwiftUI measures
        // it again at a real width.
        guard textWidth > ComposerInputMetrics.controlDiameter else { return }

        // Count lines without the expand gutter so showing the control cannot
        // re-wrap the draft back under the threshold.
        textView.textContainerInset.right = 0
        var growth = ComposerInputMetrics.textViewGrowth(
            for: textView,
            fittingWidth: textWidth,
            minHeight: oneLineTextHeight,
            maxLines: maxLines
        )
        let lineHeight = max(textView.font?.lineHeight ?? 17, 1)
        let lines = (growth.height - textVerticalInset * 2) / lineHeight
        inlineVisualLineCount = max(1, Int(lines + 0.05))
        let showsExpand = ChatInputBar.shouldShowExpandButton(
            allowsExpansion: content.allowsExpansion,
            visualLineCount: inlineVisualLineCount,
            threshold: expandVisibilityLineThreshold,
            maxLines: maxLines
        )
        overlayExpand.isHidden = !(showsExpand && content.askRequest == nil)
        expandInActionRow.isHidden = !(showsExpand && content.askRequest != nil && lastShowActionRow == true)
        if showsExpand {
            textView.textContainerInset.right = ChatInputBar.composerTextTrailingPadding(showsExpandButton: true)
            growth = ComposerInputMetrics.textViewGrowth(
                for: textView,
                fittingWidth: textWidth,
                minHeight: oneLineTextHeight,
                maxLines: maxLines
            )
        }
        if textHeightConstraint?.constant != growth.height {
            textHeightConstraint?.constant = growth.height
        }
        textView.isScrollEnabled = growth.isScrollEnabled
    }

    private func applyPrimaryButton(content: ComposerBarContent, colors: ComposerThemeColors) {
        let canSend = self.canSend
        let inFlight = isSendInFlight
        let kind = ChatInputBar.primaryActionKind(
            isBusy: content.isBusy,
            canSend: canSend,
            isSending: inFlight,
            hasAskRequest: content.askRequest != nil
        )
        let submitted = isCurrentAskSubmitted
        switch kind {
        case .send:
            let fill: UIColor
            if inFlight {
                fill = content.isBusy ? colors.purple : colors.blue
            } else {
                fill = canSend ? (content.isBusy ? colors.purple : colors.blue) : colors.bgHighlight
            }
            let stroke = (canSend || inFlight) ? fill.withAlphaComponent(0.9) : colors.comment.withAlphaComponent(0.35)
            let foreground: UIColor
            if canSend || inFlight {
                foreground = ComposerColorContrast.foreground(for: fill, fg: colors.fg, bg: colors.bg)
            } else {
                foreground = colors.comment
            }
            primaryButton.apply(
                systemImage: "arrow.up",
                fill: fill,
                stroke: stroke,
                foreground: foreground,
                showsProgress: inFlight
            )
            primaryButton.isEnabled = canSend && !inFlight && !submitted
            primaryButton.accessibilityIdentifier = content.sendAccessibilityIdentifier
            primaryButton.accessibilityLabel = inFlight ? "Sending" : "Send"
        case .ignoreAsk:
            primaryButton.apply(
                systemImage: "xmark",
                fill: colors.bgHighlight,
                stroke: colors.comment.withAlphaComponent(0.35),
                foreground: colors.comment,
                showsProgress: false,
                symbol: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            )
            primaryButton.isEnabled = !submitted
            primaryButton.accessibilityIdentifier = "chat.askIgnore"
            primaryButton.accessibilityLabel = "Ignore request"
            primaryButton.accessibilityHint = "Responds to the current extension request as ignored"
        case .stop:
            let fill = content.isStopping ? colors.orange : colors.red
            let foreground = ComposerColorContrast.foreground(for: fill, fg: colors.fg, bg: colors.bg)
            primaryButton.apply(
                systemImage: "stop.fill",
                fill: fill,
                stroke: fill.withAlphaComponent(0.9),
                foreground: foreground,
                showsProgress: content.isStopping,
                diameter: ComposerInputMetrics.controlDiameter + 2,
                symbol: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            )
            primaryButton.isEnabled = !content.isStopping
            primaryButton.accessibilityIdentifier = "chat.stop"
            primaryButton.accessibilityLabel = content.isStopping ? "Stopping" : "Stop response"
        }
    }

    private func applyMicChrome() {
        guard let host, let manager = host.content.voiceInputManager else {
            micButton.isHidden = true
            return
        }
        micButton.isHidden = false
        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)
        let accent = host.content.isBusy ? host.content.colors.purple : host.content.colors.blue
        micButton.apply(
            presentation: presentation,
            accentColor: accent,
            diameter: ComposerInputMetrics.controlDiameter
        )
        micButton.isEnabled = presentation.isEnabled
        micButton.accessibilityLabel = presentation.accessibilityLabel
        micButton.accessibilityValue = presentation.accessibilityValue
    }

    @objc private func themeDidChange() {
        applyChrome()
    }

    // MARK: - Derived state

    private var composerDisplayText: String {
        guard let host else { return "" }
        return ComposerShared.currentComposerText(
            storedText: host.content.text,
            textBeforeRecording: host.content.textBeforeRecording,
            manager: host.content.voiceInputManager,
            owner: .inlineComposer
        )
    }

    private var canSend: Bool {
        guard let host else { return false }
        if host.content.askRequest != nil {
            return pendingAskSendTransition != nil
        }
        return ChatInputBar.canSubmitMessage(
            allowsEmptySubmit: host.content.allowsEmptySubmit,
            text: composerDisplayText,
            hasImages: host.content.pendingAttachments.contains { $0.source == .image },
            hasFiles: host.content.pendingAttachments.contains { $0.source != .image }
                || !host.content.pendingRepoPointers.isEmpty,
            hasReviewComments: host.content.pendingReviewCommentCount > 0
        )
    }

    private var isSendInFlight: Bool {
        (host?.content.isSending ?? false) || isFinishingVoiceBeforeSend
    }

    private var isCurrentAskSubmitted: Bool {
        askClearing.submittedRequestID != nil && askClearing.submittedRequestID == host?.content.askRequest?.id
    }

    private var activeAskQuestionID: String? {
        guard let askRequest = host?.content.askRequest,
              askClearing.currentPage >= 0,
              askClearing.currentPage < askRequest.questions.count else {
            return nil
        }
        return askRequest.questions[askClearing.currentPage].id
    }

    private var pendingAskSendTransition: ChatInputBar.AskComposerSendTransition? {
        ChatInputBar.askComposerSendTransition(
            request: host?.content.askRequest,
            currentPage: askClearing.currentPage,
            draftAnswers: askClearing.draftAnswers,
            text: composerDisplayText
        )
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        guard let host else { return }
        switch ChatInputBar.primaryActionKind(
            isBusy: host.content.isBusy,
            canSend: canSend,
            isSending: isSendInFlight,
            hasAskRequest: host.content.askRequest != nil
        ) {
        case .send:
            handleSend()
        case .ignoreAsk:
            guard let askRequest = host.content.askRequest else { return }
            submitAskResponse(request: askRequest, answers: nil)
        case .stop:
            host.performStop()
        }
    }

    private func handleSend() {
        guard !isSendInFlight else { return }
        if let manager = host?.content.voiceInputManager,
           ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer),
           manager.isRecording || manager.isPreparing {
            isFinishingVoiceBeforeSend = true
            let wasSuppressed = host?.content.suppressKeyboard ?? false
            let voiceState = manager.state
            Task { @MainActor in
                await self.host?.finishVoiceBeforeSubmit()
                self.host?.setSuppressKeyboard(
                    ChatInputBar.suppressKeyboardAfterSend(
                        voiceState: voiceState,
                        wasSuppressed: wasSuppressed
                    )
                )
                self.isFinishingVoiceBeforeSend = false
                self.submitCurrentComposerAction()
            }
            return
        }
        submitCurrentComposerAction()
    }

    private func submitCurrentComposerAction() {
        if handleAskComposerSendIfNeeded() {
            return
        }
        if let askRequest = host?.content.askRequest {
            submitAskResponse(request: askRequest, answers: nil)
            return
        }
        if host?.content.isBusy == true {
            FeatureEducationTips.markBusySendModeUsed()
        }
        host?.performSend()
    }

    private func handleAskComposerSendIfNeeded() -> Bool {
        guard !isCurrentAskSubmitted else { return true }
        guard let transition = pendingAskSendTransition else { return false }
        if transition.shouldSubmit, let askRequest = host?.content.askRequest {
            askClearing.draftAnswers = transition.answers
            submitAskResponse(request: askRequest, answers: transition.answers)
            return true
        }
        askClearing.draftAnswers = transition.answers
        host?.setText(transition.nextComposerText)
        host?.setTextBeforeRecording(nil)
        askClearing.currentPage = transition.nextPage
        applyChrome()
        return true
    }

    func submitAskResponse(
        request: AskRequest,
        answers: [String: AskAnswer]?,
        completion: @escaping AskResponseSubmission.Completion = { _ in }
    ) {
        guard host?.content.askRequest?.id == request.id else {
            completion(.completed)
            return
        }
        var submittedTextRevision: UInt64?
        askClearing.submission.submit(requestID: request.id, deliver: { complete in
            submittedTextRevision = self.askClearing.textRevision
            self.host?.setText("")
            self.host?.setTextBeforeRecording(nil)
            if let answers {
                self.host?.submitAsk(request, answers: answers, completion: complete)
            } else {
                self.host?.ignoreAsk(request, completion: complete)
            }
            FeatureEducationTips.markPromptAnswered()
            self.applyChrome()
        }, completion: { result in
            if result == .retryableFailure,
               let submittedTextRevision,
               self.askClearing.textRevision == submittedTextRevision,
               self.host?.content.text.isEmpty == true,
               let restored = ChatInputBar.composerTextForActiveAskQuestion(
                   request: self.host?.content.askRequest,
                   activeQuestionID: self.activeAskQuestionID,
                   draftAnswers: self.askClearing.draftAnswers,
                   keepComposerClearedForSubmittedRequestID: self.askClearing.submittedRequestID
               ) {
                self.host?.setText(restored)
                self.host?.setTextBeforeRecording(nil)
            }
            completion(result)
            self.applyChrome()
        })
    }

    private func handleAlternateSend() {
        guard !isSendInFlight else { return }
        if host?.content.isBusy == true {
            host?.setBusyStreamingBehavior(.followUp)
            FeatureEducationTips.markBusySendModeUsed()
        }
        handleSend()
    }

    private func syncComposerTextWithActiveAskQuestion() {
        guard let desiredText = ChatInputBar.composerTextForActiveAskQuestion(
            request: host?.content.askRequest,
            activeQuestionID: activeAskQuestionID,
            draftAnswers: askClearing.draftAnswers,
            keepComposerClearedForSubmittedRequestID: askClearing.submittedRequestID
        ) else { return }
        guard host?.content.text != desiredText || host?.content.textBeforeRecording != nil else { return }
        host?.setText(desiredText)
        host?.setTextBeforeRecording(nil)
    }

    private func handleMicTap() {
        Task {
            guard let manager = host?.content.voiceInputManager else { return }
            guard ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer) else { return }
            switch ComposerShared.micTapAction(for: manager.state) {
            case .stop:
                await host?.stopVoice()
            case .cancelPreparing:
                await host?.cancelVoice()
                applyChrome()
            case .start:
                await startVoice(owner: .inlineComposer)
            case .ignore:
                break
            }
        }
    }

    private func startVoice(owner: ComposerShared.VoiceInputOwner) async {
        guard let host else { return }
        do {
            try await host.startVoice(
                keyboardLanguage: host.content.keyboardLanguage,
                owner: owner,
                baseText: host.content.text
            )
            applyChrome()
        } catch is CancellationError {
        } catch {
            presentAlert(title: "Couldn't Start Dictation", message: error.localizedDescription)
        }
    }

    // MARK: - Presentations

    private func attachmentMenu() -> UIMenu {
        ComposerAttachmentPickers.menu(identifierPrefix: "chat.attach") { [weak self] item in
            switch item {
            case .photoLibrary: self?.presentPhotoLibrary()
            case .camera: self?.presentCamera()
            case .chooseFile: self?.presentFileImporter()
            case .canvas: self?.presentCanvas()
            }
        }
    }

    private func presentPhotoLibrary() {
        present(ComposerAttachmentPickers.photoLibrary(delegate: self), animated: true)
    }

    private func presentCamera() {
        present(ComposerAttachmentPickers.camera(delegate: self), animated: true)
    }

    private func presentCanvas() {
        let background = canvasBackgroundImage.map { PaperMarkupCanvasSession.Background.image($0) } ?? .blank
        let replacing = canvasReplacingAttachmentID
        let controller = PaperMarkupCanvasHostController(
            background: background,
            onAddToChat: { [weak self] attachment, recognizedText in
                guard let self else { return false }
                let accepted = self.host?.applyCanvas(
                    attachment: attachment,
                    recognizedText: recognizedText,
                    replacingAttachmentID: replacing
                ) ?? false
                if accepted {
                    self.dismiss(animated: true)
                    self.canvasBackgroundImage = nil
                    self.canvasReplacingAttachmentID = nil
                    self.applyChrome()
                }
                return accepted
            },
            onCancel: { [weak self] in
                self?.dismiss(animated: true)
                self?.canvasBackgroundImage = nil
                self?.canvasReplacingAttachmentID = nil
            }
        )
        controller.modalPresentationStyle = .overFullScreen
        present(controller, animated: true)
    }

    private func presentFileImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentBusyModePicker() {
        guard let host else { return }
        let picker = ComposerBusyModePickerController(
            selected: host.content.busyStreamingBehavior,
            colors: host.content.colors,
            onSelect: { [weak self] behavior in
                self?.host?.setBusyStreamingBehavior(behavior)
                self?.applyChrome()
            }
        )
        presentPopover(picker, from: busyModeButton, actionID: "chat.busyMode")
    }

    private func presentActionPopover(id: String) {
        guard let host else { return }
        let actions = host.content.actionRow.leading + host.content.actionRow.trailing
        guard let action = actions.first(where: { $0.id == id }),
              case .picker(let spec) = action.kind,
              let source = pillViews[id] else { return }
        let screen = spec.make()
        presentPopover(screen, from: source, actionID: id)
    }

    private func presentPopover(_ screen: UIViewController, from source: UIView, actionID: String) {
        presentedPicker = screen
        presentedActionID = actionID
        if let container = screen as? RouterModalContainer {
            container.onDismissed = { [weak self] in
                self?.presentedPicker = nil
                self?.presentedActionID = nil
            }
        }
        Router.present(
            screen,
            presentation: .popover.arrowDirections(.down).keepsPopoverInCompactWidth(),
            from: self,
            sourceView: source,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in
                self?.presentedPicker = nil
                self?.presentedActionID = nil
            }
        )
    }

    private func refreshPresentedPopover(_ row: ComposerActionRow) {
        guard let presentedActionID, let presentedPicker else { return }
        let actions = row.leading + row.trailing
        guard let action = actions.first(where: { $0.id == presentedActionID }),
              case .picker(let spec) = action.kind else { return }
        spec.update?(presentedPicker)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Delegates

    func textViewDidBeginEditing(_ textView: UITextView) {
        isInputFocused = true
        host?.setInputFocused(true)
        if let pastable = textView as? PastableUITextView, pastable.isKeyboardSuppressed {
        } else {
            updateKeyboardLanguage()
        }
        applyChrome()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        isInputFocused = false
        host?.setInputFocused(false)
        applyChrome()
    }

    func textViewDidChange(_ textView: UITextView) {
        let incoming = textView.text ?? ""
        if let pastable = textView as? PastableUITextView,
           !pastable.shouldCommitUserEdit(incoming) {
            return
        }
        var next = incoming
        if host?.content.text.hasPrefix("$ ") == true {
            next = incoming.isEmpty ? "" : "$ " + incoming
        }
        askClearing.textRevision &+= 1
        host?.setText(next)
        if let host {
            host.notifyFileSuggestionContext(for: host.content.text)
        }
        applyChrome()
    }

    private func updateKeyboardLanguage() {
        if textView.isKeyboardSuppressed { return }
        guard textView.isFirstResponder else { return }
        let lang = textView.textInputMode?.primaryLanguage
        host?.setKeyboardLanguage(lang)
        AppPreferences.Keyboard.save(lang)
        if let manager = host?.content.voiceInputManager,
           AppPreferences.Keyboard.normalize(lang) != nil {
            Task {
                await manager.prewarm(keyboardLanguage: lang, source: "inline_keyboard_change")
            }
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let capturedLocal = localMediaImportEpoch
        host?.importPhotoProviders(
            results.map(\.itemProvider),
            capturedGate: host?.content.mediaImportEpoch ?? 0,
            capturedLocal: capturedLocal,
            currentLocal: { [weak self] in self?.localMediaImportEpoch ?? 0 },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
        applyChrome()
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            host?.addCapturedImage(image)
            applyChrome()
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let capturedLocal = localMediaImportEpoch
        host?.loadSelectedFiles(
            .success(urls),
            capturedGate: host?.content.mediaImportEpoch ?? 0,
            capturedLocal: capturedLocal,
            currentLocal: { [weak self] in self?.localMediaImportEpoch ?? 0 },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
        applyChrome()
    }
}

#if DEBUG
import UIKit

// MARK: - Harness Configuration

enum UIHangHarnessConfig {
    private struct LaunchContext {
        let isEnabled: Bool
        let streamDisabled: Bool
        let includeVisualFixtures: Bool
        let includeWriteMarkdownFixture: Bool
        let mixedContentFixtures: Bool
        let queueHarnessEnabled: Bool
        let assistantOverlapFixture: Bool
        let realBusyLane: Bool
    }

    // periphery:ignore - debug harness state container
    private struct StickyState {
        let noStream: Bool
        let includeVisualFixtures: Bool
        let includeWriteMarkdownFixture: Bool
        let mixedContentFixtures: Bool
        let queueHarnessEnabled: Bool
        let assistantOverlapFixture: Bool
        let realBusyLane: Bool
    }

    // XCTest repeat mode can transiently reinstall/relaunch the app without
    // preserving our explicit harness launch args/env. Persist the last
    // harness launch knobs briefly so simulator relaunches stay in harness mode.
    // periphery:ignore - debug harness persistence keys
    private static let stickyTimestampKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.timestamp"
    // periphery:ignore - debug harness persistence keys
    private static let stickyNoStreamKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.noStream"
    // periphery:ignore - debug harness persistence keys
    private static let stickyVisualFixturesKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.visualFixtures"
    // periphery:ignore - debug harness persistence keys
    private static let stickyWriteMarkdownFixtureKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.writeMarkdownFixture"
    // periphery:ignore - debug harness persistence keys
    private static let stickyMixedContentKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.mixedContent"
    // periphery:ignore - debug harness persistence keys
    private static let stickyQueueHarnessKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.queueHarness"
    // periphery:ignore - debug harness persistence keys
    private static let stickyAssistantOverlapFixtureKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.assistantOverlapFixture"
    // periphery:ignore - debug harness persistence keys
    private static let stickyRealBusyLaneKey = "\(AppIdentifiers.subsystem).uiHangHarness.sticky.realBusyLane"
    // Keep sticky harness launch knobs alive long enough for long-running UI
    // suites where CoreSimulator may relaunch the app mid-run.
    // periphery:ignore - debug harness TTL constant
    private static let stickyTTLSeconds: TimeInterval = 900

    private static let launchContext = resolveLaunchContext()

    static var isEnabled: Bool {
#if DEBUG
#if targetEnvironment(simulator)
        launchContext.isEnabled
#else
        false
#endif
#else
        false
#endif
    }

    static var streamDisabled: Bool {
#if DEBUG
        launchContext.streamDisabled
#else
        true
#endif
    }

    static var uiTestMode: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["PI_UI_HANG_UI_TEST_MODE"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
#else
        false
#endif
    }

    static var includeVisualFixtures: Bool {
#if DEBUG
        if !uiTestMode { return true }
        return launchContext.includeVisualFixtures
#else
        false
#endif
    }

    static var includeWriteMarkdownFixture: Bool {
#if DEBUG
        launchContext.includeWriteMarkdownFixture
#else
        false
#endif
    }

    /// Short assistant rows after the visual fixtures (`PI_UI_HANG_TAIL_FILLER_ROWS`).
    /// A focused row scrolls to the top of the viewport only while enough content
    /// follows it. A tall iPad viewport otherwise clamps the timeline at its bottom,
    /// where a test has nowhere to drag it. Read from the environment on every use:
    /// a relaunch outside the test's own launch does not need this knob.
    static var tailFillerRowCount: Int {
#if DEBUG
        Int(ProcessInfo.processInfo.environment["PI_UI_HANG_TAIL_FILLER_ROWS"] ?? "") ?? 0
#else
        0
#endif
    }

    static var mixedContentFixtures: Bool {
#if DEBUG
        launchContext.mixedContentFixtures
#else
        false
#endif
    }

    static var queueHarnessEnabled: Bool {
#if DEBUG
        launchContext.queueHarnessEnabled
#else
        false
#endif
    }

    static var assistantOverlapFixture: Bool {
#if DEBUG
        launchContext.assistantOverlapFixture
#else
        false
#endif
    }

    /// Opt-in XCTest lane: keep collection `isBusy` / streaming-assistant ID
    /// while still driving tokens via Pulse (no auto stream loop).
    static var realBusyLane: Bool {
#if DEBUG
        launchContext.realBusyLane
#else
        false
#endif
    }

#if DEBUG
#if targetEnvironment(simulator)
    private static func resolveLaunchContext() -> LaunchContext {
        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment

        let explicitHarness = processInfo.arguments.contains("--ui-hang-harness")
            || environment["PI_UI_HANG_HARNESS"] == "1"
        let explicitNoStream = environment["PI_UI_HANG_NO_STREAM"] == "1"
        let explicitVisualFixtures = environment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] == "1"
        let explicitWriteMarkdownFixture = environment["PI_UI_HANG_INCLUDE_WRITE_MD_FIXTURE"] == "1"
        let explicitMixedContent = environment["PI_UI_HANG_MIXED_CONTENT"] == "1"
        let explicitQueueHarness = environment["PI_UI_HANG_QUEUE_HARNESS"] == "1"
        let explicitAssistantOverlapFixture = environment["PI_UI_HANG_ASSISTANT_OVERLAP_FIXTURE"] == "1"
        let explicitRealBusyLane = environment["PI_UI_HANG_REAL_BUSY"] == "1"

        if explicitHarness {
            persistStickyState(
                noStream: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
                mixedContentFixtures: explicitMixedContent,
                queueHarnessEnabled: explicitQueueHarness,
                assistantOverlapFixture: explicitAssistantOverlapFixture,
                realBusyLane: explicitRealBusyLane
            )
            return LaunchContext(
                isEnabled: true,
                streamDisabled: explicitNoStream,
                includeVisualFixtures: explicitVisualFixtures,
                includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
                mixedContentFixtures: explicitMixedContent,
                queueHarnessEnabled: explicitQueueHarness,
                assistantOverlapFixture: explicitAssistantOverlapFixture,
                realBusyLane: explicitRealBusyLane
            )
        }

        if isLikelyXCTestHarnessRelaunch(environment: environment),
           let stickyState = loadStickyState() {
            return LaunchContext(
                isEnabled: true,
                streamDisabled: stickyState.noStream,
                includeVisualFixtures: stickyState.includeVisualFixtures,
                includeWriteMarkdownFixture: stickyState.includeWriteMarkdownFixture,
                mixedContentFixtures: stickyState.mixedContentFixtures,
                queueHarnessEnabled: stickyState.queueHarnessEnabled,
                assistantOverlapFixture: stickyState.assistantOverlapFixture,
                realBusyLane: stickyState.realBusyLane
            )
        }

        if !isLikelyXCTestHarnessRelaunch(environment: environment) {
            clearStickyState()
        }

        return LaunchContext(
            isEnabled: false,
            streamDisabled: explicitNoStream,
            includeVisualFixtures: explicitVisualFixtures,
            includeWriteMarkdownFixture: explicitWriteMarkdownFixture,
            mixedContentFixtures: explicitMixedContent,
            queueHarnessEnabled: explicitQueueHarness,
            assistantOverlapFixture: explicitAssistantOverlapFixture,
            realBusyLane: explicitRealBusyLane
        )
    }

    private static func isLikelyXCTestHarnessRelaunch(environment: [String: String]) -> Bool {
        let hasSession = environment["XCTestSessionIdentifier"] != nil
        let hasBundleInjectPath = environment["XCTestBundleInjectPath"] != nil
        let injectedIntoUnusedHost = environment["XCInjectBundleInto"] == "unused"
        return hasSession && hasBundleInjectPath && injectedIntoUnusedHost
    }

    private static var stickyDefaults: UserDefaults {
        guard let bundleID = Bundle.main.bundleIdentifier?.lowercased() else {
            return .standard
        }
        return UserDefaults(suiteName: "group.\(bundleID)") ?? .standard
    }

    private static func persistStickyState(
        noStream: Bool,
        includeVisualFixtures: Bool,
        includeWriteMarkdownFixture: Bool,
        mixedContentFixtures: Bool,
        queueHarnessEnabled: Bool,
        assistantOverlapFixture: Bool,
        realBusyLane: Bool
    ) {
        let now = Date().timeIntervalSince1970
        stickyDefaults.set(now, forKey: stickyTimestampKey)
        stickyDefaults.set(noStream, forKey: stickyNoStreamKey)
        stickyDefaults.set(includeVisualFixtures, forKey: stickyVisualFixturesKey)
        stickyDefaults.set(includeWriteMarkdownFixture, forKey: stickyWriteMarkdownFixtureKey)
        stickyDefaults.set(mixedContentFixtures, forKey: stickyMixedContentKey)
        stickyDefaults.set(queueHarnessEnabled, forKey: stickyQueueHarnessKey)
        stickyDefaults.set(assistantOverlapFixture, forKey: stickyAssistantOverlapFixtureKey)
        stickyDefaults.set(realBusyLane, forKey: stickyRealBusyLaneKey)
    }

    private static func loadStickyState(now: Date = Date()) -> StickyState? {
        let defaults = stickyDefaults
        guard let timestamp = defaults.object(forKey: stickyTimestampKey) as? TimeInterval else {
            return nil
        }

        if now.timeIntervalSince1970 - timestamp > stickyTTLSeconds {
            clearStickyState()
            return nil
        }

        return StickyState(
            noStream: defaults.bool(forKey: stickyNoStreamKey),
            includeVisualFixtures: defaults.bool(forKey: stickyVisualFixturesKey),
            includeWriteMarkdownFixture: defaults.bool(forKey: stickyWriteMarkdownFixtureKey),
            mixedContentFixtures: defaults.bool(forKey: stickyMixedContentKey),
            queueHarnessEnabled: defaults.bool(forKey: stickyQueueHarnessKey),
            assistantOverlapFixture: defaults.bool(forKey: stickyAssistantOverlapFixtureKey),
            realBusyLane: defaults.bool(forKey: stickyRealBusyLaneKey)
        )
    }

    private static func clearStickyState() {
        let defaults = stickyDefaults
        defaults.removeObject(forKey: stickyTimestampKey)
        defaults.removeObject(forKey: stickyNoStreamKey)
        defaults.removeObject(forKey: stickyVisualFixturesKey)
        defaults.removeObject(forKey: stickyWriteMarkdownFixtureKey)
        defaults.removeObject(forKey: stickyMixedContentKey)
        defaults.removeObject(forKey: stickyQueueHarnessKey)
        defaults.removeObject(forKey: stickyAssistantOverlapFixtureKey)
        defaults.removeObject(forKey: stickyRealBusyLaneKey)
    }
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            includeWriteMarkdownFixture: false,
            mixedContentFixtures: false,
            queueHarnessEnabled: false,
            assistantOverlapFixture: false,
            realBusyLane: false
        )
    }
#endif
#else
    private static func resolveLaunchContext() -> LaunchContext {
        LaunchContext(
            isEnabled: false,
            streamDisabled: true,
            includeVisualFixtures: false,
            includeWriteMarkdownFixture: false,
            mixedContentFixtures: false,
            queueHarnessEnabled: false,
            assistantOverlapFixture: false,
            realBusyLane: false
        )
    }
#endif
}

// MARK: - Harness Screen

/// The UI-hang harness (`--ui-hang-harness`): the production chat timeline
/// (`ChatTimelineController`, rows owned by the harness) over three fixture
/// sessions, with controls that drive it and the `diag.*` values
/// `UIHarnessTestCase` reads. It is the root of a router stack, where the
/// chat reader pushes, and hides the stack's bar the way a chat does.
///
/// The timeline gets a new configuration when harness state it shows changes
/// (rows, render window, busy state, a scroll command, the theme), as the chat
/// screen pushes one; a diagnostics read (`harness.diag.tick`) only refreshes
/// the values. Scroll position is not observable, so a test taps the tick
/// before it reads one; an expansion the timeline makes itself (a header tap)
/// updates `diag.*Expanded` through observation of the reducer.
final class UIHangHarnessViewController: UIViewController, NavigationBarHiding {
    /// The harness at the root of a router stack, carrying `root` in its traits.
    static func screenStack(root: AppRootEnvironment) -> RouterNavigationController {
        PreviewHost.screenStack(root: root) { UIHangHarnessViewController(root: root) }
    }

    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    private static let assistantOverlapLastPhase = 1

    var hidesNavigationBar: Bool { true }

    private let root: AppRootEnvironment
    private let connection = ServerConnection()
    private let harnessReducer = TimelineReducer()
    private let scrollController = ChatScrollController()
    private let timeline = ChatTimelineController()
    private let chatReaderPayloadStore = ChatReaderPayloadStore()
    private let harnessNavigation = AppNavigation()
    private let frameIntervalMonitor = HarnessFrameIntervalMonitor()

    private var selectedSession: UIHangHarnessSession = .alpha
    private var sessionItems = UIHangHarnessFixtures.items
    private var renderWindow = UIHangHarnessViewController.initialRenderWindow
    private var pendingScrollCommand: ChatTimelineScrollCommand?
    private var scrollCommandNonce = 0

    private var heartbeat = 0
    private var stallCount = 0
    private var streamTick = 0
    private var streamEnabled = !UIHangHarnessConfig.streamDisabled
    private var diagnosticsTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    private var themeID = ThemeRuntimeState.currentThemeID()
    private var originalThemeID = ThemeRuntimeState.currentThemeID()
    private var hasAppeared = false

    private var queueStates: [UIHangHarnessSession: MessageQueueState] = [:]
    private var queueSystemEventSerial = 0
    private var assistantOverlapPhaseBySession: [UIHangHarnessSession: Int] = [:]
    private var assistantOverlapReadySnapshot = 0
    private var assistantRowHeightSnapshot = -1
    private var assistantRenderedOverlapSnapshot = -1
    private var assistantOverflowSnapshot = -1

    // MARK: Views

    private let content = UIStackView()
    private let readyLabel = UILabel()
    private let controlFlow = HarnessControlFlowView()
    private let queueControlFlow = HarnessControlFlowView()
    private let streamToggle = UIHangHarnessViewController.makeControl()
    private let messageQueue = MessageQueueView(presentation: .standalone)
    /// Carries `harness.timeline`; the collection view inside keeps the
    /// timeline's own `chat.timeline`, which the timeline's owners look up.
    private let timelineContainer = UIView()
    private var collectionView: UICollectionView?
    private let inputField = UITextField()
    private let diagnosticsStack = UIStackView()
    private var diagnosticLabels: [HarnessDiagnosticLabel] = []

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let collectionView {
            timeline.dismantle(collectionView)
        }
    }

    // MARK: Derived state

    private var currentItems: [ChatItem] {
        sessionItems[selectedSession] ?? []
    }

    private var currentQueueState: MessageQueueState {
        queueStates[selectedSession] ?? .empty
    }

    private var showsQueueContainer: Bool {
        !currentQueueState.steering.isEmpty || !currentQueueState.followUp.isEmpty
    }

    private var queueStartedEventCount: Int {
        currentItems.reduce(into: 0) { partial, item in
            guard case .systemEvent(_, let message) = item,
                  message.hasPrefix("Message Queue •"),
                  message.contains("started") else {
                return
            }
            partial += 1
        }
    }

    private var visibleItems: [ChatItem] {
        Array(currentItems.suffix(renderWindow))
    }

    private var hiddenCount: Int {
        max(0, currentItems.count - visibleItems.count)
    }

    private var streamTargetID: String {
        selectedSession.streamItemID
    }

    private var assistantOverlapItemID: String {
        "\(selectedSession.rawValue)-assistant-overlap"
    }

    private var assistantOverlapPhaseValue: Int {
        assistantOverlapPhaseBySession[selectedSession] ?? 0
    }

    /// Default XCTest mode stays idle so the working indicator does not prevent
    /// quiescence. `realBusyLane` is the explicit opt-in that feeds production
    /// `isBusy` / streaming-assistant IDs while Pulse still owns progression.
    private var preservesBusyStreaming: Bool {
        !UIHangHarnessConfig.uiTestMode || UIHangHarnessConfig.realBusyLane
    }

    private var collectionStreamingAssistantID: String? {
        if UIHangHarnessConfig.assistantOverlapFixture,
           currentItems.contains(where: { $0.id == assistantOverlapItemID }) {
            return assistantOverlapItemID
        }

        guard streamEnabled, preservesBusyStreaming else { return nil }
        return streamTargetID
    }

    private var collectionIsBusy: Bool {
        streamEnabled && preservesBusyStreaming
    }

    /// Spinner animation still blocks XCTest idle; collection busy/streaming
    /// flags are the oracle. Keep the indicator off in UI tests.
    private var collectionShowsWorkingIndicator: Bool {
        collectionIsBusy && !UIHangHarnessConfig.uiTestMode
    }

    private var streamCharacterCount: Int {
        guard let item = currentItems.first(where: { $0.id == streamTargetID }),
              case .assistantMessage(_, let text, _) = item else {
            return 0
        }
        return text.count
    }

    private var topVisibleIndex: Int {
        guard let id = scrollController.currentTopVisibleItemId,
              let index = visibleItems.firstIndex(where: { $0.id == id }) else {
            return -1
        }
        return index
    }

    private var themeOrdinal: Int {
        switch themeID {
        case .dark: return 0
        case .oled: return 1
        case .light: return 2
        case .night: return 3
        case .custom: return 4
        }
    }

    private var visualToolCount: Int {
        currentItems.reduce(into: 0) { partialResult, item in
            if case .toolCall(let id, _, _, _, _, _, _) = item,
               id.contains("-visual-tool-") {
                partialResult += 1
            }
        }
    }

    private func isExpanded(_ itemID: String) -> Int {
        harnessReducer.expandedItemIDs.contains(itemID) ? 1 : 0
    }

    private func isTopVisible(_ itemID: String) -> Int {
        scrollController.currentTopVisibleItemId == itemID ? 1 : 0
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        installContent()
        let collectionView = timeline.makeCollectionView(configuration: makeTimelineConfiguration(), contentRoot: root)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        timelineContainer.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
        ])
        self.collectionView = collectionView
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Back from a pushed chat reader appears again. A real chat restores the
        // viewport it left, so only the first appearance seeds rows, resets
        // metrics, and jumps to the bottom.
        let isFirstAppearance = !hasAppeared
        hasAppeared = true
        originalThemeID = ThemeRuntimeState.currentThemeID()
        ThemeRuntimeState.setThemeID(themeID)
        if isFirstAppearance {
            resetRuntimeMetrics()
            renderWindow = min(Self.initialRenderWindow, currentItems.count)
            seedVisualToolFixtures()
            ensureAssistantOverlapFixtureExists()
        }
        frameIntervalMonitor.start()
        startDiagnosticsLoop()
        restartStreamingLoop()
        render()

        guard isFirstAppearance else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollToBottom(animated: false)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        streamTask?.cancel()
        streamTask = nil
        frameIntervalMonitor.stop()
        ThemeRuntimeState.setThemeID(originalThemeID)
    }

    /// Observation re-runs this when the reducer's expanded rows change (a
    /// header tap in the timeline); `render()` asks for it after harness state.
    override func updateProperties() {
        super.updateProperties()
        refreshDiagnostics()
    }

    // MARK: Rendering

    /// Pushes harness state to the timeline and the chrome, and asks for a
    /// diagnostics refresh.
    private func render() {
        if let collectionView {
            timeline.contentRoot = root
            timeline.update(configuration: makeTimelineConfiguration(), collectionView: collectionView)
        }
        applyTheme()
        streamToggle.configuration?.title = streamEnabled ? "Pause Stream" : "Resume Stream"
        controlFlow.invalidateIntrinsicContentSize()
        let showsQueue = UIHangHarnessConfig.queueHarnessEnabled && showsQueueContainer
        if showsQueue {
            messageQueue.apply(makeQueueConfiguration(), themeID: ThemeRuntimeState.currentThemeID())
        }
        if messageQueue.isHidden == showsQueue {
            messageQueue.isHidden = !showsQueue
        }
        setNeedsUpdateProperties()
    }

    private func applyTheme() {
        view.backgroundColor = .themeBg
        timelineContainer.backgroundColor = .themeBg
        view.tintColor = .themeBlue
    }

    private func makeTimelineConfiguration() -> ChatTimelineConfiguration {
        ChatTimelineConfiguration(
            items: visibleItems,
            hiddenCount: hiddenCount,
            renderWindowStep: Self.renderWindowStep,
            isBusy: collectionIsBusy,
            showsWorkingIndicator: collectionShowsWorkingIndicator,
            streamingAssistantID: collectionStreamingAssistantID,
            sessionId: "harness-\(selectedSession.rawValue)",
            workspaceId: "harness-workspace",
            onFork: { _ in },
            onOpenChatReader: { [weak self] payload in self?.openChatReader(payload) },
            onBackSwipe: {},
            onShowEarlier: { [weak self] in
                // The timeline asks from inside its own update; answer after it.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.renderWindow = min(self.currentItems.count, self.renderWindow + Self.renderWindowStep)
                    self.render()
                }
            },
            scrollCommand: pendingScrollCommand,
            scrollController: scrollController,
            reducer: harnessReducer,
            toolOutputStore: harnessReducer.toolOutputStore,
            toolArgsStore: harnessReducer.toolArgsStore,
            toolSegmentStore: harnessReducer.toolSegmentStore,
            toolDetailsStore: harnessReducer.toolDetailsStore,
            sessionContent: connection.sessionContent,
            iconAssetCache: connection.iconAssetCache,
            audioPlayer: connection.audioPlayer
        )
    }

    private func makeQueueConfiguration() -> MessageQueueSurfaceConfiguration {
        MessageQueueSurfaceConfiguration(
            queue: currentQueueState,
            onRemove: { [weak self] itemId in
                guard let self else { return }
                var queue = self.currentQueueState
                queue.steering.removeAll { $0.id == itemId }
                queue.followUp.removeAll { $0.id == itemId }
                queue.version += 1
                self.setCurrentQueueState(queue)
                self.render()
            },
            onEditInComposer: { [weak self] in
                guard let self,
                      let plan = MessageQueueComposerRestore.plan(
                          queue: self.currentQueueState,
                          currentText: self.inputField.text ?? ""
                      ) else { return }
                self.inputField.text = plan.text
                self.clearQueueItems()
            }
        )
    }

    private func openChatReader(_ payload: ChatReaderPayload) {
        chatReaderPayloadStore.removeAll()
        let route = chatReaderPayloadStore.store(payload)
        Router.push(
            ChatReaderViewController(target: route, store: chatReaderPayloadStore, navigation: harnessNavigation),
            from: self
        )
    }

    // MARK: Chrome

    private func installContent() {
        readyLabel.text = "Harness Ready"
        readyLabel.font = .preferredFont(forTextStyle: .caption1)
        readyLabel.adjustsFontForContentSizeCategory = true
        readyLabel.accessibilityIdentifier = "harness.ready"

        let sessions = UIStackView(arrangedSubviews: UIHangHarnessSession.allCases.map { session in
            control(session.title, id: session.accessibilityID) { $0.selectSession(session) }
        })
        sessions.axis = .horizontal
        sessions.spacing = 8
        sessions.alignment = .center
        let sessionRow = UIStackView(arrangedSubviews: [sessions, UIView()])
        sessionRow.axis = .horizontal

        // Visual fixtures add extra chrome; keep every control at its
        // intrinsic tappable size instead of crushing the trailing buttons
        // (Reset Metrics was 24x254 and not AX-hittable).
        controlFlow.setControls(mainControls())
        var controlRows: [UIView] = [sessionRow, controlFlow]
        if UIHangHarnessConfig.queueHarnessEnabled {
            queueControlFlow.setControls(queueControls())
            controlRows.append(queueControlFlow)
        }
        let controls = UIStackView(arrangedSubviews: controlRows)
        controls.axis = .vertical
        controls.spacing = 8

        messageQueue.isHidden = true

        timelineContainer.accessibilityIdentifier = "harness.timeline"
        timelineContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        timelineContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        inputField.borderStyle = .roundedRect
        inputField.placeholder = "Harness input"
        inputField.accessibilityIdentifier = "harness.input"

        content.axis = .vertical
        content.spacing = 10
        for row in [readyLabel, controls, messageQueue, timelineContainer, inputField, diagnosticsRow()] {
            content.addArrangedSubview(row)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
            // The timeline gives way to the keyboard when the input has focus.
            content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
    }

    private func mainControls() -> [UIView] {
        var controls = [
            control("Top", id: "harness.scroll.top") { $0.scrollToTop(animated: !UIHangHarnessConfig.uiTestMode) },
            control("Bottom", id: "harness.scroll.bottom") { $0.scrollToBottom(animated: !UIHangHarnessConfig.uiTestMode) },
            control("Expand", id: "harness.expand.all") { $0.expandRenderWindow() },
            control("ToolSet", id: "harness.tools.render") { $0.expandVisualToolSet() },
            control("Extension", id: "harness.extension.focus") { $0.focusTool(itemID: $0.selectedSession.extensionMarkdownToolID) },
            control("Extension Text", id: "harness.extensionText.focus") { $0.focusTool(itemID: $0.selectedSession.extensionTextToolID) },
            // Scrolls only: the test expands the row with a real header tap.
            control("Notebook", id: "harness.notebook.scroll") { $0.scrollToNotebook() },
            control("Write Markdown", id: "harness.writeMarkdown.focus") { $0.focusTool(itemID: $0.selectedSession.writeMarkdownToolID) },
            control("Read Markdown", id: "harness.readMarkdown.focus") { $0.focusTool(itemID: $0.selectedSession.readMarkdownToolID) },
        ]
        if UIHangHarnessConfig.assistantOverlapFixture {
            controls.append(control("Assistant Overlap", id: "harness.assistantOverlap.focus") { $0.focusAssistantOverlapFixture() })
            controls.append(control("Advance Overlap", id: "harness.assistantOverlap.advance") { $0.advanceAssistantOverlapFixture() })
        }
        if UIHangHarnessConfig.includeVisualFixtures {
            controls.append(control("Table", id: "harness.visual.table.focus") { $0.focusVisualAssistantMarkdown() })
        }
        controls.append(control("Visual Image", id: "harness.visual.image") { $0.scrollToVisualUserImage(animated: false) })
        configure(streamToggle, title: "Pause Stream", id: "harness.stream.toggle") { $0.toggleStream() }
        controls.append(streamToggle)
        controls.append(control("Pulse", id: "harness.stream.pulse") { $0.pulseStream(count: 6) })
        if UIHangHarnessConfig.realBusyLane {
            controls.append(control("Pulse Fence", id: "harness.stream.pulseFence") { $0.pulseFenceClose() })
        }
        controls.append(control("Theme", id: "harness.theme.toggle") { $0.toggleTheme() })
        controls.append(control("Diag", id: "harness.diag.tick") { $0.refreshDiagnosticsTick() })
        controls.append(control("Reset Metrics", id: "harness.metrics.reset") { $0.resetMetricsTick() })
        return controls
    }

    private func queueControls() -> [UIView] {
        [
            control("Queue Steer", id: "harness.queue.enqueueSteer") { $0.enqueueQueueItem(kind: .steer) },
            control("Queue Follow", id: "harness.queue.enqueueFollow") { $0.enqueueQueueItem(kind: .followUp) },
            control("Start Steer", id: "harness.queue.startSteer") { $0.startQueueItem(kind: .steer) },
            control("Start Follow", id: "harness.queue.startFollow") { $0.startQueueItem(kind: .followUp) },
            control("Clear Queue", id: "harness.queue.clear") { $0.clearQueueItems() },
            control("Queue Attachments", id: "harness.queue.enqueueAttachments") { $0.enqueueAttachmentQueueItems() },
        ]
    }

    /// Diagnostics must not impose their combined intrinsic width on the
    /// queue or the input; growing counters otherwise push Remove offscreen.
    /// The reader probes sit beside them, not in the control flow: a control
    /// there re-wraps the flow and moves every row the other tests scroll to.
    private func diagnosticsRow() -> UIView {
        diagnosticsStack.axis = .horizontal
        diagnosticsStack.spacing = 10
        diagnosticsStack.alignment = .center
        for (id, read) in Self.diagnostics {
            let label = HarnessDiagnosticLabel(owner: self, read: read)
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
            )
            label.accessibilityIdentifier = id
            diagnosticLabels.append(label)
            diagnosticsStack.addArrangedSubview(label)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(diagnosticsStack)
        NSLayoutConstraint.activate([
            diagnosticsStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            diagnosticsStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            diagnosticsStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            diagnosticsStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            diagnosticsStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        // Open a reader the way a timeline row does: a thinking row long enough
        // to overflow (full screen by double tap), and an extension widget's
        // surface, the subagents pill's list.
        let probes = UIStackView(arrangedSubviews: [
            probe("T", id: "harness.thinking.focus") { $0.focusReaderThinking() },
            probe("E", id: "harness.extensionReader.open") { $0.openExtensionSurfaceReader() },
        ])
        probes.axis = .horizontal
        probes.spacing = 2

        let row = UIStackView(arrangedSubviews: [scroll, probes])
        row.axis = .horizontal
        row.spacing = 4
        row.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return row
    }

    /// A bordered, small harness button at its intrinsic size.
    private func control(_ title: String, id: String, action: @escaping (UIHangHarnessViewController) -> Void) -> UIButton {
        let button = Self.makeControl()
        configure(button, title: title, id: id, action: action)
        return button
    }

    private static func makeControl() -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.buttonSize = .small
        configuration.titleLineBreakMode = .byClipping
        let button = UIButton(configuration: configuration)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func configure(
        _ button: UIButton,
        title: String,
        id: String,
        action: @escaping (UIHangHarnessViewController) -> Void
    ) {
        button.configuration?.title = title
        button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
        }, for: .primaryActionTriggered)
    }

    /// A 14-point plain text button beside the diagnostics.
    private func probe(_ title: String, id: String, action: @escaping (UIHangHarnessViewController) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 8)]))
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
        }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 14),
            button.heightAnchor.constraint(equalToConstant: 14),
        ])
        return button
    }

    // MARK: Diagnostics

    /// Each `diag.*` value and how to read it. A label reads its value when
    /// accessibility asks (`HarnessDiagnosticLabel`), so frame and perf
    /// counters that move without a harness event are current on every test
    /// read, and nothing has to tick to keep them so (which would hold off
    /// XCTest's idle).
    private static let diagnostics: [(id: String, read: (UIHangHarnessViewController) -> Int)] = [
        ("diag.heartbeat", { $0.heartbeat }),
        ("diag.stallCount", { $0.stallCount }),
        ("diag.itemCount", { $0.currentItems.count }),
        ("diag.nearBottom", { $0.scrollController.isCurrentlyNearBottom ? 1 : 0 }),
        ("diag.topIndex", { $0.topVisibleIndex }),
        ("diag.offsetY", { Int($0.scrollController.currentContentOffsetY.rounded()) }),
        ("diag.streamTick", { $0.streamTick }),
        ("diag.streamChars", { $0.streamCharacterCount }),
        ("diag.isBusy", { $0.collectionIsBusy ? 1 : 0 }),
        ("diag.streaming", { $0.collectionStreamingAssistantID == nil ? 0 : 1 }),
        ("diag.theme", { $0.themeOrdinal }),
        ("diag.nativeMode", { _ in 1 }),
        ("diag.nativeUserMode", { _ in 1 }),
        ("diag.nativeThinkingMode", { _ in 1 }),
        ("diag.nativeToolMode", { _ in 1 }),
        ("diag.visualTools", { $0.visualToolCount }),
        ("diag.extensionExpanded", { $0.isExpanded($0.selectedSession.extensionMarkdownToolID) }),
        ("diag.extensionTextExpanded", { $0.isExpanded($0.selectedSession.extensionTextToolID) }),
        ("diag.notebookExpanded", { $0.isExpanded($0.selectedSession.notebookToolID) }),
        ("diag.writeMarkdownExpanded", { $0.isExpanded($0.selectedSession.writeMarkdownToolID) }),
        ("diag.readMarkdownExpanded", { $0.isExpanded($0.selectedSession.readMarkdownToolID) }),
        ("diag.assistantOverlapReady", { $0.assistantOverlapReadySnapshot }),
        ("diag.assistantOverlapPhase", { $0.assistantOverlapPhaseValue }),
        ("diag.assistantRowHeightPx", { $0.assistantRowHeightSnapshot }),
        ("diag.assistantRenderedOverlapPx", { $0.assistantRenderedOverlapSnapshot }),
        ("diag.assistantOverflowPx", { $0.assistantOverflowSnapshot }),
        ("diag.extensionTop", { $0.isTopVisible($0.selectedSession.extensionMarkdownToolID) }),
        ("diag.extensionTextTop", { $0.isTopVisible($0.selectedSession.extensionTextToolID) }),
        ("diag.applyMs", { _ in ChatTimelinePerf.snapshot().applyLastMs }),
        ("diag.layoutMs", { _ in ChatTimelinePerf.snapshot().layoutLastMs }),
        ("diag.cellMs", { _ in ChatTimelinePerf.snapshot().cellConfigureLastMs }),
        ("diag.applyMax", { _ in ChatTimelinePerf.snapshot().applyMaxMs }),
        ("diag.layoutMax", { _ in ChatTimelinePerf.snapshot().layoutMaxMs }),
        ("diag.cellMax", { _ in ChatTimelinePerf.snapshot().cellConfigureMaxMs }),
        ("diag.perfGuardrail", { _ in ChatTimelinePerf.snapshot().hardGuardrailBreachCount }),
        ("diag.failsafeRows", { _ in ChatTimelinePerf.snapshot().failsafeConfigureCount }),
        ("diag.scrollRate", { _ in ChatTimelinePerf.snapshot().scrollCommandsPerSecond }),
        ("diag.frameSamples", { $0.frameIntervalMonitor.snapshot().sampleCount }),
        ("diag.frameP95", { $0.frameIntervalMonitor.snapshot().p95IntervalMs }),
        ("diag.frameP99", { $0.frameIntervalMonitor.snapshot().p99IntervalMs }),
        ("diag.frameMax", { $0.frameIntervalMonitor.snapshot().maxIntervalMs }),
        ("diag.frameMaxFiltered", { $0.frameIntervalMonitor.snapshot().filteredMaxIntervalMs }),
        ("diag.frameOver34Pct", { $0.frameIntervalMonitor.snapshot().over34MsPercent }),
        ("diag.frameOver50Pct", { $0.frameIntervalMonitor.snapshot().over50MsPercent }),
        ("diag.frameOver50", { $0.frameIntervalMonitor.snapshot().over50MsCount }),
        ("diag.frameOver50Filtered", { $0.frameIntervalMonitor.snapshot().filteredOver50MsCount }),
        ("diag.queueVisible", { $0.showsQueueContainer ? 1 : 0 }),
        ("diag.queueSteeringCount", { $0.currentQueueState.steering.count }),
        ("diag.queueFollowUpCount", { $0.currentQueueState.followUp.count }),
        ("diag.queueVersion", { $0.currentQueueState.version }),
        ("diag.queueStartedEvents", { $0.queueStartedEventCount }),
    ]

    /// The values on screen; a test reads them live either way.
    private func refreshDiagnostics() {
        for label in diagnosticLabels {
            label.refreshText()
        }
    }

    private func refreshDiagnosticsTick() {
        captureAssistantOverlapDiagnostics()
        heartbeat &+= 1
        setNeedsUpdateProperties()
    }

    private func resetMetricsTick() {
        resetRuntimeMetrics()
        setNeedsUpdateProperties()
    }

    private func resetRuntimeMetrics() {
        ChatTimelinePerf.reset()
        frameIntervalMonitor.reset()
    }

    private func startDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil

        // UI tests need deterministic idle windows; a continuously mutating
        // heartbeat would prevent XCTest from considering the app idle.
        guard !UIHangHarnessConfig.uiTestMode else { return }

        diagnosticsTask = Task { @MainActor [weak self] in
            var lastTick = ContinuousClock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let now = ContinuousClock.now
                if now - lastTick > .milliseconds(1_500) {
                    self.stallCount &+= 1
                }
                self.heartbeat &+= 1
                self.setNeedsUpdateProperties()
                lastTick = now
            }
        }
    }

    // MARK: Sessions and streaming

    private func selectSession(_ session: UIHangHarnessSession) {
        guard session != selectedSession else { return }
        selectedSession = session
        renderWindow = min(Self.initialRenderWindow, currentItems.count)
        seedVisualToolFixtures()
        ensureAssistantOverlapFixtureExists()
        heartbeat &+= 1
        restartStreamingLoop()
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.scrollToBottom(animated: false)
        }
    }

    private func toggleStream() {
        streamEnabled.toggle()
        heartbeat &+= 1
        restartStreamingLoop()
        render()
    }

    private func restartStreamingLoop() {
        streamTask?.cancel()
        streamTask = nil

        guard streamEnabled else { return }

        let session = selectedSession
        let streamID = session.streamItemID
        ensureStreamItemExists(session: session, streamID: streamID)

        // In UI test mode, stream progression is driven by explicit "Pulse"
        // button taps so XCTest can reach idle deterministically.
        guard !UIHangHarnessConfig.uiTestMode else { return }

        streamTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.appendStreamToken(session: session, streamID: streamID)
                self.render()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func ensureStreamItemExists(session: UIHangHarnessSession, streamID: String) {
        var items = sessionItems[session] ?? []
        guard !items.contains(where: { $0.id == streamID }) else { return }

        items.append(.assistantMessage(
            id: streamID,
            text: "",
            timestamp: Date()
        ))

        sessionItems[session] = items
        // Expanding all then starting a stream must not drop the first rows
        // from the suffix render window.
        if session == selectedSession, renderWindow >= items.count - 1 {
            renderWindow = max(renderWindow, items.count)
        }
    }

    private func appendStreamToken(session: UIHangHarnessSession, streamID: String) {
        appendStreamText(session: session, streamID: streamID, fragment: " token_\(streamTick % 23)")
    }

    private func appendStreamText(session: UIHangHarnessSession, streamID: String, fragment: String) {
        var items = sessionItems[session] ?? []

        guard let index = items.firstIndex(where: { $0.id == streamID }) else {
            ensureStreamItemExists(session: session, streamID: streamID)
            return
        }

        if case .assistantMessage(_, let text, let timestamp) = items[index] {
            items[index] = .assistantMessage(id: streamID, text: text + fragment, timestamp: timestamp)
        }

        sessionItems[session] = items
        streamTick &+= 1

        let visible = Array(items.suffix(renderWindow))
        scrollController.itemCount = visible.count

        // Busy streaming follow is intentionally owned by
        // the timeline after layout settles. The harness should
        // exercise the same ambient tail governor as production rather than
        // emitting scrollToItem commands on every token.
    }

    private func pulseStream(count: Int) {
        guard streamEnabled else {
            toggleStream()
            return
        }

        let session = selectedSession
        let streamID = session.streamItemID
        ensureStreamItemExists(session: session, streamID: streamID)

        for _ in 0..<count {
            appendStreamToken(session: session, streamID: streamID)
        }
        render()
    }

    /// Cheap busy-lane path: close mermaid then latex fences on the live stream row.
    private func pulseFenceClose() {
        guard streamEnabled else {
            toggleStream()
            return
        }

        let session = selectedSession
        let streamID = session.streamItemID
        ensureStreamItemExists(session: session, streamID: streamID)
        appendStreamText(
            session: session,
            streamID: streamID,
            fragment: "\n\n```mermaid\ngraph TD\n  A-->B\n"
        )
        appendStreamText(
            session: session,
            streamID: streamID,
            fragment: "```\n\n$$\nx^2 + y^2 = z^2\n"
        )
        appendStreamText(
            session: session,
            streamID: streamID,
            fragment: "$$\n"
        )
        render()
    }

    private func toggleTheme() {
        switch themeID {
        case .dark:
            themeID = .oled
        case .oled:
            themeID = .light
        case .light:
            themeID = .night
        case .night, .custom:
            themeID = .dark
        }
        ThemeRuntimeState.setThemeID(themeID)
        heartbeat &+= 1
        render()
    }

    // MARK: Fixtures

    private func seedVisualToolFixtures() {
        UIHangHarnessFixtures.seedToolContent(
            into: harnessReducer,
            includeWriteMarkdown: UIHangHarnessConfig.includeWriteMarkdownFixture
        )
    }

    private func expandRenderWindow() {
        renderWindow = currentItems.count
        heartbeat &+= 1
        render()
    }

    private func expandVisualToolSet() {
        for id in selectedSession.visualToolIDs {
            harnessReducer.expandedItemIDs.insert(id)
        }

        heartbeat &+= 1
        scrollToBottom(animated: false)
    }

    private func scrollToNotebook() {
        renderWindow = currentItems.count
        heartbeat &+= 1
        issueScrollCommand(
            id: selectedSession.notebookToolID,
            anchor: .viewport(relativeY: 0.2),
            animated: false
        )
    }

    /// A thinking row long enough that its viewport overflows, which is what
    /// offers the full-screen reader. Added on first use.
    private func focusReaderThinking() {
        let itemID = "\(selectedSession.rawValue)-reader-thinking"
        if !currentItems.contains(where: { $0.id == itemID }) {
            let lines = (1...80).map { "Reader thinking line \($0): weighing the renderer parity trade-offs." }
            var items = currentItems
            items.append(.thinking(
                id: itemID,
                preview: lines.joined(separator: "\n"),
                hasMore: true,
                isDone: true
            ))
            sessionItems[selectedSession] = items
        }
        focusTool(itemID: itemID)
    }

    private func openExtensionSurfaceReader() {
        openChatReader(.extensionNative(ExtensionNativeReaderContent(
            surface: ExtensionUINativeSurface(
                version: 1,
                id: "widget:jobs",
                source: "widget",
                presentation: ExtensionUINativePresentation(style: "surfacePanel", title: "Jobs", subtitle: nil),
                blocks: [],
                fallback: ExtensionUINativeFallback(text: "nothing running", lines: nil)
            ),
            identifierSuffix: "jobs",
            title: "Jobs",
            subtitle: "2 running"
        )))
    }

    private func focusTool(itemID: String) {
        guard currentItems.contains(where: { $0.id == itemID }) else { return }

        renderWindow = currentItems.count
        harnessReducer.expandedItemIDs.insert(itemID)
        heartbeat &+= 1
        issueScrollCommand(id: itemID, anchor: .top, animated: false)
    }

    private func scrollToVisualUserImage(animated: Bool) {
        let itemID = "\(selectedSession.rawValue)-visual-user-image"
        guard currentItems.contains(where: { $0.id == itemID }) else { return }
        issueScrollCommand(id: itemID, anchor: .top, animated: animated)
    }

    private func focusVisualAssistantMarkdown() {
        let itemID = "\(selectedSession.rawValue)-visual-assistant-table"
        guard currentItems.contains(where: { $0.id == itemID }) else { return }
        renderWindow = currentItems.count
        heartbeat &+= 1
        issueScrollCommand(id: itemID, anchor: .top, animated: false)
    }

    // MARK: Assistant overlap fixture

    private func focusAssistantOverlapFixture() {
        ensureAssistantOverlapFixtureExists()
        guard currentItems.contains(where: { $0.id == assistantOverlapItemID }) else {
            render()
            return
        }
        renderWindow = currentItems.count
        heartbeat &+= 1
        issueScrollCommand(id: assistantOverlapItemID, anchor: .top, animated: false)
        scheduleAssistantOverlapDiagnosticsRefresh()
    }

    private func ensureAssistantOverlapFixtureExists() {
        guard UIHangHarnessConfig.assistantOverlapFixture,
              !currentItems.contains(where: { $0.id == assistantOverlapItemID }) else {
            return
        }

        var items = currentItems
        items.append(.assistantMessage(
            id: assistantOverlapItemID,
            text: UIHangHarnessFixtures.assistantOverlapText(phase: assistantOverlapPhaseValue, session: selectedSession),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(items.count + 9_000))
        ))
        sessionItems[selectedSession] = items
    }

    private func advanceAssistantOverlapFixture() {
        ensureAssistantOverlapFixtureExists()
        guard UIHangHarnessConfig.assistantOverlapFixture,
              assistantOverlapPhaseValue < Self.assistantOverlapLastPhase,
              let index = currentItems.firstIndex(where: { $0.id == assistantOverlapItemID }),
              case .assistantMessage(_, _, let timestamp) = currentItems[index] else {
            render()
            return
        }

        let nextPhase = assistantOverlapPhaseValue + 1
        var items = currentItems
        items[index] = .assistantMessage(
            id: assistantOverlapItemID,
            text: UIHangHarnessFixtures.assistantOverlapText(phase: nextPhase, session: selectedSession),
            timestamp: timestamp
        )
        sessionItems[selectedSession] = items
        assistantOverlapPhaseBySession[selectedSession] = nextPhase
        heartbeat &+= 1
        render()
        scheduleAssistantOverlapDiagnosticsRefresh()
    }

    private func scheduleAssistantOverlapDiagnosticsRefresh(retriesRemaining: Int = 12) {
        guard UIHangHarnessConfig.assistantOverlapFixture, retriesRemaining > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.captureAssistantOverlapDiagnostics()
            self.heartbeat &+= 1
            self.setNeedsUpdateProperties()

            if self.assistantOverlapReadySnapshot == 0 || self.assistantOverlapPhaseValue < Self.assistantOverlapLastPhase {
                self.scheduleAssistantOverlapDiagnosticsRefresh(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    private func captureAssistantOverlapDiagnostics() {
        guard UIHangHarnessConfig.assistantOverlapFixture else {
            assistantOverlapReadySnapshot = 0
            assistantRowHeightSnapshot = -1
            assistantRenderedOverlapSnapshot = -1
            assistantOverflowSnapshot = -1
            return
        }

        if let row = assistantOverlapRowView(itemID: assistantOverlapItemID) {
            assistantOverlapReadySnapshot = 1
            assistantRowHeightSnapshot = Int(row.bounds.height.rounded())
            assistantRenderedOverlapSnapshot = Int(row.debugMarkdownRenderedOverlapPoints.rounded())
            assistantOverflowSnapshot = Int(row.debugMarkdownOverflowPoints.rounded())
            return
        }

        guard let snapshot = AssistantTimelineRowContentView.debugSnapshot(for: assistantOverlapItemID) else {
            assistantOverlapReadySnapshot = 0
            assistantRowHeightSnapshot = -1
            assistantRenderedOverlapSnapshot = -1
            assistantOverflowSnapshot = -1
            return
        }

        assistantOverlapReadySnapshot = 1
        assistantRowHeightSnapshot = Int(snapshot.frameHeight.rounded())
        assistantRenderedOverlapSnapshot = Int(snapshot.overlapPoints.rounded())
        assistantOverflowSnapshot = Int(snapshot.overflowPoints.rounded())
    }

    /// The assistant row of `itemID` in this harness's timeline: by its own
    /// identifier, else inside the cell that carries the row's identifier.
    private func assistantOverlapRowView(itemID: String) -> AssistantTimelineRowContentView? {
        guard let collectionView else { return nil }
        collectionView.layoutIfNeeded()
        let rowIdentifier = "chat.timeline.assistant.\(itemID)"
        let cellIdentifier = "chat.timeline.row.\(itemID)"
        if let row: AssistantTimelineRowContentView = Self.firstSubview(in: collectionView, where: {
            $0.accessibilityIdentifier == rowIdentifier
        }) {
            return row
        }
        guard let cell: SafeSizingCell = Self.firstSubview(in: collectionView, where: {
            $0.accessibilityIdentifier == cellIdentifier
        }) else { return nil }
        return Self.firstSubview(in: cell, where: { _ in true })
    }

    private static func firstSubview<View: UIView>(in root: UIView, where matches: (View) -> Bool) -> View? {
        if let view = root as? View, matches(view) {
            return view
        }
        for subview in root.subviews {
            if let found: View = firstSubview(in: subview, where: matches) {
                return found
            }
        }
        return nil
    }

    // MARK: Queue

    private func setCurrentQueueState(_ state: MessageQueueState) {
        queueStates[selectedSession] = state
    }

    private func enqueueQueueItem(kind: MessageQueueKind) {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let item = MessageQueueItem(
            id: UUID().uuidString,
            message: kind == .steer
                ? "Harness steer message \(streamTick + 1)"
                : "Harness follow-up message \(streamTick + 1)",
            createdAt: now
        )

        var next = currentQueueState
        switch kind {
        case .steer:
            next.steering.append(item)
        case .followUp:
            next.followUp.append(item)
        }

        next.version += 1
        setCurrentQueueState(next)
        heartbeat &+= 1
        render()
    }

    private func enqueueAttachmentQueueItems() {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let image = ChatAttachmentRef(
            type: "attachment",
            id: "harness-image",
            source: .upload,
            name: "image-1.jpg",
            mimeType: "image/jpeg",
            sizeBytes: 1_024,
            sha256: nil,
            kind: .image,
            workspacePath: ".pi/attachments/harness/image-1.jpg"
        )
        let file = ChatAttachmentRef(
            type: "attachment",
            id: "harness-file",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 256,
            sha256: nil,
            kind: .text,
            workspacePath: ".pi/attachments/harness/notes.txt"
        )

        var next = currentQueueState
        next.steering.append(MessageQueueItem(
            id: "harness-image-item",
            message: "",
            attachments: [image],
            createdAt: now
        ))
        next.steering.append(MessageQueueItem(
            id: "harness-file-item",
            message: "",
            attachments: [file],
            createdAt: now + 1
        ))
        next.version += 1
        setCurrentQueueState(next)
        heartbeat &+= 1
        render()
    }

    private func startQueueItem(kind: MessageQueueKind) {
        var next = currentQueueState
        let startedItem: MessageQueueItem

        switch kind {
        case .steer:
            guard !next.steering.isEmpty else { return }
            startedItem = next.steering.removeFirst()
        case .followUp:
            guard !next.followUp.isEmpty else { return }
            startedItem = next.followUp.removeFirst()
        }

        next.version += 1
        setCurrentQueueState(next)

        queueSystemEventSerial &+= 1
        let label = kind == .steer ? "Steering" : "Follow-up"
        let message = "Message Queue • \(label) started: \(startedItem.message)"

        var items = currentItems
        items.append(.systemEvent(
            id: "\(selectedSession.rawValue)-queue-started-\(queueSystemEventSerial)",
            message: message
        ))
        sessionItems[selectedSession] = items

        heartbeat &+= 1
        render()
    }

    private func clearQueueItems() {
        var next = currentQueueState
        next.steering = []
        next.followUp = []
        next.version += 1
        setCurrentQueueState(next)
        heartbeat &+= 1
        render()
    }

    // MARK: Scroll commands

    private func scrollToTop(animated: Bool) {
        guard let firstID = visibleItems.first?.id else { return }
        issueScrollCommand(id: firstID, anchor: .top, animated: animated)
    }

    private func scrollToBottom(animated: Bool) {
        guard let bottomItemID = visibleItems.last?.id else { return }
        issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: animated)
    }

    private func issueScrollCommand(id: String, anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        scrollCommandNonce &+= 1
        pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: scrollCommandNonce
        )
        render()
    }
}

/// DEBUG chrome only: wraps harness buttons onto extra rows instead of
/// compressing them below a tappable size when visual fixtures add controls.
private final class HarnessControlFlowView: UIView {
    private let spacing: CGFloat = 8
    private var laidOutWidth: CGFloat = 0

    func setControls(_ controls: [UIView]) {
        for subview in subviews { subview.removeFromSuperview() }
        for control in controls { addSubview(control) }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: bounds.width, place: false))
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, place: true)
        // The height depends on the width, which is known only now.
        if laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            super.invalidateIntrinsicContentSize()
        }
    }

    /// The rows' total height at `width`; with `place`, the controls' frames too.
    private func arrange(width: CGFloat, place: Bool) -> CGFloat {
        let maxWidth = width > 0 ? width : .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for control in subviews {
            let size = control.intrinsicContentSize
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if place {
                control.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return y + rowHeight
    }
}

/// One `diag.*` value: its accessibility label and value are read from the
/// harness when asked, and its text when the harness refreshes.
private final class HarnessDiagnosticLabel: UILabel {
    private weak var owner: UIHangHarnessViewController?
    private let read: (UIHangHarnessViewController) -> Int

    init(owner: UIHangHarnessViewController, read: @escaping (UIHangHarnessViewController) -> Int) {
        self.owner = owner
        self.read = read
        super.init(frame: .zero)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var currentValue: String {
        owner.map { "\(read($0))" } ?? ""
    }

    func refreshText() {
        let value = currentValue
        if text != value { text = value }
    }

    override var accessibilityLabel: String? {
        get { currentValue }
        set {}
    }

    override var accessibilityValue: String? {
        get { currentValue }
        set {}
    }
}

// MARK: - Fixtures

private enum UIHangHarnessSession: String, CaseIterable {
    case alpha
    case beta
    case gamma

    var title: String { rawValue.capitalized }
    var accessibilityID: String { "harness.session.\(rawValue)" }
    var streamItemID: String { "harness-stream-\(rawValue)" }
    var extensionMarkdownToolID: String { "\(rawValue)-visual-tool-extension-b" }
    var extensionTextToolID: String { "\(rawValue)-visual-tool-extension-a" }
    var notebookToolID: String { "\(rawValue)-visual-tool-notebook" }
    var writeMarkdownToolID: String { "\(rawValue)-visual-tool-write" }
    var readMarkdownToolID: String { "\(rawValue)-visual-tool-read" }

    var visualToolIDs: [String] {
        [
            "\(rawValue)-visual-tool-bash",
            "\(rawValue)-visual-tool-read",
            "\(rawValue)-visual-tool-write",
            "\(rawValue)-visual-tool-edit",
            "\(rawValue)-visual-tool-extension-a",
            "\(rawValue)-visual-tool-extension-b",
            "\(rawValue)-visual-tool-notebook",
            "\(rawValue)-visual-tool-read-image",
            "\(rawValue)-visual-tool-unknown",
        ]
    }
}

/// The harness's rows and the tool content the reducer's stores hold for them.
@MainActor
private enum UIHangHarnessFixtures {
    static let items: [UIHangHarnessSession: [ChatItem]] = {
        var result: [UIHangHarnessSession: [ChatItem]] = [:]
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // UI tests need fast launch and quiescence. Default to smaller fixtures
        // in XCTest mode, unless explicitly running mixed-content scenarios.
        let turnsPerSession = UIHangHarnessConfig.uiTestMode ? 36 : 120
        let usePlainAssistantText = UIHangHarnessConfig.uiTestMode
            && !UIHangHarnessConfig.mixedContentFixtures

        for (sessionIndex, session) in UIHangHarnessSession.allCases.enumerated() {
            var items: [ChatItem] = []
            items.reserveCapacity(turnsPerSession * 2)

            for turn in 1...turnsPerSession {
                let offset = Double((sessionIndex * 10_000) + turn)
                let ts = baseDate.addingTimeInterval(offset)

                items.append(.userMessage(
                    id: "\(session.rawValue)-u-\(turn)",
                    text: "\(session.title) prompt \(turn): summarize and explain this response with examples.",
                    images: [],
                    timestamp: ts
                ))

                let assistantText: String
                if usePlainAssistantText {
                    assistantText = "\(session.title) answer \(turn) plain text payload for UI reliability harness."
                } else if UIHangHarnessConfig.mixedContentFixtures {
                    switch turn % 3 {
                    case 0:
                        assistantText = "\(session.title) answer \(turn) plain payload mixed-content lane."
                    case 1:
                        assistantText = """
                        ### \(session.title) answer \(turn)

                        Mixed markdown segment.

                        - turn: \(turn)
                        - value: \(turn * 17)

                        `inline-code-token-\(turn)`
                        """
                    default:
                        assistantText = """
                        ```swift
                        struct HarnessSample\(turn) {
                            let value = \(turn)
                        }
                        ```
                        """
                    }
                } else {
                    assistantText = """
                    ### \(session.title) answer \(turn)

                    Synthetic markdown content for timeline stress.

                    - turn: \(turn)
                    - value: \(turn * 17)

                    ```swift
                    let value = \(turn)
                    print(value)
                    ```
                    """
                }

                items.append(.assistantMessage(
                    id: "\(session.rawValue)-a-\(turn)",
                    text: assistantText,
                    timestamp: ts.addingTimeInterval(0.2)
                ))
            }

            if UIHangHarnessConfig.includeVisualFixtures {
                items += visualItems(
                    session: session,
                    timestamp: baseDate.addingTimeInterval(Double((sessionIndex * 10_000) + turnsPerSession + 500))
                )
            }

            if UIHangHarnessConfig.assistantOverlapFixture {
                items.append(.assistantMessage(
                    id: "\(session.rawValue)-assistant-overlap",
                    text: assistantOverlapText(phase: 0, session: session),
                    timestamp: baseDate.addingTimeInterval(Double((sessionIndex * 10_000) + turnsPerSession + 900))
                ))
            }

            result[session] = items
        }

        return result
    }()

    // swiftlint:disable:next function_body_length
    private static func visualItems(session: UIHangHarnessSession, timestamp visualTS: Date) -> [ChatItem] {
        let sessionPrefix = session.rawValue
        var items: [ChatItem] = []

        items.append(.userMessage(
            id: "\(sessionPrefix)-visual-user-image",
            text: "Image attachment example for visual routing check.",
            images: [
                ImageAttachment(
                    data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5YpU8AAAAASUVORK5CYII=",
                    mimeType: "image/png"
                ),
            ],
            timestamp: visualTS
        ))

        items.append(.assistantMessage(
            id: "\(sessionPrefix)-visual-assistant-markdown",
            text: """
            # Visual markdown sample

            First line sits beside the avatar; later lines and blocks reclaim the full bubble width so tables can breathe.

            - bullet one
            - bullet two with enough text to wrap under the avatar column on phone widths

            | Time | Evidence |
            | --- | --- |
            | 01:46:42 | JSONL start, cwd ~/.config/dotfiles, host session (not Gondolin) |
            | 01:48:21 | auth.refresh_succeeded |
            | 01:49:48 | iOS background again; last WS activity 01a0140d; keepalive timeout (27s) |

            | Col A | Col B | Col C | Col D | Col E |
            | --- | --- | --- | --- | --- |
            | alpha-value-long | beta-value-long | gamma-value-long | delta-value-long | epsilon-value-long |

            ```swift
            print(\"markdown + syntax highlight parity\")
            ```
            """,
            timestamp: visualTS.addingTimeInterval(0.1)
        ))

        items.append(.assistantMessage(
            id: "\(sessionPrefix)-visual-assistant-table",
            text: """
            | Time | Evidence |
            | --- | --- |
            | 01:46:42 | JSONL start, cwd ~/.config/dotfiles, host session (not Gondolin) |
            | 01:48:21 | auth.refresh_succeeded |
            | 01:49:48 | iOS background again; last WS activity 01a0140d; keepalive timeout (27s) |
            """,
            timestamp: visualTS.addingTimeInterval(0.15)
        ))

        items.append(.thinking(
            id: "\(sessionPrefix)-visual-thinking",
            preview: "Deliberating about renderer parity and fallback policy…",
            hasMore: true,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-bash",
            tool: "bash",
            argsSummary: "command: git status --short",
            outputPreview: "M ios/Oppi/Features/Chat/ChatTimelineCollectionView.swift",
            outputByteCount: 96,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-read",
            tool: "read",
            argsSummary: "path: ios/Oppi/Features/Chat/ChatTimelineCollectionView.swift",
            outputPreview: "import SwiftUI\\nimport UIKit",
            outputByteCount: 512,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-write",
            tool: "write",
            argsSummary: "path: docs/notes.md",
            outputPreview: "",
            outputByteCount: 128,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-edit",
            tool: "edit",
            argsSummary: "path: ios/Oppi/App/OppiApp.swift",
            outputPreview: "",
            outputByteCount: 256,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-extension-a",
            tool: "extensions.lookup",
            argsSummary: "query: renderer parity checklist",
            outputPreview: "- [ ] keep renderer parity checklist up to date",
            outputByteCount: 80,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-extension-b",
            tool: "extensions.notes",
            argsSummary: "query: harness markdown payload",
            outputPreview: "",
            outputByteCount: 2_400,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-notebook",
            tool: "script",
            argsSummary: "code: const notes = await tools.read()",
            outputPreview: "resolved",
            outputByteCount: 8,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-read-image",
            tool: "read",
            argsSummary: "path: fixtures/harness-image.png",
            outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5YpU8AAAAASUVORK5CYII=",
            outputByteCount: 144,
            isError: false,
            isDone: true
        ))

        items.append(.toolCall(
            id: "\(sessionPrefix)-visual-tool-unknown",
            tool: "grep",
            argsSummary: "pattern: TODO",
            outputPreview: "docs/notes.md:12: TODO: tighten regression harness",
            outputByteCount: 96,
            isError: false,
            isDone: true
        ))

        items.append(.systemEvent(
            id: "\(sessionPrefix)-visual-system",
            message: "Context compacted for visual pass"
        ))

        items.append(.error(
            id: "\(sessionPrefix)-visual-error",
            message: "Sample error row for native renderer visual verification"
        ))

        // Expandable compaction summary for expand/collapse UI testing.
        // Detail exceeds 140 chars so CompactionPresentation.canExpand is true.
        items.append(.systemEvent(
            id: "\(sessionPrefix)-visual-compaction-expandable",
            message: "Context compacted (8192 tokens): The conversation context was compacted to stay within the model context window. Previous discussion covered architecture patterns for the ChatTimelineCollectionView, performance optimization strategies for UIKit cell reuse, and debugging approaches for main thread stalls during rapid scrolling operations with expanded tool output rows."
        ))

        let customLog = (1...50).map { "build output line \($0)" }.joined(separator: "\n")
        items.append(.customEvent(
            id: "\(sessionPrefix)-visual-custom-log",
            message: "Background work finished\n\(customLog)",
            presentation: TraceEventPresentation(
                kind: "custom", title: "Background work finished",
                subtitle: nil, status: nil, body: customLog,
                fields: nil, accent: "info"
            )
        ))

        items.append(.audioClip(
            id: "\(sessionPrefix)-visual-audio",
            title: "Harness Audio Clip",
            fileURL: URL(fileURLWithPath: "/tmp/\(sessionPrefix)-harness-audio.wav"),
            timestamp: visualTS.addingTimeInterval(0.2)
        ))

        for fillerIndex in 0..<UIHangHarnessConfig.tailFillerRowCount {
            items.append(.assistantMessage(
                id: "\(sessionPrefix)-visual-tail-filler-\(fillerIndex)",
                text: "Tail filler \(fillerIndex + 1): content below the visual fixtures.",
                timestamp: visualTS.addingTimeInterval(1 + Double(fillerIndex) * 0.01)
            ))
        }

        return items
    }

    static func assistantOverlapText(phase: Int, session: UIHangHarnessSession) -> String {
        switch phase {
        case 0:
            return "Overlap repro fixture — \(session.title).\n\nShort intro before the rich markdown arrives."
        default:
            return """
            Overlap repro fixture — \(session.title).

            This paragraph stays short at first, then the renderer suddenly has to fit a wrapped table in one streaming assistant row.

            | Topic | Detail |
            | --- | --- |
            | Why | Long values must wrap inside the table instead of painting over the content below. |
            | Result | The following heading must remain below the complete table card after cell reuse. |

            ## Content after the wrapped table

            This heading and paragraph must remain visible below the table when a short streaming cell is recycled for this taller assistant item.
            """
        }
    }

    /// The output, arguments, and nested calls the visual tool rows show,
    /// for every session.
    static func seedToolContent(into reducer: TimelineReducer, includeWriteMarkdown: Bool) {
        seedExtensionMarkdown(into: reducer)
        seedExtensionText(into: reducer)
        seedNotebook(into: reducer)
        seedReadMarkdown(into: reducer)
        if includeWriteMarkdown {
            seedWriteMarkdown(into: reducer)
        }
    }

    private static func seedExtensionMarkdown(into reducer: TimelineReducer) {
        let extensionIDs = Set(UIHangHarnessSession.allCases.map(\.extensionMarkdownToolID))
        reducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in UIHangHarnessSession.allCases {
            let extensionID = session.extensionMarkdownToolID
            var sections: [String] = ["# Extension harness notes — \(session.title)"]
            for index in 1...22 {
                sections.append("## Segment \(index)")
                sections.append(
                    "- detail \(index).1\n- detail \(index).2\n- detail \(index).3\n- detail \(index).4"
                )
            }
            let markdown = sections.joined(separator: "\n\n")

            reducer.toolArgsStore.set([
                "text": .string(markdown),
                "tags": .array([
                    .string("harness"),
                    .string("extension-markdown"),
                    .string(session.rawValue),
                ]),
            ], for: extensionID)
            _ = reducer.toolOutputStore.append(markdown, to: extensionID)
        }
    }

    private static func seedExtensionText(into reducer: TimelineReducer) {
        let extensionIDs = Set(UIHangHarnessSession.allCases.map(\.extensionTextToolID))
        reducer.toolOutputStore.clear(itemIDs: extensionIDs)

        for session in UIHangHarnessSession.allCases {
            let bodySections = (1...28).map { index in
                "section \(index): detail \(index).1, detail \(index).2, detail \(index).3"
            }
            let output = ([
                "extension lookup result — \(session.title)",
                "status: in_progress",
            ] + bodySections).joined(separator: "\n")
            _ = reducer.toolOutputStore.append(output, to: session.extensionTextToolID)
        }
    }

    /// A code-role script with nested calls paints the notebook cell, the
    /// compact hosted surface whose taps must stay with the row.
    private static func seedNotebook(into reducer: TimelineReducer) {
        let notebookIDs = Set(UIHangHarnessSession.allCases.map(\.notebookToolID))
        reducer.toolOutputStore.clear(itemIDs: notebookIDs)

        for id in notebookIDs {
            reducer.toolArgsStore.set([
                "code": .string("""
                const notes = await tools.read({path: "CHANGELOG.md"});
                await tools.write({path: "CHANGELOG.md", content: notes});
                return "resolved";
                """),
            ], for: id)
            reducer.toolArgsStore.setInputPresentation(
                .init(fields: ["code": .init(role: "code", language: "javascript")]),
                for: id
            )
            reducer.toolDetailsStore.setNestedCalls(NestedToolCalls(calls: [
                .init(id: "1", name: "read", arguments: ["path": .string("CHANGELOG.md")], status: "ok", durationMs: 2),
                .init(id: "2", name: "write", arguments: ["path": .string("CHANGELOG.md")], status: "ok", durationMs: 1),
            ], complete: false), for: id)
            _ = reducer.toolOutputStore.append("resolved", to: id)
        }
    }

    private static func seedReadMarkdown(into reducer: TimelineReducer) {
        let readIDs = Set(UIHangHarnessSession.allCases.map(\.readMarkdownToolID))
        reducer.toolOutputStore.clear(itemIDs: readIDs)

        for session in UIHangHarnessSession.allCases {
            let readID = session.readMarkdownToolID
            reducer.toolArgsStore.set([
                "path": .string("design/read-harness-markdown.md"),
                "offset": .number(1),
                "limit": .number(800),
            ], for: readID)

            _ = reducer.toolOutputStore.append(readMarkdown(for: session), to: readID)
        }
    }

    private static func readMarkdown(for session: UIHangHarnessSession) -> String {
        var sections: [String] = [
            "# Session 01a0140d — network diagnosis",
            "Local times are PDT (UTC−7).",
            "## What 01a0140d itself did",
            """
            | Time | Evidence |
            | --- | --- |
            | 01:46:42 | JSONL start, cwd ~/.config/dotfiles, host session (not Gondolin) |
            | 01:48:21 | auth.refresh_succeeded |
            | 01:48:31 | iOS scene → inactive/background |
            | 01:49:48 | iOS background again; last WS activity 01a0140d; keepalive timeout (27s) |
            | 01:51:04 | user: “install the dev build… connect” |
            | 01:51:14 | agent_end / agent_settled mid install |
            | 01:51:21 | mirror_stopped |
            """,
            "This heading after the table must stay fully below the last row.",
            "# Read Harness Markdown — \(session.title)",
            "This fixture mirrors long markdown loaded via the read tool on a .md path.",
        ]

        for index in 1...36 {
            sections.append("## Read section \(index)")
            sections.append("- reducer path\n- markdown layout pass\n- viewport height\n- scroll ownership")
            sections.append(
                "Explanation \(index): verify expanded read markdown rows do not induce stagger, snapback, or offset oscillation under drag stress."
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private static func seedWriteMarkdown(into reducer: TimelineReducer) {
        var sections: [String] = [
            "# Chat Timeline Code Paths (Streaming + Normal Output)",
            "Status: current as of 2026-03-01.",
            "",
            "This fixture mirrors a long-form write payload that tends to trigger scroll staggering when expanded.",
        ]

        for index in 1...32 {
            sections.append("## Section \(index)")
            sections.append(
                "1. live streaming output\n2. finalized output\n3. reconnect catch-up\n4. fallback reload"
            )
            sections.append(
                "Detailed paragraph \(index): explain reducer, coalescer, and collection-view self-sizing interactions for markdown-heavy rows."
            )
        }
        let markdown = sections.joined(separator: "\n\n")

        for session in UIHangHarnessSession.allCases {
            let writeID = session.writeMarkdownToolID
            reducer.toolArgsStore.set([
                "path": .string("design/chat-timeline-code-paths.md"),
                "content": .string(markdown),
            ], for: writeID)

            reducer.toolOutputStore.clear(itemIDs: Set([writeID]))
        }
    }
}

// MARK: - Frame Interval Metrics

struct HarnessFrameIntervalSnapshot: Sendable {
    /// Continuity-window samples (`< 120ms`). p95/p99/percents use this set.
    let sampleCount: Int
    let p95IntervalMs: Int
    let p99IntervalMs: Int
    /// Raw maximum including AX/idle discontinuities (`>= 120ms`).
    let maxIntervalMs: Int
    /// Continuity-window maximum, excluding `>= 120ms` gaps.
    let filteredMaxIntervalMs: Int
    /// Raw count of `>= 50ms` frames, including discontinuities.
    let over50MsCount: Int
    /// Continuity-window count of `>= 50ms` frames.
    let filteredOver50MsCount: Int
    let over34MsPercent: Int
    let over50MsPercent: Int

    static let empty = Self(
        sampleCount: 0,
        p95IntervalMs: 0,
        p99IntervalMs: 0,
        maxIntervalMs: 0,
        filteredMaxIntervalMs: 0,
        over50MsCount: 0,
        filteredOver50MsCount: 0,
        over34MsPercent: 0,
        over50MsPercent: 0
    )
}

struct HarnessFrameIntervalRecorder: Sendable {
    /// Consecutive-frame cutoff: XCTest AX snapshots and idle gaps after reset
    /// produce 100ms+ CADisplayLink jumps that are not dropped frames.
    static let discontinuityMs = 120

    private let interval34Ms = 34
    private let interval50Ms = 50
    private let maxSamples = 1_200
    private var intervalsMs: [Int] = []

    mutating func reset() {
        intervalsMs.removeAll(keepingCapacity: false)
    }

    mutating func record(_ value: Int) {
        intervalsMs.append(max(0, value))
        if intervalsMs.count > maxSamples {
            intervalsMs.removeFirst()
        }
    }

    func snapshot() -> HarnessFrameIntervalSnapshot {
        guard !intervalsMs.isEmpty else { return .empty }

        let filtered = intervalsMs.filter { $0 < Self.discontinuityMs }
        let sortedFiltered = filtered.sorted()
        let sampleCount = sortedFiltered.count
        let filteredOver34 = filtered.reduce(into: 0) { partial, value in
            if value >= interval34Ms { partial &+= 1 }
        }
        let filteredOver50 = filtered.reduce(into: 0) { partial, value in
            if value >= interval50Ms { partial &+= 1 }
        }
        let rawOver50 = intervalsMs.reduce(into: 0) { partial, value in
            if value >= interval50Ms { partial &+= 1 }
        }

        return HarnessFrameIntervalSnapshot(
            sampleCount: sampleCount,
            p95IntervalMs: percentileValue(in: sortedFiltered, percentile: 0.95),
            p99IntervalMs: percentileValue(in: sortedFiltered, percentile: 0.99),
            maxIntervalMs: intervalsMs.max() ?? 0,
            filteredMaxIntervalMs: sortedFiltered.last ?? 0,
            over50MsCount: rawOver50,
            filteredOver50MsCount: filteredOver50,
            over34MsPercent: percent(part: filteredOver34, total: sampleCount),
            over50MsPercent: percent(part: filteredOver50, total: sampleCount)
        )
    }

    private func percentileValue(in sorted: [Int], percentile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(1.0, max(0.0, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.down))
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func percent(part: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(part) / Double(total) * 100).rounded())
    }
}

@MainActor
final class HarnessFrameIntervalMonitor: NSObject {
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var recorder = HarnessFrameIntervalRecorder()

    func start() {
        guard displayLink == nil else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        displayLink.preferredFramesPerSecond = 0
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    func reset() {
        previousTimestamp = nil
        recorder.reset()
    }

    func snapshot() -> HarnessFrameIntervalSnapshot {
        recorder.snapshot()
    }

    @objc
    private func handleDisplayLink(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return
        }

        let deltaMs = max(0, Int(((timestamp - previousTimestamp) * 1_000).rounded()))
        self.previousTimestamp = timestamp
        recorder.record(deltaMs)
    }
}
#endif

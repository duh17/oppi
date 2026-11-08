import Testing
import UIKit
@testable import Oppi

/// What a crowded Quick Session row gives up, and in what order: thinking
/// loses its title for its icon, then the model is cut short, and neither
/// shrinks to a single letter.
@Suite("Composer pop-up fit")
struct ComposerPopUpFitTests {
    private let model = ComposerPopUpFit.Item(full: 150, iconOnly: nil, minimum: 100)
    private let thinking = ComposerPopUpFit.Item(full: 130, iconOnly: 50, minimum: 100)

    // Items arrive in the order they give up room: thinking, then the model.
    private func resolve(available: CGFloat) -> [ComposerPopUpFit.Result] {
        ComposerPopUpFit.resolve([thinking, model], available: available, spacing: 8)
    }

    @Test("Nothing changes while both fit")
    func bothFit() {
        let results = resolve(available: 288)
        #expect(results.map(\.display) == [.full, .full])
        #expect(results.map(\.width) == [130, 150])
    }

    @Test("Thinking drops to its icon before the model is touched")
    func thinkingGoesFirst() {
        let results = resolve(available: 287)
        #expect(results[0] == .init(display: .iconOnly, width: 50))
        #expect(results[1] == .init(display: .full, width: 150))
    }

    @Test("The model is cut short only once thinking is an icon, to the room left")
    func modelGoesSecond() {
        let results = resolve(available: 180)
        #expect(results[0].display == .iconOnly)
        #expect(results[1].display == .truncated)
        // 180 - 50 (thinking) - 8 (gap)
        #expect(results[1].width == 122)
    }

    @Test("Neither control goes below its minimum, however narrow the row")
    func floors() {
        let results = resolve(available: 40)
        #expect(results[0] == .init(display: .iconOnly, width: 50))
        #expect(results[1] == .init(display: .truncated, width: 100))
    }
}

/// The destination bar's own truncation: the Classic reason and the Agent give
/// up room before the worktree, the worktree before the workspace, and none
/// shrinks to a single letter.
@Suite("Quick Session wide bar truncation")
@MainActor
struct QuickSessionWideBarTruncationTests {
    private func makeBar() -> (QuickSessionWideBar, UIView) {
        let bar = QuickSessionWideBar()
        func content(_ title: String, symbol: String, detail: String? = nil) -> QuickSessionPillButton.Content {
            QuickSessionPillButton.Content(
                icon: .symbol(symbol, color: .white, style: .body, weight: .semibold),
                title: title,
                titleColor: .white,
                detail: detail,
                trailingSymbol: "chevron.down"
            )
        }
        let colors = ComposerThemeColors.placeholder
        bar.workspace.apply(content("a-rather-long-workspace-name", symbol: "folder"), colors: colors)
        bar.worktree.apply(content("feature/a-rather-long-worktree-branch", symbol: "house"), colors: colors)
        bar.agent.apply(content("Reviewer with a long name", symbol: "person"), colors: colors)
        bar.engine.apply(content("Classic", symbol: "infinity", detail: "\u{00B7} Durable is unavailable here"), colors: colors)
        bar.incognito.apply(content("", symbol: "eye.slash"), colors: colors)
        bar.refreshGroups()

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2000, height: 60))
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return (bar, host)
    }

    private func widths(_ bar: QuickSessionWideBar, _ host: UIView, at width: CGFloat)
        -> (workspace: CGFloat, worktree: CGFloat, agent: CGFloat, engine: CGFloat)
    {
        host.frame.size.width = width
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return (bar.workspace.bounds.width, bar.worktree.bounds.width, bar.agent.bounds.width, bar.engine.bounds.width)
    }

    /// The bar's natural width: every control, the groups' padding, and the
    /// two gaps at their minimum.
    private func neededWidth(_ bar: QuickSessionWideBar, _ natural: (workspace: CGFloat, worktree: CGFloat, agent: CGFloat, engine: CGFloat))
        -> CGFloat
    {
        natural.workspace + natural.worktree + natural.agent + natural.engine + bar.incognito.bounds.width + 3 * 8 + 2 * 8
    }

    /// The label in `view` showing `text`.
    private func label(_ text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        return view.subviews.lazy.compactMap { label(text, in: $0) }.first
    }

    @Test("A small shortfall costs the Classic reason first, nothing else")
    func smallShortfallCostsTheEngineFirst() throws {
        let (bar, host) = makeBar()
        let natural = widths(bar, host, at: 2000)
        let tight = widths(bar, host, at: neededWidth(bar, natural) - 24)
        let detail = "natural \(natural), tight \(tight)"
        #expect(tight.engine < natural.engine - 10, "\(detail)")
        // The reason gave up the room; "Classic" itself is whole.
        let classic = try #require(label("Classic", in: bar.engine))
        #expect(classic.bounds.width >= classic.intrinsicContentSize.width - 0.5, "\(detail)")
        #expect(abs(tight.agent - natural.agent) < 1, "\(detail)")
        #expect(abs(tight.worktree - natural.worktree) < 1, "\(detail)")
        #expect(abs(tight.workspace - natural.workspace) < 1, "\(detail)")
    }

    @Test("Past the Classic reason, the Agent then the worktree give up room while the workspace keeps its width")
    func agentThenWorktreeBeforeWorkspace() {
        let (bar, host) = makeBar()
        let natural = widths(bar, host, at: 2000)
        let pressed = widths(bar, host, at: neededWidth(bar, natural) - 500)
        let detail = "natural \(natural), pressed \(pressed)"
        #expect(abs(pressed.workspace - natural.workspace) < 1, "\(detail)")
        #expect(pressed.worktree < natural.worktree - 10, "\(detail)")
        #expect(pressed.agent < natural.agent - 10, "\(detail)")
    }

    @Test("Under heavy pressure the workspace is cut last, and no title shrinks to a single letter")
    func workspaceLastAndFloors() {
        let (bar, host) = makeBar()
        let natural = widths(bar, host, at: 2000)
        let squeezed = widths(bar, host, at: 640)
        let detail = "natural \(natural), squeezed \(squeezed)"
        // The Agent and worktree sit on the same floor (a title's minimum beside its icon and indicator).
        #expect(abs(squeezed.worktree - squeezed.agent) < 1, "\(detail)")
        #expect(squeezed.agent >= QuickSessionWideBar.minimumTitleWidth + 40, "\(detail)")
        // Only now does the workspace give up room, and it keeps more than the floor.
        #expect(squeezed.workspace < natural.workspace - 10, "\(detail)")
        #expect(squeezed.workspace > squeezed.worktree, "\(detail)")
    }
}

/// Quick Session at regular width: the destination bar above the composer
/// replaces the compact pills, and the composer's row keeps model and thinking.
@Suite("Quick Session wide bar")
@MainActor
struct QuickSessionWideBarTests {
    private func makeController(regular: Bool, onDismiss: @escaping () -> Void = {}) async throws
        -> (QuickSessionViewController, UIWindow)
    {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let client = makeTestURLProtocolClient(host: "quick-session-wide.test")
        let root = try await makeTestAppRoot(readyServerId: "sha256:qs-wide-\(UUID().uuidString)", apiClient: client)
        let controller = QuickSessionViewController(root: root, onDismiss: onDismiss)
        // The simulator is an iPhone, so regular width is a trait override.
        if regular { controller.traitOverrides.horizontalSizeClass = .regular }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: regular ? 744 : 390, height: 1000)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    @Test("Regular width swaps the pills for the bar; compact keeps the pills")
    func barReplacesPillsWhenWide() async throws {
        let (wide, wideWindow) = try await makeController(regular: true)
        defer { wide.tearDown(); wideWindow.isHidden = true; wideWindow.rootViewController = nil }
        #expect(wide.usesWideLayout)
        #expect(!wide.wideBarContainer.isHidden)
        #expect(wide.destinationRowContainer.isHidden)
        #expect(!wide.wideBar.workspace.isHidden)
        #expect(!wide.wideBar.agent.isHidden)

        let (compact, compactWindow) = try await makeController(regular: false)
        defer { compact.tearDown(); compactWindow.isHidden = true; compactWindow.rootViewController = nil }
        #expect(!compact.usesWideLayout)
        #expect(compact.wideBarContainer.isHidden)
        #expect(!compact.destinationRowContainer.isHidden)
    }

    @Test("A bar control keeps its identifier and a VoiceOver label")
    func barControlsAreLabelled() async throws {
        let (controller, window) = try await makeController(regular: true)
        defer { controller.tearDown(); window.isHidden = true; window.rootViewController = nil }
        let bar = controller.wideBar
        #expect(bar.workspace.accessibilityIdentifier == "quickSession.workspacePicker")
        #expect(bar.worktree.accessibilityIdentifier == "quickSession.worktreePicker")
        #expect(bar.agent.accessibilityIdentifier == "quickSession.agentPicker")
        #expect(bar.engine.accessibilityIdentifier == "quickSession.durableEngine")
        #expect(bar.incognito.accessibilityIdentifier == "quickSession.incognito")
        for control in [bar.workspace, bar.agent, bar.incognito] {
            #expect(control.accessibilityLabel?.isEmpty == false)
        }
        #expect(bar.incognito.accessibilityTraits.contains(.toggleButton))
    }

    @Test("Esc closes an open picker first, then Quick Session")
    func escapeClosesPickerThenSession() async throws {
        var closed = 0
        let (controller, window) = try await makeController(regular: true) { closed += 1 }
        defer { controller.tearDown(); window.isHidden = true; window.rootViewController = nil }
        let escape = try #require(controller.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })

        controller.model.showWorkspacePicker = true
        controller.perform(escape.action)
        #expect(!controller.model.showWorkspacePicker)
        #expect(closed == 0)

        controller.perform(escape.action)
        #expect(closed == 1)
    }

    @Test("Esc steps aside while an input method is composing in the composer")
    func escapeLeavesMarkedTextToTheInputMethod() async throws {
        let (controller, window) = try await makeController(regular: true)
        defer { controller.tearDown(); window.isHidden = true; window.rootViewController = nil }
        let escape = try #require(controller.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        let action = try #require(escape.action)
        #expect(controller.canPerformAction(action, withSender: escape))

        let textView = controller.composer.bar.textView
        textView.markedTextRangeOverrideForTesting = textView.textRange(
            from: textView.beginningOfDocument,
            to: textView.beginningOfDocument
        )
        #expect(!controller.canPerformAction(action, withSender: escape))

        textView.markedTextRangeOverrideForTesting = nil
        #expect(controller.canPerformAction(action, withSender: escape))
    }
}

import AppKit
import SwiftUI

/// OppiMac overlay scrollers. The app-domain `AppleShowScrollBars` value
/// `WhenScrolling` overrides System Settings “Show scroll bars: Always”, which
/// would otherwise keep a persistent gutter. Overlay knobs hide when idle and
/// use an 8pt scroller class instead of the default ~16pt overlay knob.
@MainActor
enum MacScrollChrome {
    static let overlayThickness: CGFloat = 8
    nonisolated static let showScrollBarsDefaultsKey = "AppleShowScrollBars"
    nonisolated static let showScrollBarsWhenScrolling = "WhenScrolling"

    static var systemOverlayThickness: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    }

    static func install() {
        preferOverlayScrollers()
        MacScrollChromeController.shared.start()
    }

    /// Highest-priority app override so System Settings Always cannot keep
    /// OppiMac gutters visible. Argument-domain beats the global Always value.
    nonisolated static func preferOverlayScrollers() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: showScrollBarsDefaultsKey) != showScrollBarsWhenScrolling {
            defaults.set(showScrollBarsWhenScrolling, forKey: showScrollBarsDefaultsKey)
        }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments[showScrollBarsDefaultsKey] as? String != showScrollBarsWhenScrolling {
            arguments[showScrollBarsDefaultsKey] = showScrollBarsWhenScrolling
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }

    static func apply(to window: NSWindow) {
        apply(in: window.contentView)
    }

    static func apply(in root: NSView?) {
        guard let root else { return }
        for scrollView in scrollViews(in: root) {
            applyIfNeeded(to: scrollView)
        }
    }

    static func apply(to scrollView: NSScrollView) {
        if hasInstalledChrome(scrollView) {
            return
        }
        preferOverlayScrollers()
        if scrollView.hasVerticalScroller {
            installOverlayScroller(on: scrollView, vertical: true)
        }
        if scrollView.hasHorizontalScroller {
            installOverlayScroller(on: scrollView, vertical: false)
        }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.scrollerStyle = .overlay
        scrollView.horizontalScroller?.scrollerStyle = .overlay
    }

    /// True when this scroll view already has overlay autohide and 8pt knobs.
    static func hasInstalledChrome(_ scrollView: NSScrollView) -> Bool {
        guard scrollView.scrollerStyle == .overlay, scrollView.autohidesScrollers else {
            return false
        }
        var hasScroller = false
        if scrollView.hasVerticalScroller {
            hasScroller = true
            guard let vertical = scrollView.verticalScroller as? MacOverlayScroller,
                  vertical.scrollerStyle == .overlay else {
                return false
            }
        }
        if scrollView.hasHorizontalScroller {
            hasScroller = true
            guard let horizontal = scrollView.horizontalScroller as? MacOverlayScroller,
                  horizontal.scrollerStyle == .overlay else {
                return false
            }
        }
        return hasScroller
    }

    static func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView {
                found.append(scrollView)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Auto path for scene roots and window attachments. Cheap no-op when
    /// overlay autohide and 8pt knobs are already installed.
    private static func applyIfNeeded(to scrollView: NSScrollView) {
        if hasInstalledChrome(scrollView) { return }
        apply(to: scrollView)
    }

    private static func installOverlayScroller(on scrollView: NSScrollView, vertical: Bool) {
        let existing = vertical ? scrollView.verticalScroller : scrollView.horizontalScroller
        let scroller: MacOverlayScroller
        if let existing = existing as? MacOverlayScroller {
            scroller = existing
        } else {
            scroller = MacOverlayScroller(frame: existing?.frame ?? .zero)
            if vertical {
                scrollView.verticalScroller = scroller
            } else {
                scrollView.horizontalScroller = scroller
            }
        }
        scroller.scrollerStyle = .overlay
        scroller.knobStyle = scrollView.scrollerKnobStyle
    }

    /// Scene-root probe. Layout restyles this window; `install()` also watches
    /// every Oppi window so sheets, popovers, and the menu-bar extra pick up
    /// NSScrollView descendants that appear after the window is already key.
    struct WindowInstaller: NSViewRepresentable {
        func makeNSView(context: Context) -> InstallView {
            InstallView()
        }

        func updateNSView(_ nsView: InstallView, context: Context) {
            nsView.installIfNeeded()
        }
    }

    final class InstallView: NSView {
        private var isInstalling = false
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize { .zero }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stopObserving()
                return
            }
            MacScrollChrome.install()
            startObservingIfNeeded()
            installIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if window != nil {
                installIfNeeded()
            }
        }

        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            installIfNeeded()
        }

        override func layout() {
            super.layout()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard !isInstalling, window != nil else { return }
            isInstalling = true
            defer { isInstalling = false }
            MacScrollChrome.install()
        }

        private func startObservingIfNeeded() {
            guard observers.isEmpty else { return }
            let names: [Notification.Name] = [
                NSScroller.preferredScrollerStyleDidChangeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.willBeginSheetNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: name == NSScroller.preferredScrollerStyleDidChangeNotification
                            ? nil
                            : window,
                        queue: .main
                    ) { [weak self] _ in
                        // Main-queue delivery: run now. Task { @MainActor } cannot
                        // start while a @MainActor test holds the actor.
                        MainActor.assumeIsolated {
                            self?.installIfNeeded()
                        }
                    }
                )
            }
        }

        private func stopObserving() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }
    }
}

/// Native overlay knob, half the usual overlay width. No custom painted track.
final class MacOverlayScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        MacScrollChrome.overlayThickness
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Overlay chrome has no persistent track.
    }

    override func drawKnob() {
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.setAlpha(0.55)
        super.drawKnob()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func configure() {
        scrollerStyle = .overlay
    }
}

/// Watches every Oppi window, including sheets, popovers, and the menu-bar
/// extra. New windows are attached on app update; each attachment restyles
/// NSScrollView descendants when that window updates after becoming key.
@MainActor
private final class MacScrollChromeController {
    static let shared = MacScrollChromeController()

    private var started = false
    private var isApplying = false
    private var isScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var windowAttachments: [ObjectIdentifier: WindowAttachment] = [:]

    func start() {
        if !started {
            started = true
            observeWindowLifecycle()
        }
        attachVisibleWindows()
        applyAll()
    }

    private func observeWindowLifecycle() {
        let names: [Notification.Name] = [
            NSApplication.didUpdateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification,
            NSWindow.willBeginSheetNotification,
            NSScroller.preferredScrollerStyleDidChangeNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Main-queue delivery: run now. Task { @MainActor } cannot
                    // start while a @MainActor test holds the actor.
                    MainActor.assumeIsolated {
                        self?.handle(name)
                    }
                }
            )
        }
    }

    func attachVisibleWindows() {
        for window in NSApp.windows {
            attach(window)
        }
    }

    func attach(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if windowAttachments[id] == nil {
            windowAttachments[id] = WindowAttachment(window: window) { [weak self] in
                self?.windowAttachments[id] = nil
            }
        }
        installProbe(in: window)
    }

    /// Puts an `InstallView` in the window so layout after a late List/ScrollView
    /// restyles descendants. Re-adds if SwiftUI rebuilt the hosting tree.
    private func installProbe(in window: NSWindow) {
        guard let content = window.contentView else { return }
        // Sit on the frame, not the hosting view, so SwiftUI rebuilds keep the probe.
        let host = content.superview ?? content
        if host.subviews.contains(where: { $0 is MacScrollChrome.InstallView }) {
            return
        }
        let probe = MacScrollChrome.InstallView()
        probe.autoresizingMask = [.width, .height]
        probe.frame = .zero
        host.addSubview(probe)
        probe.needsLayout = true
    }

    private func handle(_ name: Notification.Name) {
        if name == NSScroller.preferredScrollerStyleDidChangeNotification {
            attachVisibleWindows()
            applyAll()
            return
        }
        attachVisibleWindows()
        if name == NSApplication.didUpdateNotification {
            scheduleApplyAll()
            return
        }
        applyAll()
    }

    private func scheduleApplyAll() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isScheduled = false
            self?.applyAll()
        }
    }

    private func applyAll() {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        var seen = Set<ObjectIdentifier>()
        var windows = NSApp.windows
        windows.append(contentsOf: windows.flatMap { $0.childWindows ?? [] })
        windows.append(contentsOf: windows.compactMap(\.attachedSheet))
        for window in windows {
            let id = ObjectIdentifier(window)
            if !seen.insert(id).inserted { continue }
            attach(window)
            MacScrollChrome.apply(to: window)
        }
    }
}

@MainActor
private final class WindowAttachment {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var isApplying = false
    private var isScheduled = false
    private var onClose: (() -> Void)?

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.window = window
        self.onClose = onClose
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleApply()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleClose()
                }
            }
        )
        applyNow()
    }

    private func handleClose() {
        let close = onClose
        onClose = nil
        tearDown()
        close?()
    }

    private func scheduleApply() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isScheduled = false
            self?.applyNow()
        }
    }

    private func applyNow() {
        guard !isApplying, let window else { return }
        isApplying = true
        defer { isApplying = false }
        MacScrollChrome.apply(to: window)
        for child in window.childWindows ?? [] {
            MacScrollChromeController.shared.attach(child)
            MacScrollChrome.apply(to: child)
        }
        if let sheet = window.attachedSheet {
            MacScrollChromeController.shared.attach(sheet)
            MacScrollChrome.apply(to: sheet)
        }
    }

    private func tearDown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        window = nil
    }
}

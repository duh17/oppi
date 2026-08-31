import AppKit
import SwiftUI
import Testing
@testable import Oppi

@MainActor
@Suite("Mac overlay scroll chrome")
struct MacScrollChromeTests {
    @Test func overlayKnobIsAboutHalfTheSystemOverlayWidth() {
        let overlay = MacOverlayScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let system = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)

        #expect(overlay == MacScrollChrome.overlayThickness)
        #expect(overlay == 8)
        #expect(system >= 15)
        #expect(overlay * 2 <= system + 1)
        #expect(MacScrollChrome.systemOverlayThickness == system)
    }

    @Test func applyForcesOverlayAutohideAndThinKnobsOverAlwaysVisibleBars() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 960))
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false

        MacScrollChrome.apply(to: scrollView)

        try assertOverlayChrome(scrollView)
    }

    @Test func windowInstallerAppliesChromeToSwiftUIListAndScrollView() throws {
        let root = VStack(spacing: 0) {
            List {
                Text("Inbox row")
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(0..<40, id: \.self) { index in
                        Text("Line \(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background { MacScrollChrome.WindowInstaller() }
        .frame(width: 320, height: 280)

        let (host, window) = makeOffscreenHost(root, width: 320, height: 280)
        defer { tearDown(window) }

        let scrollViews = waitForChromedScrollViews(in: host, minimumCount: 2)
        #expect(scrollViews.count >= 2, "SwiftUI List and ScrollView should each host an NSScrollView")
        for scrollView in scrollViews {
            try assertOverlayChrome(scrollView)
        }
    }

    @Test func lifecycleAppliesChromeToLateSheetList() throws {
        let parentRoot = Color.clear
            .frame(width: 240, height: 180)
            .background { MacScrollChrome.WindowInstaller() }
        let (_, parent) = makeOffscreenHost(parentRoot, width: 240, height: 180)
        parent.makeKeyAndOrderFront(nil)
        defer { tearDown(parent) }
        // Startup analog: production calls install() once, then watches windows.
        MacScrollChrome.install()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // Sheet/popover analog: a child window becomes key with empty content,
        // then a List materializes. No WindowInstaller on the child content.
        let emptyHost = NSHostingView(
            rootView: AnyView(Color.clear.frame(width: 320, height: 280))
        )
        emptyHost.frame = NSRect(x: 0, y: 0, width: 320, height: 280)
        let sheet = NSWindow(
            contentRect: emptyHost.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        sheet.isReleasedWhenClosed = false
        sheet.contentView = emptyHost
        sheet.setFrameOrigin(NSPoint(x: -10_000, y: -9_000))
        parent.addChildWindow(sheet, ordered: .above)
        sheet.makeKeyAndOrderFront(nil)
        defer {
            parent.removeChildWindow(sheet)
            tearDown(sheet)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(emptyHost.window === sheet)
        #expect(NSApp.windows.contains(sheet))

        emptyHost.rootView = AnyView(
            List {
                Text("Sheet row")
            }
            .frame(width: 320, height: 280)
        )

        let scrollViews = waitForChromedScrollViews(in: emptyHost, minimumCount: 1)
        #expect(emptyHost.window === sheet)
        #expect(!scrollViews.isEmpty, "A List materialized after the sheet is key should host an NSScrollView")
        for scrollView in scrollViews {
            try assertOverlayChrome(scrollView)
        }
    }

    private func assertOverlayChrome(_ scrollView: NSScrollView) throws {
        #expect(scrollView.autohidesScrollers)
        #expect(
            UserDefaults.standard.string(forKey: MacScrollChrome.showScrollBarsDefaultsKey)
                == MacScrollChrome.showScrollBarsWhenScrolling
        )
        if scrollView.hasVerticalScroller {
            let vertical = try #require(scrollView.verticalScroller)
            #expect(vertical is MacOverlayScroller)
            #expect(vertical.scrollerStyle == .overlay)
            #expect(
                type(of: vertical).scrollerWidth(for: vertical.controlSize, scrollerStyle: .overlay)
                    == MacScrollChrome.overlayThickness
            )
        }
        if scrollView.hasHorizontalScroller {
            let horizontal = try #require(scrollView.horizontalScroller)
            #expect(horizontal is MacOverlayScroller)
            #expect(horizontal.scrollerStyle == .overlay)
            #expect(
                type(of: horizontal).scrollerWidth(for: horizontal.controlSize, scrollerStyle: .overlay)
                    == MacScrollChrome.overlayThickness
            )
        }
    }

    @Test func appWindowInstallsScrollChrome() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let macRoot = testsDir.deletingLastPathComponent().appending(path: "OppiMac")
        let appSource = try String(
            contentsOf: macRoot.appending(path: "App/OppiMacApp.swift"),
            encoding: .utf8
        )
        #expect(appSource.contains("MacScrollChrome.preferOverlayScrollers()"))
        #expect(appSource.contains("MacScrollChrome.install()"))
        let installerMarks = appSource.components(separatedBy: "MacScrollChrome.WindowInstaller()").count - 1
        #expect(installerMarks >= 2, "Main window and MenuBarExtra scene roots should attach WindowInstaller")
    }

    private func makeOffscreenHost<Content: View>(
        _ root: Content,
        width: CGFloat,
        height: CGFloat
    ) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        return (host, window)
    }

    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Waits for overlay chrome by pumping layout, display, and the run loop.
    /// Does not call `install()` or `apply(to:)` — startup and WindowInstaller
    /// must restyle on their own, matching production.
    private func waitForChromedScrollViews(
        in root: NSView,
        minimumCount: Int,
        timeout: TimeInterval = 1.5
    ) -> [NSScrollView] {
        let deadline = Date().addingTimeInterval(timeout)
        var scrollViews: [NSScrollView] = []
        repeat {
            // AppKit's event-loop update pass posts window/app didUpdate.
            // RunLoop.current.run does not.
            NSApp.updateWindows()
            root.layoutSubtreeIfNeeded()
            root.window?.contentView?.layoutSubtreeIfNeeded()
            root.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            root.window?.displayIfNeeded()
            scrollViews = MacScrollChrome.scrollViews(in: root)
            let chromed = scrollViews.filter { MacScrollChrome.hasInstalledChrome($0) }
            if chromed.count >= minimumCount {
                return chromed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return scrollViews
    }
}

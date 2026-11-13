import Testing
import UIKit
@testable import Oppi

/// Outside the chat timeline, working is static: a session row says "Working" in blue where other states put
/// their word, and small icon slots draw the app's one working icon (`WorkingMarkView`) in the accent blue.
/// Nothing outside the timeline draws an orb or another animated spinner.
@MainActor
@Suite("Working indicator surfaces")
struct WorkingIndicatorSurfacesTests {
    private func session(_ kind: SessionStatusKind) -> Session {
        var session = Session(
            id: "row-\(kind)",
            workspaceId: "ws",
            name: "Build the thing",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        let since = Date(timeIntervalSince1970: 2_000)
        switch kind {
        case .working:
            session.status = .busy
            session.currentTurnStartedAt = since
            session.programStatus = ProgramStatus(state: .working, since: since)
        case .error: session.programStatus = ProgramStatus(state: .error, since: since)
        default: session.programStatus = ProgramStatus(state: .idle, since: since)
        }
        return session
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    private func shown(_ view: UIView, in root: UIView) -> Bool {
        var node: UIView? = view
        while let current = node, current !== root {
            if current.isHidden { return false }
            node = current.superview
        }
        return true
    }

    private func apply(_ kind: SessionStatusKind, to row: SessionRowView) {
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session(kind))),
            display: .standard, themeID: .dark, iconAssetCache: nil
        )
        row.layoutIfNeeded()
    }

    /// The animated views that belong only to the chat timeline.
    private func animatedViews(in root: UIView) -> [UIView] {
        descendants(of: root, WorkingSpinnerUIView.self) as [UIView]
            + descendants(of: root, OrbMetalView.self) + descendants(of: root, BrailleSpinnerUIView.self)
            + descendants(of: root, GameOfLifeUIView.self)
    }

    /// One reused row going working → idle → working: the status word reads "Working" in the working blue only
    /// while it works, the row's combined VoiceOver facts include it only then, and the row never holds a
    /// working icon or an animated spinner.
    @Test func aSessionRowSaysWorkingInBlueOnlyWhileWorking() {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        window.addSubview(row)
        let style = SessionRowStyle.for(.dark)
        func shownLabel(_ text: String) -> UILabel? {
            descendants(of: row, UILabel.self).first { shown($0, in: row) && $0.text == text }
        }

        for (kind, working) in [(SessionStatusKind.working, true), (.idle, false), (.working, true)] {
            apply(kind, to: row)
            let word = shownLabel("Working")
            #expect((word != nil) == working, "\(kind): the word Working")
            #expect(word.map { $0.textColor == style.tint(.working) } ?? true, "\(kind): Working is blue")
            #expect((shownLabel("Idle") != nil) == !working, "\(kind): the idle word")
            // The combined row speaks its shown facts; the status word is one of them.
            let spoken = (row.automationElements ?? []).compactMap { ($0 as? UILabel)?.text }
            #expect(spoken.contains("Working") == working, "\(kind): \(spoken)")
        }
        #expect(descendants(of: row, WorkingMarkView.self).isEmpty, "A session row draws no working icon")
        #expect(animatedViews(in: row).isEmpty, "A session row draws no animated spinner")
    }

    /// The thread strip draws one working icon for its working members, "×N" only when more than one works,
    /// and keeps its dots for the members that need the person or are in error.
    @Test func theThreadStripDrawsOneMarkForItsWorkingMembers() throws {
        let style = SessionRowStyle.for(.dark)
        let view = SessionThreadStatusMarksView()
        let mark = try #require(descendants(of: view, WorkingMarkView.self).first)
        func dots() -> [CALayer] { (view.layer.sublayers ?? []).filter { $0.delegate == nil && !$0.isHidden } }
        func count() -> String? {
            descendants(of: view, UILabel.self).first { !$0.isHidden && $0.text?.hasPrefix("×") == true }?.text
        }

        view.apply([.needsYou, .error], hiddenCount: 0, working: 3, style: style)
        #expect(dots().map { $0.backgroundColor.map(UIColor.init(cgColor:)) } == [style.tint(.needsApproval), style.tint(.error)])
        #expect(!mark.isHidden && mark.image != nil)
        #expect(count() == "×3")

        view.apply([], hiddenCount: 0, working: 1, style: style)
        #expect(dots().isEmpty)
        #expect(!mark.isHidden)
        #expect(count() == nil, "One working member draws the mark alone")

        view.apply([.needsYou], hiddenCount: 0, working: 0, style: style)
        #expect(dots().count == 1)
        #expect(mark.isHidden, "No working member, no mark")
        #expect(count() == nil)
        #expect(animatedViews(in: view).isEmpty, "A Thread strip draws no animated spinner")
    }

    /// The strip's status line keeps one height whether or not it draws the mark, so the list below never
    /// jumps as members start and stop working.
    @Test func theStatusLineKeepsItsHeightWithAndWithoutTheMark() {
        let style = SessionRowStyle.for(.dark)
        let view = SessionThreadStatusMarksView()
        view.apply([.error], hiddenCount: 0, working: 0, style: style)
        let still = view.intrinsicContentSize
        view.apply([.error], hiddenCount: 4, working: 5, style: style)
        let working = view.intrinsicContentSize

        #expect(still.height == working.height)
        #expect(working.width > still.width)
    }

    /// The icon is its text line's height and grows with a live text-size change, so it keeps its place
    /// beside the words at the largest sizes.
    @Test func theMarkFollowsALiveTextSizeChange() {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }
        window.traitOverrides.preferredContentSizeCategory = .large
        let mark = WorkingMarkView(textStyle: .caption1)
        window.addSubview(mark)
        window.layoutIfNeeded()
        let regular = mark.intrinsicContentSize

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.layoutIfNeeded()
        let largest = mark.intrinsicContentSize

        #expect(regular.width == regular.height)
        #expect(largest.height > regular.height * 2, "\(regular) → \(largest)")
    }

    /// Whatever spinner style Settings chose for the chat, the icon is the one static symbol in the theme's
    /// accent blue, and it is spoken as "Working".
    @Test func theIconIsOneStaticSymbolInAccentBlueWhateverTheSpinnerStyle() throws {
        let saved = AppPreferenceStore.Appearance.spinnerStyle
        defer { AppPreferenceStore.Appearance.setSpinnerStyle(saved) }
        let symbol = try #require(UIImage(systemName: WorkingMarkView.symbolName)?.pngData())
        for style in SpinnerStyle.allCases {
            AppPreferenceStore.Appearance.setSpinnerStyle(style)
            for theme in [ThemeID.dark, .light] {
                let mark = WorkingMarkView(textStyle: .caption1)
                mark.apply(palette: theme.palette)
                #expect(mark.image?.pngData() == symbol, "\(style)")
                #expect(mark.tintColor == theme.palette.ui.blue, "\(style), \(theme)")
                #expect(mark.accessibilityLabel == "Working")
                #expect(animatedViews(in: mark).isEmpty)
            }
        }
    }
}

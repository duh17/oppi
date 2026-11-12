import Testing
import UIKit
@testable import Oppi

/// A working agent draws the still working mark wherever a session's status shows outside the focused chat,
/// and only while it works: a session row puts it where other states put their word, and VoiceOver hears
/// "Working".
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

    /// The animated views a still mark must never bring onto a list.
    private func animatedViews(in root: UIView) -> [UIView] {
        descendants(of: root, WorkingSpinnerUIView.self) as [UIView]
            + descendants(of: root, OrbMetalView.self) + descendants(of: root, BrailleSpinnerUIView.self)
            + descendants(of: root, GameOfLifeUIView.self)
    }

    /// One reused row going working → idle → working: the still mark and the word trade places each time,
    /// the row's combined VoiceOver label says Working only while the mark shows, and the row never holds an
    /// animated spinner.
    @Test func aSessionRowShowsTheStillMarkInPlaceOfTheWordOnlyWhileWorking() throws {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        window.addSubview(row)
        let mark = try #require(descendants(of: row, WorkingMarkView.self).first)
        func shownWords() -> [String] {
            descendants(of: row, UILabel.self).filter { shown($0, in: row) }.compactMap(\.text)
        }

        for (kind, working) in [(SessionStatusKind.working, true), (.idle, false), (.working, true)] {
            apply(kind, to: row)
            #expect(shown(mark, in: row) == working, "\(kind): mark shown")
            #expect(!working || mark.image != nil, "\(kind): the mark draws its frame")
            #expect(shownWords().contains("Working") == false, "\(kind): the word Working is never drawn")
            #expect(shownWords().contains("Idle") == !working, "\(kind): the idle word")
            let label = row.accessibilityLabel ?? ""
            #expect(label.contains("Working") == working, Comment(rawValue: label))
        }
        #expect(animatedViews(in: row).isEmpty, "A session row draws no animated spinner")
    }

    /// The thread strip draws one still mark for its working members, "×N" only when more than one works,
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

    /// The mark is its text line's height and grows with a live text-size change, redrawing its frame at the
    /// new size, so it keeps its place beside the words at the largest sizes.
    @Test func theMarkFollowsALiveTextSizeChange() throws {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }
        window.traitOverrides.preferredContentSizeCategory = .large
        let mark = WorkingMarkView(textStyle: .caption1)
        window.addSubview(mark)
        mark.apply(tint: .systemBlue, palette: ThemeID.dark.palette)
        window.layoutIfNeeded()
        let regular = mark.intrinsicContentSize
        let regularImage = try #require(mark.image)

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.layoutIfNeeded()
        let largest = mark.intrinsicContentSize
        let largestImage = try #require(mark.image)

        #expect(regular.width == regular.height)
        #expect(largest.height > regular.height * 2, "\(regular) → \(largest)")
        #expect(regularImage.size == regular)
        #expect(largestImage.size == largest, "The frame is drawn again at the new size")
    }

    /// Each Settings style draws its own still frame, so the mark changes with the chosen style; the same
    /// style, colors, and size draw one shared image.
    @Test func eachStyleDrawsItsOwnStillFrame() {
        let palette = ThemeID.dark.palette
        func key(_ style: SpinnerStyle) -> WorkingMarkImage.Key {
            WorkingMarkImage.Key(
                style: style, tint: palette.blue, accents: [palette.blue, palette.cyan, palette.purple, palette.orange],
                isDark: true, side: 16
            )
        }
        let images = SpinnerStyle.allCases.map { WorkingMarkImage.image(for: key($0)).pngData() }

        #expect(Set(images).count == SpinnerStyle.allCases.count, "Two styles drew the same frame")
        #expect(WorkingMarkImage.image(for: key(.working)) === WorkingMarkImage.image(for: key(.working)))
    }
}

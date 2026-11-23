import Foundation
import Testing
import UIKit
@testable import Oppi

/// The session row's identity icon: the session's icon on a circle whose size
/// the person picks (Settings › Session Rows › Icon Size), with the text
/// column, a thread's child indents, and the row's height following it.
@MainActor
@Suite("Session row identity icon")
struct SessionRowIdentitySizeTests {
    private func session() -> Session {
        var session = Session(
            id: "identity-size",
            workspaceId: "ws",
            workspaceName: "shop-app",
            name: "Refactor checkout flow",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            model: "anthropic/claude-opus-5-5",
            messageCount: 12,
            tokens: TokenUsage(input: 8_000, output: 1_200),
            cost: 1.4
        )
        session.programStatus = ProgramStatus(state: .idle, since: Date(timeIntervalSince1970: 1_000))
        return session
    }

    private func makeWindow(wide: Bool) -> UIWindow {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 300))
        window.traitOverrides.horizontalSizeClass = wide ? .regular : .compact
        window.isHidden = false
        return window
    }

    /// A row laid out at the height it asks for: a taller frame stretches the
    /// text column, which moves the title away from the circle. `identity` is one
    /// size of the test's own: it goes on after `apply`, which is a row taking the
    /// size Settings holds now.
    private func makeRow(in window: UIWindow, identity: SessionRowIdentity? = nil) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 60)
        window.addSubview(row)
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session())),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        if let identity { row.applyIdentity(identity) }
        row.frame.size.height = height(of: row)
        window.layoutIfNeeded()
        return row
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    /// The identity circle as the row draws it.
    private func drawnIcon(of row: SessionRowView) -> (side: CGFloat, shape: IconShape)? {
        guard let badge = descendants(of: row, SessionGridBadgeView.self).first,
              let icon = badge.subviews.compactMap({ $0 as? IconChoiceUIView }).first else { return nil }
        return (badge.bounds.width, icon.shape)
    }

    private func label(_ text: String, in row: SessionRowView) -> UILabel? {
        descendants(of: row, UILabel.self).first { $0.text == text }
    }

    /// Where the row's text starts, past the circle.
    private func textStart(of row: SessionRowView) -> CGFloat? {
        label("Refactor checkout flow", in: row).map { $0.convert($0.bounds, to: row).minX }
    }

    private func height(of row: SessionRowView) -> CGFloat {
        row.systemLayoutSizeFitting(
            CGSize(width: 430, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// The three sizes, and what each does to the column and the text past it.
    /// These are the tested sizes: a row is laid out for one of them, never for a
    /// width a slider landed on.
    @Test func theThreeSizesAreTheTable() {
        let table: [(SessionIconSize, side: CGFloat, column: CGFloat, textInset: CGFloat)] = [
            (.small, 32, 36, 44),
            (.medium, 44, 48, 56),
            (.large, 56, 60, 68),
        ]
        for (size, side, column, textInset) in table {
            let identity = SessionRowIdentity(size: size)
            #expect(identity.side == side, "\(size) circle")
            #expect(identity.columnWidth == column, "\(size) column")
            #expect(identity.textInset == textInset, "\(size) text start")
        }
    }

    /// A thread's children take one title column per level, and the widest size
    /// never pushes a row in past the deepest indent a small icon draws: a large
    /// icon may not leave less room for the words than today's deepest thread.
    @Test func threadIndentsFollowTheSizeAndStopAtTheDeepest() {
        let small = SessionRowIdentity(size: .small)
        #expect(small.indent(forDepth: 0) == 0)
        #expect(small.indent(forDepth: 1) == 44)
        #expect(small.indent(forDepth: 4) == 176)
        #expect(small.indent(forDepth: 9) == 176)

        let medium = SessionRowIdentity(size: .medium)
        #expect(medium.indent(forDepth: 1) == 56)
        #expect(medium.indent(forDepth: 2) == 112)
        #expect(medium.indent(forDepth: 3) == 168)

        let large = SessionRowIdentity(size: .large)
        #expect(large.indent(forDepth: 1) == 68)
        #expect(large.indent(forDepth: 2) == 136)
        #expect(large.indent(forDepth: 3) == SessionRowIdentity.deepestIndent)
        #expect(large.indent(forDepth: 4) == SessionRowIdentity.deepestIndent)
        #expect(SessionRowIdentity.deepestIndent == 176)
    }

    @Test func everyRowDrawsTheCirclePastTheSameTextBox() {
        let phone = makeWindow(wide: false)
        let pad = makeWindow(wide: true)
        defer {
            hideTestWindow(phone)
            hideTestWindow(pad)
        }
        let phoneRow = makeRow(in: phone)
        let padRow = makeRow(in: pad)
        let identity = SessionRowIdentity.current

        #expect(drawnIcon(of: phoneRow)?.side == identity.side)
        #expect(drawnIcon(of: phoneRow)?.shape == .circle)
        #expect(textStart(of: phoneRow) == identity.textInset)
        #expect(drawnIcon(of: padRow)?.side == identity.side)
        #expect(drawnIcon(of: padRow)?.shape == .circle)
        #expect(textStart(of: padRow) == identity.textInset)
    }

    @Test func theCircleSitsOnTheTitleLineAndFitsTheRow() throws {
        let window = makeWindow(wide: false)
        defer { hideTestWindow(window) }
        let row = makeRow(in: window)

        let badge = try #require(descendants(of: row, SessionGridBadgeView.self).first)
        let title = try #require(label("Refactor checkout flow", in: row))
        let circleFrame = badge.convert(badge.bounds, to: row)
        let titleFrame = title.convert(title.bounds, to: row)
        #expect(
            abs(circleFrame.minY - titleFrame.minY) < 6,
            "the circle sits on the title line, not centred in the row: circle \(circleFrame), title \(titleFrame)"
        )

        // The circle is inside the row: the details and the circle share the height.
        #expect(
            circleFrame.maxY <= height(of: row),
            "the row grows for the circle rather than drawing it outside: circle \(circleFrame), row \(height(of: row))"
        )
    }

    /// The size the person picked moves the circle, the column, and the text
    /// past it together, and the row grows only when the circle is taller than
    /// the words: a big icon beside a short row does not clip.
    @Test func eachSizeDrawsItsCircleAndItsTextColumn() throws {
        let window = makeWindow(wide: false)
        defer { hideTestWindow(window) }
        for size in SessionIconSize.allCases {
            let identity = SessionRowIdentity(size: size)
            let row = makeRow(in: window, identity: identity)
            defer { row.removeFromSuperview() }

            #expect(drawnIcon(of: row)?.side == identity.side, "\(size) circle")
            #expect(textStart(of: row) == identity.textInset, "\(size) text start")
            #expect(height(of: row) >= identity.side, "\(size) row fits its circle")
        }
    }
}

/// The size preference: a defaults suite of its own, never the app's, because
/// session rows elsewhere read the shared one while these run.
@Suite("Session icon size preference")
struct SessionIconSizePreferenceTests {
    private typealias Store = AppPreferenceStore.Appearance

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "SessionIconSizePreferenceTests.\(UUID().uuidString)"))
    }

    /// The sizes rows drew before the setting existed, so an update never
    /// resizes a list.
    @Test func nothingStoredIsTheSmallCircle() throws {
        #expect(Store.sessionIconSize(in: try makeDefaults()) == .small)
        #expect(Store.sessionIconSizeDefault == .small)
    }

    @Test func anUnreadableValueIsTheSmallCircle() throws {
        let defaults = try makeDefaults()
        defaults.set("some-future-size", forKey: Store.sessionIconSizeKey)
        #expect(Store.sessionIconSize(in: defaults) == .small)
    }

    @Test func everyChoiceIsStoredAndReadBack() throws {
        let defaults = try makeDefaults()
        for size in SessionIconSize.allCases {
            defaults.set(size.rawValue, forKey: Store.sessionIconSizeKey)
            #expect(Store.sessionIconSize(in: defaults) == size)
        }
        #expect(SessionIconSize.allCases == [.small, .medium, .large])
    }
}

/// Settings › Session Rows › Icon Size while a row is on screen: the row
/// redraws where it is, at the new circle and column, and a row built later
/// reads the size Settings holds now.
///
/// The write goes through the shared defaults the app's device store uses, so
/// this suite is serialized and puts the stored value back; another suite's row
/// laid out inside that window reads the size this test set.
@Suite("Session icon size live change", .serialized)
@MainActor
struct SessionIconSizeLiveChangeTests {
    private func makeWindow() -> UIWindow {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 400))
        window.isHidden = false
        return window
    }

    private func makeRow(in window: UIWindow) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 60)
        window.addSubview(row)
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: Session(
                id: "live-size",
                workspaceId: "ws",
                workspaceName: "shop-app",
                name: "Live size",
                status: .ready,
                createdAt: Date(timeIntervalSince1970: 1_000),
                lastActivity: Date(timeIntervalSince1970: 1_000),
                messageCount: 4,
                tokens: TokenUsage(input: 2_000, output: 400),
                cost: 0.2
            ))),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        return row
    }

    private func drawnSide(of row: SessionRowView) -> CGFloat? {
        func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
            root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
        }
        return descendants(of: row, SessionGridBadgeView.self).first?.bounds.width
    }

    private func textStart(of row: SessionRowView) -> CGFloat? {
        func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
            root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
        }
        return descendants(of: row, UILabel.self)
            .first { $0.text == "Live size" }
            .map { $0.convert($0.bounds, to: row).minX }
    }

    /// The store writes the preference, the notification reaches the row, and
    /// the row it is already drawing moves to the new size without a reload.
    @Test func aStoredSizeMovesARowOnScreen() async throws {
        let key = AppPreferenceStore.Appearance.sessionIconSizeKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            NotificationCenter.default.post(
                name: AppPreferenceStore.Appearance.sessionIconSizeDidChangeNotification,
                object: nil
            )
        }

        let window = makeWindow()
        defer { hideTestWindow(window) }
        UserDefaults.standard.set(SessionIconSize.small.rawValue, forKey: key)
        let row = makeRow(in: window)
        window.layoutIfNeeded()
        #expect(drawnSide(of: row) == 32)
        #expect(textStart(of: row) == 44)

        // Settings saves through the device store, whose hook posts the change.
        UserDefaults.standard.set(SessionIconSize.large.rawValue, forKey: key)
        NotificationCenter.default.post(
            name: AppPreferenceStore.Appearance.sessionIconSizeDidChangeNotification,
            object: nil
        )
        window.layoutIfNeeded()

        #expect(drawnSide(of: row) == 56)
        #expect(textStart(of: row) == 68)
        #expect(row.systemLayoutSizeFitting(
            CGSize(width: 430, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height >= 56)

        // A row built for the next cell takes the size from the preference too.
        let recycled = makeRow(in: window)
        window.layoutIfNeeded()
        #expect(drawnSide(of: recycled) == 56)
        #expect(textStart(of: recycled) == 68)
    }
}

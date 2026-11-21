import Testing
import UIKit
@testable import Oppi

/// The session row's identity tile. A compact layout (an iPhone) keeps the 20-pt
/// tile the row was drawn with; a wide one (an iPad, or the Duo's inner display)
/// draws 32 pt, balancing it against the title and its caption detail line (about
/// 39 pt together at the default text size), and the text column moves out with
/// it. The row's height stays the text's: the bigger tile fits inside it.
@MainActor
@Suite("Session row identity tile")
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

    private func makeRow(in window: UIWindow) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 80)
        window.addSubview(row)
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session())),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        window.layoutIfNeeded()
        return row
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    /// The identity tile's drawn side.
    private func tileSide(of row: SessionRowView) -> CGFloat? {
        descendants(of: row, SessionGridBadgeView.self).first.map(\.bounds.width)
    }

    /// Where the row's text starts, past the tile.
    private func textStart(of row: SessionRowView) -> CGFloat? {
        descendants(of: row, UILabel.self)
            .first { $0.text == "Refactor checkout flow" }
            .map { $0.convert($0.bounds, to: row).minX }
    }

    private func height(of row: SessionRowView) -> CGFloat {
        row.systemLayoutSizeFitting(
            CGSize(width: 430, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    @Test func theGridIsTheRowsOwnWhenCompactAndWiderWhenWide() {
        #expect(SessionRowIdentity.tileSide(isWide: false) == 20)
        #expect(SessionRowIdentity.columnWidth(isWide: false) == 24)
        #expect(SessionRowIdentity.textInset(isWide: false) == 32, "the grid the row was drawn with")
        #expect(SessionRowIdentity.tileSide(isWide: true) == 32)
        #expect(SessionRowIdentity.columnWidth(isWide: true) == 36)
        #expect(SessionRowIdentity.textInset(isWide: true) == 44)
    }

    @Test func aWideRowDrawsTheLargerTileWithoutGrowingTheRow() {
        let phone = makeWindow(wide: false)
        let pad = makeWindow(wide: true)
        defer {
            hideTestWindow(phone)
            hideTestWindow(pad)
        }
        let phoneRow = makeRow(in: phone)
        let padRow = makeRow(in: pad)

        #expect(tileSide(of: phoneRow) == 20)
        #expect(textStart(of: phoneRow) == 32)
        #expect(tileSide(of: padRow) == 32)
        #expect(textStart(of: padRow) == 44)
        // The tile is as tall as the row's first two lines, and still inside the
        // row: both widths lay the same three lines out at the same height.
        #expect(height(of: padRow) == height(of: phoneRow))
    }

    @Test func aRowThatTurnsWideGrowsItsTile() {
        let window = makeWindow(wide: false)
        defer { hideTestWindow(window) }
        let row = makeRow(in: window)
        #expect(tileSide(of: row) == 20)

        // A row in a window that turned wide (Split View, rotation): the next
        // pass resizes the tile and moves the text column with it.
        window.traitOverrides.horizontalSizeClass = .regular
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session())),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        window.layoutIfNeeded()
        #expect(tileSide(of: row) == 32)
        #expect(textStart(of: row) == 44)
    }
}

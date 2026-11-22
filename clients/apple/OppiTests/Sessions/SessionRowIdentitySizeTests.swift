import Testing
import UIKit
@testable import Oppi

/// The session row's identity icon: the session's icon on the 32-pt circle an
/// Agent's own page draws it in, on every width, with the text column starting
/// past it. The row's height stays the text's: the circle is aligned to the
/// title line and fits beside the details.
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
    /// text column, which moves the title away from the circle.
    private func makeRow(in window: UIWindow) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 60)
        window.addSubview(row)
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session())),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
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

    @Test func theIconIsTheAgentPagesCircleAtBothWidths() {
        #expect(SessionRowIdentity.side == 32)
        #expect(SessionRowIdentity.columnWidth == 36)
        #expect(SessionRowIdentity.textInset == 44)
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

        #expect(drawnIcon(of: phoneRow)?.side == 32)
        #expect(drawnIcon(of: phoneRow)?.shape == .circle)
        #expect(textStart(of: phoneRow) == 44)
        #expect(drawnIcon(of: padRow)?.side == 32)
        #expect(drawnIcon(of: padRow)?.shape == .circle)
        #expect(textStart(of: padRow) == 44)
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
}

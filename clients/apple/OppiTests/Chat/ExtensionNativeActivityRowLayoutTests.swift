import Foundation
import Testing
import UIKit
@testable import Oppi

/// Where an activity row's pieces land in the drawer and in the panel pane: the state icon and the
/// trailing accessories on the title's first line, and every row under its section's header.
@Suite("Extension activity row layout")
@MainActor
struct ExtensionNativeActivityRowLayoutTests {
    /// Sections of rows as the Subagents widget publishes them: a running row with `since`, finished
    /// rows with a subtitle, a detail and disclosure blocks, and a disclosure row that nests a list.
    private static let surfaceJSON = #"""
    {
      "version": 1, "id": "widget:rows", "source": "widget",
      "presentation": { "style": "surfacePanel", "title": "Rows", "subtitle": "1 working" },
      "blocks": [
        { "type": "section", "id": "working", "title": "Working", "blocks": [
          { "type": "activityList", "id": "working:rows", "rows": [
            { "id": "run-1", "title": "build-the-thing", "subtitle": "Running sim-pool.sh",
              "detail": "opus high · $21.40", "state": "running", "since": 1794771931826,
              "link": "oppi://session/run-1",
              "blocks": [{ "type": "markdown", "id": "answer", "markdown": "**Now:** Running" }] }
          ] }
        ] },
        { "type": "section", "id": "recent", "title": "Recent", "blocks": [
          { "type": "activityList", "id": "recent:rows", "rows": [
            { "id": "done-1", "title": "fix-the-viewport", "subtitle": "Warnings ratchet passes on the fixed build.",
              "detail": "opus medium · $7.30 · took 37m", "state": "success", "link": "oppi://session/done-1",
              "blocks": [{ "type": "markdown", "id": "answer", "markdown": "Done." }] },
            { "id": "done-2", "title": "row-width", "subtitle": "Waiting for bash-47.",
              "detail": "opus medium · $2.86 · took 9m", "state": "success", "link": "oppi://session/done-2" }
          ] }
        ] },
        { "type": "section", "id": "earlier", "title": "Earlier", "blocks": [
          { "type": "activityList", "id": "earlier:rows", "rows": [
            { "id": "earlier-all", "title": "2 finished", "blocks": [
              { "type": "activityList", "id": "earlier:nested", "rows": [
                { "id": "old-1", "title": "ask-agent", "subtitle": "PASS: snapshot to chat.",
                  "detail": "opus medium · $12.31 · took 1h", "state": "success", "link": "oppi://session/old-1",
                  "blocks": [{ "type": "markdown", "id": "answer", "markdown": "Done." }] },
                { "id": "old-2", "title": "page-fast", "subtitle": "Both fixes are in.",
                  "detail": "opus medium · $7.14 · took 25m", "state": "success", "link": "oppi://session/old-2" }
              ] }
            ] }
          ] }
        ] }
      ]
    }
    """#

    private static let topLevelRowIDs = ["run-1", "done-1", "done-2", "earlier-all"]
    private static let rowIDs = topLevelRowIDs + ["old-1", "old-2"]

    @Test func drawerAlignsRowsToTheirTitleLine() throws {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1133))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let drawer = ExtensionNativeBlockScrollView(frame: CGRect(x: 0, y: 0, width: 560, height: 1000))
        host.view.addSubview(drawer)
        drawer.update(
            content: ExtensionNativeBlockContent(surface: try surface()),
            context: context(),
            sizing: .fill,
            contentInsets: NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
            spacing: 10,
            accessibilityIdentifier: nil,
            onDoubleTap: nil
        )
        drawer.layoutIfNeeded()
        try assertAligned(in: drawer, rows: Self.topLevelRowIDs, disclosed: false)
        try expandEarlier(in: drawer)
        try assertAligned(in: drawer)
    }

    /// The pane mounts the reader without its header into its body once a snapshot arrives, as
    /// `ExtensionPanelViewController` does, and lays it out in the window's next pass.
    @Test func paneAlignsRowsToTheirTitleLine() throws {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 1133))
        let pane = UIViewController()
        window.rootViewController = pane
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        window.layoutIfNeeded()

        let reader = ExtensionNativeSurfaceDetailViewController(
            surface: try surface(),
            identifierSuffix: "rows",
            title: "Rows",
            subtitle: nil,
            showsHeader: false,
            onLeave: {}
        )
        // The pane builds its reader as its own properties update, before the reader is in the
        // window: the rows configure and lay out once there, at no size.
        reader.loadViewIfNeeded()
        reader.updatePropertiesIfNeeded()
        reader.view.layoutIfNeeded()
        pane.addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        pane.view.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(equalTo: pane.view.topAnchor),
            reader.view.leadingAnchor.constraint(equalTo: pane.view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: pane.view.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: pane.view.bottomAnchor),
        ])
        reader.didMove(toParent: pane)
        window.layoutIfNeeded()

        try assertAligned(in: pane.view, rows: Self.topLevelRowIDs, disclosed: false)
        try expandEarlier(in: pane.view)
        try assertAligned(in: pane.view)
    }

    /// A narrow pane of working rows, as a busy thread fills it: every row runs with a ticking time,
    /// some with a subtitle and some without, each with disclosure blocks and a link.
    @Test func narrowPaneOfWorkingRowsAlignsEveryRow() throws {
        let ids = (0 ..< 8).map { "w\($0)" }
        let rows = ids.enumerated().map { index, id in
            ExtensionUIActivityRow(
                id: id, title: "worker-\(index)", subtitle: index.isMultiple(of: 2) ? "Waiting on background work" : nil,
                detail: "opus medium · $9.80 · 1 ahead", state: "running", progress: nil,
                link: "oppi://session/\(id)", children: nil,
                blocks: [.markdown(base: ExtensionUIBlockBase(id: "answer", accessibility: nil), markdown: "Working")],
                since: 1_794_771_931_826 - Double(index) * 60_000
            )
        }
        let surface = ExtensionUINativeSurface(
            version: 1, id: "widget:rows", source: "widget",
            presentation: ExtensionUINativePresentation(style: "surfacePanel", title: "Rows", subtitle: "8 working"),
            blocks: [.section(
                base: ExtensionUIBlockBase(id: "working", accessibility: nil), title: "Working", subtitle: nil,
                blocks: [.activityList(base: ExtensionUIBlockBase(id: "working:rows", accessibility: nil), rows: rows)]
            )],
            fallback: nil
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 1133))
        let reader = ExtensionNativeSurfaceDetailViewController(
            surface: surface, identifierSuffix: "rows", title: "Rows", subtitle: nil, showsHeader: false, onLeave: {}
        )
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        reader.view.layoutIfNeeded()

        let root: UIView = reader.view
        let header = try #require(sectionHeader("Working", in: root))
        var previousBottom = header.convert(header.bounds, to: root).maxY
        for (index, id) in ids.enumerated() {
            let control = try #require(rowControl(id, in: root), "row \(id) is shown")
            let title = try #require(subviews(of: UILabel.self, in: control).first { $0.text == "worker-\(index)" })
            let titleFrame = title.convert(title.bounds, to: root)
            let icon = try #require(stateIcon(in: control))
            let iconFrame = icon.convert(icon.bounds, to: root)
            #expect(abs(iconFrame.midY - titleFrame.midY) <= 1, "row \(id): icon at \(iconFrame.midY), title at \(titleFrame.midY)")
            #expect(iconFrame.minY >= previousBottom, "row \(id): icon at \(iconFrame.minY) reaches above \(previousBottom)")
            for accessory in trailingAccessories(of: control) {
                let frame = accessory.convert(accessory.bounds, to: root)
                #expect(abs(frame.midY - titleFrame.midY) <= 1, "row \(id): \(type(of: accessory)) at \(frame.midY), title at \(titleFrame.midY)")
            }
            previousBottom = control.convert(control.bounds, to: root).maxY
        }
    }

    @Test func fullScreenReaderAlignsRowsToTheirTitleLine() throws {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1133))
        let reader = ExtensionNativeSurfaceDetailViewController(
            surface: try surface(),
            identifierSuffix: "rows",
            title: "Rows",
            subtitle: "1 working",
            onLeave: {}
        )
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        reader.view.layoutIfNeeded()

        try assertAligned(in: reader.view, rows: Self.topLevelRowIDs, disclosed: false)
        try expandEarlier(in: reader.view)
        try assertAligned(in: reader.view)
    }

    // MARK: - Checks

    private func expandEarlier(in root: UIView) throws {
        let control = try #require(rowControl("earlier-all", in: root))
        control.sendActions(for: .touchUpInside)
        root.layoutIfNeeded()
    }

    /// Each row's icon, time, chevron and link button centre on its title's first line; each row's
    /// top sits under its section's header; the first row of a disclosed list sits as far under its
    /// disclosure row's title as one row sits under the row before it.
    private func assertAligned(in root: UIView, rows: [String] = Self.rowIDs, disclosed: Bool = true) throws {
        for id in rows {
            let control = try #require(rowControl(id, in: root), "row \(id) is shown")
            let title = try #require(titleLabel(in: control, id: id), "row \(id) draws its title")
            let titleLine = title.convert(title.bounds, to: root)
            // The title is attributed text: its own font sets its line.
            let titleFont = title.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? title.font
            let titleMid = titleLine.minY + (titleFont?.lineHeight ?? 0) / 2

            let icon = try #require(stateIcon(in: control), "row \(id) draws its state")
            let iconFrame = icon.convert(icon.bounds, to: root)
            #expect(abs(iconFrame.midY - titleMid) <= 1, "row \(id): icon at \(iconFrame.midY), title line at \(titleMid)")

            for accessory in trailingAccessories(of: control) {
                let frame = accessory.convert(accessory.bounds, to: root)
                #expect(
                    abs(frame.midY - titleMid) <= 1,
                    "row \(id): \(type(of: accessory)) at \(frame.midY), title line at \(titleMid)"
                )
            }
        }

        for (header, firstRow) in [("Working", "run-1"), ("Recent", "done-1"), ("Earlier", "earlier-all")] {
            let label = try #require(sectionHeader(header, in: root), "section \(header) draws its header")
            let headerFrame = label.convert(label.bounds, to: root)
            let control = try #require(rowControl(firstRow, in: root))
            let rowFrame = control.convert(control.bounds, to: root)
            let icon = try #require(stateIcon(in: control))
            let iconFrame = icon.convert(icon.bounds, to: root)
            #expect(rowFrame.minY >= headerFrame.maxY, "\(header): row at \(rowFrame.minY), header ends at \(headerFrame.maxY)")
            #expect(iconFrame.minY >= headerFrame.maxY, "\(header): icon at \(iconFrame.minY), header ends at \(headerFrame.maxY)")
        }

        guard disclosed else { return }
        // A disclosed list continues its disclosure row as the next row of one list does: as far
        // under the disclosure row as one row of a list sits under the row before it.
        func rowGap(_ upper: String, _ lower: String) throws -> CGFloat {
            let top = try #require(rowControl(upper, in: root))
            let bottom = try #require(rowControl(lower, in: root))
            return bottom.convert(bottom.bounds, to: root).minY - top.convert(top.bounds, to: root).maxY
        }
        let disclosureGap = try rowGap("earlier-all", "old-1")
        let listStep = try rowGap("done-1", "done-2")
        #expect(abs(disclosureGap - listStep) <= 1, "disclosed list starts \(disclosureGap) under its row; a list step is \(listStep)")
    }

    // MARK: - Finding views

    private func rowControl(_ id: String, in root: UIView) -> UIControl? {
        subviews(of: UIControl.self, in: root).first {
            $0.accessibilityIdentifier == "extension.native.activity.row.\(id)" && visible($0, under: root)
        }
    }

    private func titleLabel(in control: UIView, id: String) -> UILabel? {
        subviews(of: UILabel.self, in: control).first { $0.text == Self.titles[id] }
    }

    private static let titles = [
        "run-1": "build-the-thing", "done-1": "fix-the-viewport", "done-2": "row-width",
        "earlier-all": "2 finished", "old-1": "ask-agent", "old-2": "page-fast",
    ]

    /// The visible state icon: the working mark on a running row, else the state symbol, both
    /// direct subviews of the row's control.
    private func stateIcon(in control: UIView) -> UIImageView? {
        control.subviews.compactMap { $0 as? UIImageView }.first { !$0.isHidden && $0.image != nil }
    }

    /// The time, the chevron (in the trailing stack) and the separate link button beside the control.
    private func trailingAccessories(of control: UIView) -> [UIView] {
        let trailing = control.subviews.compactMap { $0 as? UIStackView }.first { $0.axis == .horizontal }
        let inTrailing = trailing?.arrangedSubviews.filter { !$0.isHidden } ?? []
        let link = (control.superview as? UIStackView)?.arrangedSubviews.first { $0 is UIButton && !$0.isHidden }
        return inTrailing + (link.map { [$0] } ?? [])
    }

    private func sectionHeader(_ text: String, in root: UIView) -> UILabel? {
        subviews(of: UILabel.self, in: root).first { $0.text == text && visible($0, under: root) }
    }

    private func visible(_ view: UIView, under root: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current, candidate !== root {
            if candidate.isHidden { return false }
            current = candidate.superview
        }
        return true
    }

    private func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) + subviews(of: type, in: child)
        }
    }

    // MARK: - Fixture

    private func surface() throws -> ExtensionUINativeSurface {
        try JSONDecoder().decode(ExtensionUINativeSurface.self, from: Data(Self.surfaceJSON.utf8))
    }

    private func context() -> ExtensionNativeBlockContext {
        ExtensionNativeBlockContext(
            themeID: .dark,
            linkContext: ExtensionSurfaceLinkContext(serverID: "server-1", workspaceID: "ws-1", sessionID: "parent"),
            onOpenURL: { _ in true }
        )
    }
}

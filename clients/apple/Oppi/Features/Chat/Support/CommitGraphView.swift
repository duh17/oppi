import UIKit

/// The Git panel's commit graph: one row per commit, its lanes drawn in a
/// gutter on the left (`CommitGraphLayout`), its SHA and subject, and chips for
/// the branches, tags, and worktrees that point at it. Rows stack with no gap,
/// so each row's lanes meet the next row's.
@MainActor
enum CommitGraphView {
    struct Style {
        let sha: UIFont
        let message: UIFont
        let chip: UIFont
        let chevron: UIFont
        let palette: ThemePalette
    }

    /// The rows of `layout`, in a vertical stack. `currentWorktreeId` is the
    /// queried checkout; every other checkout marks the branch or commit it has
    /// out.
    static func make(
        layout: CommitGraphLayout,
        worktrees: [WorkspaceWorktree],
        currentWorktreeId: String?,
        style: Style,
        onSelect: @escaping (CommitGraphCommit) -> Void
    ) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        let marks = WorktreeMarks(worktrees: worktrees, currentWorktreeId: currentWorktreeId)
        let colors = laneColors(style.palette)
        for row in layout.rows {
            let content = RowContentView(
                row: row,
                laneCount: layout.laneCount,
                laneColors: colors,
                chips: chips(for: row.commit, marks: marks, style: style),
                style: style
            )
            let button = PlainRowButton(wrapping: content) { onSelect(row.commit) }
            button.accessibilityLabel = content.accessibilityParts.joined(separator: ", ")
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private static func laneColors(_ palette: ThemePalette) -> [UIColor] {
        [palette.purple, palette.cyan, palette.green, palette.orange, palette.blue, palette.yellow, palette.red]
            .map { UIColor($0) }
    }

    // MARK: Chips

    /// Which checkouts other than the queried one have a branch or a detached
    /// commit out.
    private struct WorktreeMarks {
        var byBranch: [String: WorkspaceWorktree] = [:]
        var detached: [WorkspaceWorktree] = []

        init(worktrees: [WorkspaceWorktree], currentWorktreeId: String?) {
            let current = currentWorktreeId.flatMap { $0.isEmpty ? nil : $0 } ?? WorkspaceWorktree.mainId
            for worktree in worktrees where worktree.id != current {
                if let branch = worktree.branch, !branch.isEmpty {
                    byBranch[branch] = worktree
                } else if let headSha = worktree.headSha, !headSha.isEmpty {
                    detached.append(worktree)
                }
            }
        }

        /// Checkouts with `commit` detached; a worktree's `headSha` is
        /// abbreviated.
        func detachedAt(_ commit: CommitGraphCommit) -> [WorkspaceWorktree] {
            detached.filter { worktree in
                guard let headSha = worktree.headSha else { return false }
                return commit.sha.hasPrefix(headSha)
            }
        }
    }

    struct Chip {
        let text: String
        let symbol: String?
        let color: UIColor
        let accessibility: String
    }

    /// The commit's refs, most telling first: what this checkout has out, local
    /// branches, other checkouts, tags, then remotes.
    private static func chips(for commit: CommitGraphCommit, marks: WorktreeMarks, style: Style) -> [Chip] {
        let palette = style.palette
        var head: [Chip] = []
        var branches: [Chip] = []
        var tags: [Chip] = []
        var remotes: [Chip] = []
        for ref in commit.refs {
            switch ref.kind {
            case .head:
                head.append(Chip(
                    text: "HEAD", symbol: nil, color: UIColor(palette.orange),
                    accessibility: String(localized: "detached HEAD")
                ))
            case .branch where ref.isHead == true:
                head.append(Chip(
                    text: ref.name, symbol: "arrow.branch", color: UIColor(palette.cyan),
                    accessibility: String(localized: "current branch \(ref.name)")
                ))
            case .branch:
                if let worktree = marks.byBranch[ref.name] {
                    branches.append(Chip(
                        text: ref.name, symbol: "folder", color: UIColor(palette.green),
                        accessibility: String(localized: "branch \(ref.name), checked out in \(worktree.displayName)")
                    ))
                } else {
                    branches.append(Chip(
                        text: ref.name, symbol: nil, color: UIColor(palette.purple),
                        accessibility: String(localized: "branch \(ref.name)")
                    ))
                }
            case .tag:
                tags.append(Chip(
                    text: ref.name, symbol: "tag", color: UIColor(palette.yellow),
                    accessibility: String(localized: "tag \(ref.name)")
                ))
            case .remote:
                remotes.append(Chip(
                    text: ref.name, symbol: "cloud", color: UIColor(palette.comment),
                    accessibility: String(localized: "remote \(ref.name)")
                ))
            }
        }
        let detached = marks.detachedAt(commit).map { worktree in
            Chip(
                text: worktree.name, symbol: "folder", color: UIColor(palette.green),
                accessibility: String(localized: "worktree \(worktree.name)")
            )
        }
        return head + branches + detached + tags + remotes
    }

    // MARK: Row

    /// A row: the lane gutter, then the SHA and subject over the ref chips.
    private final class RowContentView: UIView {
        private let lanes: LanesView
        private let firstLine: UIStackView
        private let textStack: UIStackView
        let accessibilityParts: [String]

        /// Chips a row shows before it counts the rest.
        private static let maxChips = 3

        init(row: CommitGraphRow, laneCount: Int, laneColors: [UIColor], chips: [Chip], style: Style) {
            lanes = LanesView(row: row, laneCount: laneCount, colors: laneColors, background: UIColor(style.palette.bg))
            let sha = Self.label(row.commit.shortSha, font: style.sha, color: UIColor(style.palette.comment))
            sha.setContentCompressionResistancePriority(.required, for: .horizontal)
            sha.setContentHuggingPriority(.required, for: .horizontal)
            let message = Self.label(
                row.commit.message,
                font: style.message,
                color: UIColor(row.commit.isHead ? style.palette.fg : style.palette.fgDim)
            )
            message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            message.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let chevron = ChangedFileRow.chevron(font: style.chevron, palette: style.palette)
            firstLine = UIStackView(arrangedSubviews: [sha, message, chevron])
            firstLine.axis = .horizontal
            firstLine.alignment = .center
            firstLine.spacing = 8
            firstLine.setCustomSpacing(16, after: message)
            textStack = UIStackView(arrangedSubviews: [firstLine])
            textStack.axis = .vertical
            textStack.alignment = .fill
            textStack.spacing = 3
            if !chips.isEmpty {
                textStack.addArrangedSubview(Self.chipRow(chips, style: style))
            }
            accessibilityParts = [row.commit.shortSha, row.commit.message] + chips.map(\.accessibility)
            super.init(frame: .zero)
            isOpaque = false
            for view in [lanes, textStack] as [UIView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                lanes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                lanes.topAnchor.constraint(equalTo: topAnchor),
                lanes.bottomAnchor.constraint(equalTo: bottomAnchor),
                lanes.widthAnchor.constraint(equalToConstant: LanesView.width(laneCount: laneCount)),
                textStack.leadingAnchor.constraint(equalTo: lanes.trailingAnchor, constant: 6),
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                textStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// The dot sits level with the subject line.
        override func layoutSubviews() {
            super.layoutSubviews()
            lanes.dotY = textStack.frame.minY + firstLine.frame.midY
        }

        private static func chipRow(_ chips: [Chip], style: Style) -> UIView {
            var views = chips.prefix(maxChips).map { chipView($0, font: style.chip) }
            if chips.count > maxChips {
                views.append(label("+\(chips.count - maxChips)", font: style.chip, color: UIColor(style.palette.comment)))
            }
            for view in views.dropLast() {
                view.setContentHuggingPriority(.required, for: .horizontal)
            }
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            let row = UIStackView(arrangedSubviews: views + [spacer])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 4
            return row
        }

        private static func chipView(_ chip: Chip, font: UIFont) -> UIView {
            var items: [UIView] = []
            if let symbol = chip.symbol {
                let icon = UIImageView(image: UIImage(systemName: symbol))
                icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
                icon.tintColor = chip.color
                icon.contentMode = .center
                icon.setContentHuggingPriority(.required, for: .horizontal)
                icon.setContentCompressionResistancePriority(.required, for: .horizontal)
                items.append(icon)
            }
            let text = label(chip.text, font: font, color: chip.color)
            text.lineBreakMode = .byTruncatingMiddle
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            items.append(text)
            let stack = UIStackView(arrangedSubviews: items)
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 3
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5)
            stack.backgroundColor = chip.color.withAlphaComponent(0.14)
            stack.layer.cornerRadius = 4
            stack.layer.cornerCurve = .continuous
            return stack
        }

        private static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = font
            label.textColor = color
            label.adjustsFontForContentSizeCategory = true
            return label
        }
    }

    // MARK: Lanes

    /// One row's slice of the graph. Lines leave at the row's top and bottom
    /// edges at their lane's center, so the slices above and below continue
    /// them.
    private final class LanesView: UIView {
        static let lineWidth: CGFloat = 1.75
        static let dotRadius: CGFloat = 3.5

        /// 12 pt a lane up to six lanes; a wider graph squeezes its lanes into
        /// the same 72 pt (down to 5 pt each) so the subjects keep the row.
        static func laneSpacing(laneCount: Int) -> CGFloat {
            laneCount <= 6 ? 12 : max(5, 72 / CGFloat(laneCount))
        }

        static func width(laneCount: Int) -> CGFloat {
            CGFloat(max(laneCount, 1)) * laneSpacing(laneCount: laneCount)
        }

        private let row: CommitGraphRow
        private let laneSpacing: CGFloat
        private let colors: [UIColor]
        private let background: UIColor
        var dotY: CGFloat = 0 {
            didSet { if abs(dotY - oldValue) > 0.25 { setNeedsDisplay() } }
        }

        init(row: CommitGraphRow, laneCount: Int, colors: [UIColor], background: UIColor) {
            self.row = row
            laneSpacing = Self.laneSpacing(laneCount: laneCount)
            self.colors = colors
            self.background = background
            super.init(frame: .zero)
            isOpaque = false
            contentMode = .redraw
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        private func x(_ lane: Int) -> CGFloat {
            (CGFloat(lane) + 0.5) * laneSpacing
        }

        private func color(_ lane: Int) -> UIColor {
            colors[lane % colors.count]
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.setLineWidth(Self.lineWidth)
            context.setLineCap(.round)
            let bottom = bounds.height
            let dot = CGPoint(x: x(row.column), y: dotY)

            for lane in row.passing {
                stroke(context, color: color(lane)) { path in
                    path.move(to: CGPoint(x: x(lane), y: 0))
                    path.addLine(to: CGPoint(x: x(lane), y: bottom))
                }
            }
            if row.continuesFromAbove {
                stroke(context, color: color(row.column)) { path in
                    path.move(to: CGPoint(x: dot.x, y: 0))
                    path.addLine(to: dot)
                }
            }
            for lane in row.outgoing {
                stroke(context, color: color(lane)) { path in
                    path.move(to: dot)
                    let end = CGPoint(x: x(lane), y: bottom)
                    if lane == row.column {
                        path.addLine(to: end)
                    } else {
                        // Leave the dot sideways and arrive straight down, so
                        // the bend meets the next row's vertical line.
                        let mid = (dot.y + bottom) / 2
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: end.x, y: dot.y),
                            control2: CGPoint(x: end.x, y: mid)
                        )
                    }
                }
            }

            let dotColor = color(row.column)
            if row.commit.isHead {
                // This checkout's commit: a ring.
                let radius = Self.dotRadius + 1
                let ring = CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(background.cgColor)
                context.fillEllipse(in: ring)
                context.setStrokeColor(dotColor.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: ring)
            } else {
                let radius = Self.dotRadius
                context.setFillColor(dotColor.cgColor)
                context.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
            }
        }

        private func stroke(_ context: CGContext, color: UIColor, _ build: (CGMutablePath) -> Void) {
            let path = CGMutablePath()
            build(path)
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.strokePath()
        }
    }
}

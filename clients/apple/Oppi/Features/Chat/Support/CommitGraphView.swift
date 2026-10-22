import UIKit

/// The Git panel's commit graph: one table cell per commit, its lanes drawn in
/// a gutter on the left (`CommitGraphLayout`), its SHA and subject, and chips
/// for the branches, tags, and worktrees that point at it. Cells sit with no
/// gap, so each row's lanes meet the next row's. A table, not a stack: a
/// stack of every loaded commit held hundreds of MB of label bitmaps and laid
/// all of them out on each change, a multi-second hang a few pages in.
@MainActor
enum CommitGraphView {
    struct Style {
        let sha: UIFont
        let message: UIFont
        let chip: UIFont
        let chevron: UIFont
        let palette: ThemePalette
    }

    /// What every row draws besides its own commit. `currentWorktreeId` is
    /// the queried checkout; every other checkout marks the branch or commit it
    /// has out.
    @MainActor
    struct Context {
        let laneCount: Int
        let style: Style
        fileprivate let marks: WorktreeMarks
        fileprivate let laneColors: [UIColor]

        init(laneCount: Int, worktrees: [WorkspaceWorktree], currentWorktreeId: String?, style: Style) {
            self.laneCount = laneCount
            self.style = style
            marks = WorktreeMarks(worktrees: worktrees, currentWorktreeId: currentWorktreeId)
            laneColors = CommitGraphView.laneColors(style.palette)
        }
    }

    /// A row's height, from its fonts alone: the subject line, and the chip
    /// line under it when the commit has refs. The table asks for every row's
    /// height on each update, so it is arithmetic, not a layout pass: self-sized
    /// rows made a 2,000-commit graph re-measure every row per page.
    static func rowHeight(for row: CommitGraphRow, context: Context) -> CGFloat {
        let style = context.style
        let firstLine = max(style.sha.lineHeight, style.message.lineHeight).rounded(.up)
        guard !row.commit.refs.isEmpty || !context.marks.detachedAt(row.commit).isEmpty else {
            return firstLine + 8
        }
        let chipLine = (style.chip.lineHeight + 2).rounded(.up)
        return firstLine + 3 + chipLine + 8
    }

    /// A commit's row; a tap runs `configure`'s `onSelect`.
    final class Cell: UITableViewCell {
        static let reuseIdentifier = "CommitGraphView.Cell"

        private let content = RowContentView()
        private var button: PlainRowButton?
        private var onSelect: (() -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            selectionStyle = .none
            let button = PlainRowButton(wrapping: content) { [weak self] in self?.onSelect?() }
            button.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            self.button = button
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func configure(row: CommitGraphRow, context: Context, onSelect: @escaping () -> Void) {
            self.onSelect = onSelect
            let chips = CommitGraphView.chips(for: row.commit, marks: context.marks, style: context.style)
            content.configure(row: row, context: context, chips: chips)
            button?.accessibilityLabel = ([row.commit.shortSha, row.commit.message] + chips.map(\.accessibility))
                .joined(separator: ", ")
        }
    }

    fileprivate static func laneColors(_ palette: ThemePalette) -> [UIColor] {
        [palette.purple, palette.cyan, palette.green, palette.orange, palette.blue, palette.yellow, palette.red]
            .map { UIColor($0) }
    }

    // MARK: Chips

    /// Which checkouts other than the queried one have a branch or a detached
    /// commit out.
    fileprivate struct WorktreeMarks {
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
    fileprivate static func chips(for commit: CommitGraphCommit, marks: WorktreeMarks, style: Style) -> [Chip] {
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
    /// Its views are made once per cell and refilled on reuse.
    private final class RowContentView: UIView {
        private let lanes = LanesView()
        private let sha = UILabel()
        private let message = UILabel()
        private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        private let firstLine: UIStackView
        private let chipRow = UIStackView()
        private let textStack: UIStackView
        private var lanesWidth: NSLayoutConstraint?

        /// Chips a row shows before it counts the rest.
        private static let maxChips = 3

        init() {
            firstLine = UIStackView(arrangedSubviews: [sha, message, chevron])
            textStack = UIStackView(arrangedSubviews: [firstLine, chipRow])
            super.init(frame: .zero)
            // Fonts change only through `configure`: a row's height is computed
            // from them (`rowHeight`), so a label must not rescale on its own.
            sha.setContentCompressionResistancePriority(.required, for: .horizontal)
            sha.setContentHuggingPriority(.required, for: .horizontal)
            message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            message.setContentHuggingPriority(.defaultLow, for: .horizontal)
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            firstLine.axis = .horizontal
            firstLine.alignment = .center
            firstLine.spacing = 8
            firstLine.setCustomSpacing(16, after: message)
            chipRow.axis = .horizontal
            chipRow.alignment = .center
            chipRow.spacing = 4
            textStack.axis = .vertical
            textStack.alignment = .fill
            textStack.spacing = 3
            isOpaque = false
            for view in [lanes, textStack] as [UIView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            let width = lanes.widthAnchor.constraint(equalToConstant: LanesView.width(laneCount: 1))
            lanesWidth = width
            NSLayoutConstraint.activate([
                lanes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                lanes.topAnchor.constraint(equalTo: topAnchor),
                lanes.bottomAnchor.constraint(equalTo: bottomAnchor),
                width,
                textStack.leadingAnchor.constraint(equalTo: lanes.trailingAnchor, constant: 6),
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                textStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                // The table sets the height (`rowHeight(for:context:)`).
                textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func configure(row: CommitGraphRow, context: Context, chips: [Chip]) {
            let style = context.style
            let palette = style.palette
            lanes.configure(
                row: row,
                laneCount: context.laneCount,
                colors: context.laneColors,
                background: UIColor(palette.bg)
            )
            lanesWidth?.constant = LanesView.width(laneCount: context.laneCount)
            sha.text = row.commit.shortSha
            sha.font = style.sha
            sha.textColor = UIColor(palette.comment)
            message.text = row.commit.message
            message.font = style.message
            message.textColor = UIColor(row.commit.isHead ? palette.fg : palette.fgDim)
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: style.chevron)
            chevron.tintColor = UIColor(palette.comment).withAlphaComponent(0.5)

            chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chipRow.isHidden = chips.isEmpty
            guard !chips.isEmpty else { return }
            var views = chips.prefix(Self.maxChips).map { Self.chipView($0, font: style.chip) }
            if chips.count > Self.maxChips {
                views.append(Self.label("+\(chips.count - Self.maxChips)", font: style.chip, color: UIColor(palette.comment)))
            }
            for view in views.dropLast() {
                view.setContentHuggingPriority(.required, for: .horizontal)
            }
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            for view in views + [spacer] {
                chipRow.addArrangedSubview(view)
            }
        }

        /// The dot sits level with the subject line.
        override func layoutSubviews() {
            super.layoutSubviews()
            lanes.dotY = textStack.frame.minY + firstLine.frame.midY
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

        private var row: CommitGraphRow?
        private var laneSpacing: CGFloat = 12
        private var colors: [UIColor] = [.gray]
        private var background: UIColor = .clear
        var dotY: CGFloat = 0 {
            didSet { if abs(dotY - oldValue) > 0.25 { setNeedsDisplay() } }
        }

        init() {
            super.init(frame: .zero)
            isOpaque = false
            contentMode = .redraw
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func configure(row: CommitGraphRow, laneCount: Int, colors: [UIColor], background: UIColor) {
            self.row = row
            laneSpacing = Self.laneSpacing(laneCount: laneCount)
            self.colors = colors
            self.background = background
            setNeedsDisplay()
        }

        private func x(_ lane: Int) -> CGFloat {
            (CGFloat(lane) + 0.5) * laneSpacing
        }

        private func color(_ lane: Int) -> UIColor {
            colors[lane % colors.count]
        }

        override func draw(_ rect: CGRect) {
            guard let row, let context = UIGraphicsGetCurrentContext() else { return }
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

import AppKit
import SwiftUI

struct AppKitTimelineView: NSViewRepresentable {
    let rows: [OppiMacTimelineRow]
    let selectedID: String?
    let textScale: CGFloat
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> TimelineTableContainerView {
        let view = TimelineTableContainerView()
        view.onSelectionChange = { id in
            context.coordinator.onSelectionChange(id)
        }
        view.update(rows: rows, selectedID: selectedID, textScale: textScale)
        return view
    }

    func updateNSView(_ nsView: TimelineTableContainerView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        nsView.onSelectionChange = { id in
            context.coordinator.onSelectionChange(id)
        }
        nsView.update(rows: rows, selectedID: selectedID, textScale: textScale)
    }

    final class Coordinator {
        var onSelectionChange: (String?) -> Void

        init(onSelectionChange: @escaping (String?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }
    }
}

final class TimelineTableContainerView: NSView {
    var onSelectionChange: ((String?) -> Void)?

    private var rows: [OppiMacTimelineRow] = []
    private var textScale: CGFloat = 1.15
    private var lastSelectedID: String?
    private var applyingProgrammaticSelection = false

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func update(rows: [OppiMacTimelineRow], selectedID: String?, textScale: CGFloat) {
        let clampedScale = min(max(textScale, 0.95), 1.55)
        let rowsChanged = self.rows != rows
        let scaleChanged = abs(self.textScale - clampedScale) > 0.0001

        if rowsChanged || scaleChanged {
            self.rows = rows
            self.textScale = clampedScale
            tableView.reloadData()
            applyTheme()
        }

        if selectedID != lastSelectedID {
            applyingProgrammaticSelection = true
            defer { applyingProgrammaticSelection = false }

            if let selectedID,
               let selectedRowIndex = rows.firstIndex(where: { $0.id == selectedID }) {
                tableView.selectRowIndexes(IndexSet(integer: selectedRowIndex), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }

            lastSelectedID = selectedID
        }
    }

    private func setUpViews() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self

        let column = NSTableColumn(identifier: .timelineColumn)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme()
    }

    private func applyTheme() {
        let palette = OppiMacTheme.current
        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor

        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        tableView.gridColor = palette.backgroundSecondary
    }
}

extension TimelineTableContainerView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension TimelineTableContainerView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let scaledHeight = rows[row].estimatedHeight * Double(textScale)
        return CGFloat(min(max(scaledHeight, 62), 320))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier.timelineCell

        let rowView: TimelineTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? TimelineTableCellView {
            rowView = reused
        } else {
            rowView = TimelineTableCellView(frame: .zero)
            rowView.identifier = identifier
        }

        let model = rows[row]
        rowView.configure(model, textScale: textScale)
        return rowView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TimelineTableRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingProgrammaticSelection else {
            return
        }

        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0, selectedIndex < rows.count else {
            lastSelectedID = nil
            onSelectionChange?(nil)
            return
        }

        let selectedID = rows[selectedIndex].id
        lastSelectedID = selectedID
        onSelectionChange?(selectedID)
    }
}

private final class TimelineTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 6, dy: 3)
        OppiMacTheme.current.selection.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 10, yRadius: 10).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        // Intentionally no separators — card spacing does the grouping.
    }
}

private final class TimelineTableCellView: NSTableCellView {
    private let cardView = NSView()

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let toolCallIdLabel = NSTextField(labelWithString: "")
    private let errorBadgeLabel = NSTextField(labelWithString: "ERROR")

    private let subtitleLabel = NSTextField(labelWithString: "")

    private let commandCaptionLabel = NSTextField(labelWithString: "Command")
    private let commandContainer = NSView()
    private let commandLabel = NSTextField(labelWithString: "")

    private let outputCaptionLabel = NSTextField(labelWithString: "Output")
    private let outputContainer = NSView()
    private let outputLabel = NSTextField(labelWithString: "")

    private var currentScale: CGFloat = 1.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func configure(_ row: OppiMacTimelineRow, textScale: CGFloat) {
        currentScale = min(max(textScale, 0.95), 1.55)

        titleLabel.stringValue = row.title
        subtitleLabel.stringValue = row.subtitle
        timestampLabel.stringValue = row.timestamp.formatted(date: .omitted, time: .shortened)

        iconView.image = NSImage(systemSymbolName: row.symbolName, accessibilityDescription: row.kind.label)
        iconView.contentTintColor = OppiMacTheme.iconColor(for: row.kind)

        titleLabel.textColor = OppiMacTheme.titleColor(for: row.kind)
        subtitleLabel.textColor = OppiMacTheme.subtitleColor(for: row.kind)
        timestampLabel.textColor = OppiMacTheme.current.comment

        if let toolCallId = row.toolCallId {
            toolCallIdLabel.stringValue = "id: \(toolCallId)"
            toolCallIdLabel.isHidden = false
        } else {
            toolCallIdLabel.stringValue = ""
            toolCallIdLabel.isHidden = true
        }

        errorBadgeLabel.isHidden = !row.isError

        if let commandText = row.commandText {
            commandLabel.stringValue = commandText
            commandCaptionLabel.isHidden = false
            commandContainer.isHidden = false
        } else {
            commandLabel.stringValue = ""
            commandCaptionLabel.isHidden = true
            commandContainer.isHidden = true
        }

        if let outputText = row.outputText {
            outputLabel.stringValue = outputText
            outputLabel.textColor = row.isError ? OppiMacTheme.current.red : OppiMacTheme.current.foreground
            outputCaptionLabel.isHidden = false
            outputContainer.isHidden = false
        } else {
            outputLabel.stringValue = ""
            outputLabel.textColor = OppiMacTheme.current.foreground
            outputCaptionLabel.isHidden = true
            outputContainer.isHidden = true
        }

        applyTypography()
        applyTheme()
    }

    private func setUpViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.alignment = .right
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        toolCallIdLabel.translatesAutoresizingMaskIntoConstraints = false
        toolCallIdLabel.lineBreakMode = .byTruncatingMiddle

        errorBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        errorBadgeLabel.alignment = .center
        errorBadgeLabel.wantsLayer = true
        errorBadgeLabel.layer?.cornerRadius = 6
        errorBadgeLabel.layer?.masksToBounds = true
        errorBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.usesSingleLineMode = false

        commandCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        commandContainer.translatesAutoresizingMaskIntoConstraints = false
        commandContainer.wantsLayer = true
        commandContainer.layer?.cornerRadius = 7
        commandContainer.layer?.masksToBounds = true

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.cell?.wraps = true
        commandLabel.cell?.usesSingleLineMode = false

        outputCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        outputContainer.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.wantsLayer = true
        outputContainer.layer?.cornerRadius = 7
        outputContainer.layer?.masksToBounds = true

        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.lineBreakMode = .byWordWrapping
        outputLabel.cell?.wraps = true
        outputLabel.cell?.usesSingleLineMode = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [iconView, titleLabel, spacer, errorBadgeLabel, timestampLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 8

        let metaRow = NSStackView(views: [toolCallIdLabel])
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 8

        let bodyStack = NSStackView(views: [
            subtitleLabel,
            metaRow,
            commandCaptionLabel,
            commandContainer,
            outputCaptionLabel,
            outputContainer,
        ])
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.distribution = .fill
        bodyStack.spacing = 6

        let containerStack = NSStackView(views: [headerStack, bodyStack])
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.distribution = .fill
        containerStack.spacing = 7

        commandContainer.addSubview(commandLabel)
        outputContainer.addSubview(outputLabel)

        cardView.addSubview(containerStack)
        addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            containerStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            containerStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            containerStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),

            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8),

            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            commandContainer.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
            outputContainer.widthAnchor.constraint(equalTo: containerStack.widthAnchor),

            commandLabel.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 10),
            commandLabel.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -10),
            commandLabel.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: 8),
            commandLabel.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -8),

            outputLabel.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor, constant: 10),
            outputLabel.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor, constant: -10),
            outputLabel.topAnchor.constraint(equalTo: outputContainer.topAnchor, constant: 8),
            outputLabel.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor, constant: -8),
        ])

        applyTypography()
        applyTheme()
    }

    private func applyTypography() {
        let scale = currentScale

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12 * scale,
            weight: .semibold
        )

        titleLabel.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12 * scale, weight: .regular)

        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 10 * scale, weight: .regular)
        toolCallIdLabel.font = .monospacedSystemFont(ofSize: 10 * scale, weight: .regular)

        commandCaptionLabel.font = .systemFont(ofSize: 10 * scale, weight: .semibold)
        outputCaptionLabel.font = .systemFont(ofSize: 10 * scale, weight: .semibold)

        commandLabel.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        outputLabel.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)

        errorBadgeLabel.font = .systemFont(ofSize: 9 * scale, weight: .bold)
    }

    private func applyTheme() {
        let palette = OppiMacTheme.current

        cardView.layer?.backgroundColor = palette.backgroundSecondary.withAlphaComponent(0.75).cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = palette.comment.withAlphaComponent(0.13).cgColor

        commandContainer.layer?.backgroundColor = palette.background.cgColor
        outputContainer.layer?.backgroundColor = palette.background.cgColor

        titleLabel.textColor = palette.foreground
        subtitleLabel.textColor = palette.foregroundDim
        timestampLabel.textColor = palette.comment

        toolCallIdLabel.textColor = palette.comment
        commandCaptionLabel.textColor = palette.comment
        outputCaptionLabel.textColor = palette.comment

        commandLabel.textColor = palette.foreground
        if outputLabel.stringValue.isEmpty {
            outputLabel.textColor = palette.foreground
        }

        errorBadgeLabel.textColor = palette.background
        errorBadgeLabel.layer?.backgroundColor = palette.red.cgColor
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let timelineCell = NSUserInterfaceItemIdentifier("OppiMacTimelineCell")
    static let timelineColumn = NSUserInterfaceItemIdentifier("OppiMacTimelineColumn")
}

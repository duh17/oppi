import AppKit
import SwiftUI

struct AppKitTimelineView: NSViewRepresentable {
    let rows: [OppiMacTimelineRow]
    let selectedID: String?
    let textScale: CGFloat
    let autoFollowTail: Bool
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> TimelineTableContainerView {
        let view = TimelineTableContainerView()
        view.onSelectionChange = { id in
            context.coordinator.onSelectionChange(id)
        }
        view.update(rows: rows, selectedID: selectedID, textScale: textScale, autoFollowTail: autoFollowTail)
        return view
    }

    func updateNSView(_ nsView: TimelineTableContainerView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        nsView.onSelectionChange = { id in
            context.coordinator.onSelectionChange(id)
        }
        nsView.update(rows: rows, selectedID: selectedID, textScale: textScale, autoFollowTail: autoFollowTail)
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
    private var autoFollowTail = true
    private var isNearBottom = true

    private var commandExpandedByRowKey: [String: Bool] = [:]
    private var outputExpandedByRowKey: [String: Bool] = [:]

    private let bottomFollowThreshold: CGFloat = 80

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

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
    }

    func update(rows: [OppiMacTimelineRow], selectedID: String?, textScale: CGFloat, autoFollowTail: Bool) {
        let clampedScale = min(max(textScale, 0.95), 1.55)
        let previousRowCount = self.rows.count
        let wasNearBottom = isNearBottom

        self.autoFollowTail = autoFollowTail

        let rowsChanged = self.rows != rows
        let scaleChanged = abs(self.textScale - clampedScale) > 0.0001

        if rowsChanged || scaleChanged {
            self.rows = rows
            self.textScale = clampedScale
            if rowsChanged {
                pruneExpansionState()
            }
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

        updateNearBottomState()

        if shouldAutoScrollToBottom(
            rowsChanged: rowsChanged,
            previousRowCount: previousRowCount,
            wasNearBottom: wasNearBottom
        ) {
            scrollToBottom()
            updateNearBottomState()
        }
    }

    private func setUpViews() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
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
        updateNearBottomState()
    }

    @objc private func handleScrollBoundsDidChange(_ notification: Notification) {
        _ = notification
        updateNearBottomState()
    }

    private func shouldAutoScrollToBottom(
        rowsChanged: Bool,
        previousRowCount: Int,
        wasNearBottom: Bool
    ) -> Bool {
        guard autoFollowTail else { return false }
        guard rowsChanged, !rows.isEmpty else { return false }

        if previousRowCount == 0 {
            return true
        }

        return wasNearBottom
    }

    private func updateNearBottomState() {
        guard let documentView = scrollView.documentView else {
            isNearBottom = true
            return
        }

        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentHeight = documentView.bounds.height
        let distanceToBottom = max(0, contentHeight - visibleMaxY)
        isNearBottom = distanceToBottom <= bottomFollowThreshold
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else {
            return
        }

        tableView.scrollRowToVisible(rows.count - 1)
    }

    private func rowKey(for row: OppiMacTimelineRow) -> String {
        row.toolCallId ?? row.id
    }

    private func pruneExpansionState() {
        let validKeys = Set(rows.map { rowKey(for: $0) })

        commandExpandedByRowKey = commandExpandedByRowKey.filter { validKeys.contains($0.key) }
        outputExpandedByRowKey = outputExpandedByRowKey.filter { validKeys.contains($0.key) }
    }

    private func commandExpanded(for row: OppiMacTimelineRow) -> Bool {
        let key = rowKey(for: row)
        if let expanded = commandExpandedByRowKey[key] {
            return expanded
        }

        let defaultValue = row.commandText != nil
        commandExpandedByRowKey[key] = defaultValue
        return defaultValue
    }

    private func outputExpanded(for row: OppiMacTimelineRow) -> Bool {
        let key = rowKey(for: row)
        if let expanded = outputExpandedByRowKey[key] {
            return expanded
        }

        let defaultValue: Bool
        if row.outputText == nil {
            defaultValue = false
        } else if row.isError {
            defaultValue = true
        } else if row.kind == .toolCall {
            defaultValue = false
        } else {
            defaultValue = true
        }

        outputExpandedByRowKey[key] = defaultValue
        return defaultValue
    }

    private func toggleCommandExpansion(for key: String) {
        let next = !(commandExpandedByRowKey[key] ?? false)
        commandExpandedByRowKey[key] = next
        reloadRows(forKey: key)
    }

    private func toggleOutputExpansion(for key: String) {
        let next = !(outputExpandedByRowKey[key] ?? false)
        outputExpandedByRowKey[key] = next
        reloadRows(forKey: key)
    }

    private func reloadRows(forKey key: String) {
        let indexes = rows.enumerated().compactMap { index, row in
            rowKey(for: row) == key ? index : nil
        }

        guard !indexes.isEmpty else { return }

        let rowIndexes = IndexSet(indexes)
        tableView.noteHeightOfRows(withIndexesChanged: rowIndexes)
        tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integer: 0))
    }

    private func estimatedHeight(for row: OppiMacTimelineRow) -> Double {
        var height = row.estimatedHeight

        if row.commandText != nil, !commandExpanded(for: row) {
            height -= 14
        }

        if row.outputText != nil, !outputExpanded(for: row) {
            height -= 30
        }

        return max(height, 54)
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
        let model = rows[row]
        let scaledHeight = estimatedHeight(for: model) * Double(textScale)
        return CGFloat(min(max(scaledHeight, 54), 300))
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
        let key = rowKey(for: model)
        let isCommandExpanded = commandExpanded(for: model)
        let isOutputExpanded = outputExpanded(for: model)

        rowView.onToggleCommand = { [weak self] rowKey in
            self?.toggleCommandExpansion(for: rowKey)
        }
        rowView.onToggleOutput = { [weak self] rowKey in
            self?.toggleOutputExpansion(for: rowKey)
        }

        rowView.configure(
            model,
            textScale: textScale,
            rowKey: key,
            isCommandExpanded: isCommandExpanded,
            isOutputExpanded: isOutputExpanded
        )
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

        let selectionRect = bounds.insetBy(dx: 6, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8).fill()

        NSColor.controlAccentColor.withAlphaComponent(0.24).setStroke()
        let border = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        // Use spacing + subtle card styles instead of fixed separators.
    }
}

private final class TimelineTableCellView: NSTableCellView {
    var onToggleCommand: ((String) -> Void)?
    var onToggleOutput: ((String) -> Void)?

    private let cardView = NSView()

    private let iconView = NSImageView()
    private let kindTagLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let toolCallIdLabel = NSTextField(labelWithString: "")
    private let errorBadgeLabel = NSTextField(labelWithString: "ERROR")

    private let subtitleLabel = NSTextField(labelWithString: "")

    private let commandToggleButton = NSButton(title: "Command", target: nil, action: nil)
    private let commandContainer = NSView()
    private let commandLabel = NSTextField(labelWithString: "")

    private let outputToggleButton = NSButton(title: "Output", target: nil, action: nil)
    private let outputContainer = NSView()
    private let outputLabel = NSTextField(labelWithString: "")

    private var currentScale: CGFloat = 1.15
    private var currentKind: ReviewTimelineKind = .system
    private var currentIsError = false

    private var currentRowKey: String?
    private var currentCommandCaption = "Command"
    private var currentOutputCaption = "Output"
    private var isCommandExpanded = true
    private var isOutputExpanded = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func configure(
        _ row: OppiMacTimelineRow,
        textScale: CGFloat,
        rowKey: String,
        isCommandExpanded: Bool,
        isOutputExpanded: Bool
    ) {
        currentScale = min(max(textScale, 0.95), 1.55)
        currentKind = row.kind
        currentIsError = row.isError

        currentRowKey = rowKey
        self.isCommandExpanded = isCommandExpanded
        self.isOutputExpanded = isOutputExpanded

        kindTagLabel.stringValue = kindTag(for: row.kind)
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
            currentCommandCaption = row.commandCaption
            commandToggleButton.title = disclosureTitle(caption: row.commandCaption, expanded: isCommandExpanded)
            commandToggleButton.isHidden = false
            commandContainer.isHidden = false
            commandLabel.stringValue = isCommandExpanded
                ? commandText
                : collapsedCommandPreview(from: commandText)
        } else {
            currentCommandCaption = "Command"
            commandToggleButton.title = disclosureTitle(caption: currentCommandCaption, expanded: true)
            commandToggleButton.isHidden = true
            commandContainer.isHidden = true
            commandLabel.stringValue = ""
        }

        if let outputText = row.outputText {
            currentOutputCaption = row.outputCaption
            outputToggleButton.title = disclosureTitle(caption: row.outputCaption, expanded: isOutputExpanded)
            outputToggleButton.isHidden = false
            outputContainer.isHidden = false

            let visibleOutputText = isOutputExpanded
                ? outputText
                : collapsedOutputPreview(from: outputText)
            outputLabel.stringValue = visibleOutputText
            outputLabel.textColor = row.isError ? OppiMacTheme.current.red : OppiMacTheme.current.foreground
        } else {
            currentOutputCaption = "Output"
            outputToggleButton.title = disclosureTitle(caption: currentOutputCaption, expanded: true)
            outputToggleButton.isHidden = true
            outputContainer.isHidden = true
            outputLabel.stringValue = ""
            outputLabel.textColor = OppiMacTheme.current.foreground
        }

        applyTypography()
        applyTheme()
    }

    private func setUpViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 8
        cardView.layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        kindTagLabel.translatesAutoresizingMaskIntoConstraints = false
        kindTagLabel.alignment = .center
        kindTagLabel.wantsLayer = true
        kindTagLabel.layer?.cornerRadius = 5
        kindTagLabel.layer?.masksToBounds = true
        kindTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        commandToggleButton.translatesAutoresizingMaskIntoConstraints = false
        commandToggleButton.setButtonType(.momentaryPushIn)
        commandToggleButton.bezelStyle = .inline
        commandToggleButton.isBordered = false
        commandToggleButton.alignment = .left
        commandToggleButton.target = self
        commandToggleButton.action = #selector(handleCommandToggle)

        commandContainer.translatesAutoresizingMaskIntoConstraints = false
        commandContainer.wantsLayer = true
        commandContainer.layer?.cornerRadius = 6
        commandContainer.layer?.masksToBounds = true

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.cell?.wraps = true
        commandLabel.cell?.usesSingleLineMode = false

        outputToggleButton.translatesAutoresizingMaskIntoConstraints = false
        outputToggleButton.setButtonType(.momentaryPushIn)
        outputToggleButton.bezelStyle = .inline
        outputToggleButton.isBordered = false
        outputToggleButton.alignment = .left
        outputToggleButton.target = self
        outputToggleButton.action = #selector(handleOutputToggle)

        outputContainer.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.wantsLayer = true
        outputContainer.layer?.cornerRadius = 6
        outputContainer.layer?.masksToBounds = true

        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.lineBreakMode = .byWordWrapping
        outputLabel.cell?.wraps = true
        outputLabel.cell?.usesSingleLineMode = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [iconView, kindTagLabel, titleLabel, spacer, errorBadgeLabel, timestampLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 7

        let metaRow = NSStackView(views: [toolCallIdLabel])
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 6

        let bodyStack = NSStackView(views: [
            subtitleLabel,
            metaRow,
            commandToggleButton,
            commandContainer,
            outputToggleButton,
            outputContainer,
        ])
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.distribution = .fill
        bodyStack.spacing = 5

        let containerStack = NSStackView(views: [headerStack, bodyStack])
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.distribution = .fill
        containerStack.spacing = 6

        commandContainer.addSubview(commandLabel)
        outputContainer.addSubview(outputLabel)

        cardView.addSubview(containerStack)
        addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            containerStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            containerStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            containerStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            containerStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -8),

            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8),

            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            kindTagLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),

            commandToggleButton.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
            outputToggleButton.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
            commandContainer.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
            outputContainer.widthAnchor.constraint(equalTo: containerStack.widthAnchor),

            commandLabel.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 9),
            commandLabel.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -9),
            commandLabel.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: 7),
            commandLabel.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -7),

            outputLabel.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor, constant: 9),
            outputLabel.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor, constant: -9),
            outputLabel.topAnchor.constraint(equalTo: outputContainer.topAnchor, constant: 7),
            outputLabel.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor, constant: -7),
        ])

        applyTypography()
        applyTheme()
    }

    @objc private func handleCommandToggle() {
        guard let currentRowKey else { return }
        onToggleCommand?(currentRowKey)
    }

    @objc private func handleOutputToggle() {
        guard let currentRowKey else { return }
        onToggleOutput?(currentRowKey)
    }

    private func collapsedCommandPreview(from text: String) -> String {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count > 180 else {
            return compact
        }

        return String(compact.prefix(179)) + "…"
    }

    private func collapsedOutputPreview(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.count > 3 else {
            return normalized
        }

        return lines.prefix(3).joined(separator: "\n") + "\n…"
    }

    private func disclosureTitle(caption: String, expanded: Bool) -> String {
        let chevron = expanded ? "▾" : "▸"
        return "\(chevron) \(caption)"
    }

    private func applyTypography() {
        let scale = currentScale

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11 * scale,
            weight: .semibold
        )

        kindTagLabel.font = .monospacedSystemFont(ofSize: 9 * scale, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12 * scale, weight: .regular)

        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 10 * scale, weight: .regular)
        toolCallIdLabel.font = .monospacedSystemFont(ofSize: 10 * scale, weight: .regular)

        commandLabel.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        outputLabel.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)

        errorBadgeLabel.font = .systemFont(ofSize: 9 * scale, weight: .bold)
    }

    private func applyTheme() {
        let palette = OppiMacTheme.current
        let kindColor = OppiMacTheme.iconColor(for: currentKind)

        cardView.layer?.cornerRadius = 8

        let isToolBlock = currentKind == .toolCall || currentKind == .toolResult
        let isMetaBlock = currentKind == .system || currentKind == .compaction || currentKind == .thinking

        if isToolBlock {
            cardView.layer?.backgroundColor = palette.backgroundSecondary.withAlphaComponent(0.55).cgColor
            cardView.layer?.borderWidth = 1
            cardView.layer?.borderColor = palette.comment.withAlphaComponent(0.20).cgColor
        } else if isMetaBlock {
            cardView.layer?.backgroundColor = palette.backgroundSecondary.withAlphaComponent(0.38).cgColor
            cardView.layer?.borderWidth = 1
            cardView.layer?.borderColor = palette.comment.withAlphaComponent(0.14).cgColor
        } else {
            cardView.layer?.backgroundColor = NSColor.clear.cgColor
            cardView.layer?.borderWidth = 0
            cardView.layer?.borderColor = NSColor.clear.cgColor
        }

        commandContainer.layer?.backgroundColor = palette.background.cgColor
        commandContainer.layer?.borderWidth = 1
        commandContainer.layer?.borderColor = palette.comment.withAlphaComponent(0.16).cgColor

        outputContainer.layer?.backgroundColor = palette.background.cgColor
        outputContainer.layer?.borderWidth = 1
        if currentIsError {
            outputContainer.layer?.borderColor = palette.red.withAlphaComponent(0.35).cgColor
        } else {
            outputContainer.layer?.borderColor = palette.comment.withAlphaComponent(0.16).cgColor
        }

        kindTagLabel.textColor = kindColor
        kindTagLabel.layer?.backgroundColor = kindColor.withAlphaComponent(0.14).cgColor
        kindTagLabel.layer?.borderWidth = 1
        kindTagLabel.layer?.borderColor = kindColor.withAlphaComponent(0.24).cgColor

        titleLabel.textColor = palette.foreground
        subtitleLabel.textColor = palette.foregroundDim
        timestampLabel.textColor = palette.comment

        toolCallIdLabel.textColor = palette.comment

        commandLabel.textColor = palette.foreground
        if outputLabel.stringValue.isEmpty {
            outputLabel.textColor = palette.foreground
        }

        errorBadgeLabel.textColor = palette.background
        errorBadgeLabel.layer?.backgroundColor = palette.red.cgColor

        let disclosureFont = NSFont.monospacedSystemFont(ofSize: 10 * currentScale, weight: .semibold)
        let disclosureAttributes: [NSAttributedString.Key: Any] = [
            .font: disclosureFont,
            .foregroundColor: palette.comment,
        ]

        commandToggleButton.attributedTitle = NSAttributedString(
            string: commandToggleButton.title,
            attributes: disclosureAttributes
        )
        outputToggleButton.attributedTitle = NSAttributedString(
            string: outputToggleButton.title,
            attributes: disclosureAttributes
        )
    }

    private func kindTag(for kind: ReviewTimelineKind) -> String {
        switch kind {
        case .user:
            return "USER"
        case .assistant:
            return "ASSIST"
        case .thinking:
            return "THINK"
        case .toolCall:
            return "TOOL"
        case .toolResult:
            return "OUTPUT"
        case .system:
            return "SYSTEM"
        case .compaction:
            return "COMPACT"
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let timelineCell = NSUserInterfaceItemIdentifier("OppiMacTimelineCell")
    static let timelineColumn = NSUserInterfaceItemIdentifier("OppiMacTimelineColumn")
}

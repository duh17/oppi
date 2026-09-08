import SwiftUI

/// Table + source for CSV/TSV files. Not a sheet. Document column stays the reading surface.
struct MacDelimitedTablePreviewView: View {
    private enum Mode: String, Hashable {
        case table
        case source
    }

    let plan: DelimitedTableViewerPlan
    var fillsColumn: Bool = false
    var filePath: String? = nil

    @State private var mode: Mode = .table
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            truncationBanner
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsColumn ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(plan.kind.fileType.displayLabel, systemImage: "tablecells")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(theme.text.secondary)
            Spacer(minLength: 8)
            Picker("Display", selection: $mode) {
                Text("Table").tag(Mode.table)
                Text("Source").tag(Mode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier(modeAccessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var truncationBanner: some View {
        if let summary = plan.truncationSummary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(theme.text.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if mode == .table {
            tableView
                .frame(maxWidth: .infinity, minHeight: fillsColumn ? 240 : 160)
                .frame(maxHeight: fillsColumn ? .infinity : 400)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(plan.source.isEmpty ? " " : plan.source)
                    .font(Font(FontPreferenceStore.macCodeFont()))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityLabel(filePath ?? plan.kind.fileType.displayLabel)
            }
            .frame(maxHeight: fillsColumn ? .infinity : 400)
        }
    }

    @ViewBuilder
    private var tableView: some View {
        if plan.table.displayedRowCount == 0 {
            Text("Empty table")
                .font(.caption)
                .foregroundStyle(theme.text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView([.vertical, .horizontal]) {
                grid
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.markdown.codeBlockBorder, lineWidth: 1)
                    }
            }
        }
    }

    private var grid: some View {
        let columns = max(plan.table.columnCount, 1)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(padded(plan.table.headers, to: columns).enumerated()), id: \.offset) { _, header in
                    Text(header)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }
            }
            GridRow {
                Rectangle()
                    .fill(theme.markdown.hr)
                    .frame(height: 1)
                    .gridCellColumns(columns)
            }
            ForEach(Array(plan.table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(padded(row, to: columns).enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func padded(_ cells: [String], to count: Int) -> [String] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private var containerAccessibilityIdentifier: String {
        fillsColumn ? "mac.documentColumn.table" : "mac.timeline.table"
    }

    private var modeAccessibilityIdentifier: String {
        fillsColumn ? "mac.documentColumn.table.mode" : "mac.timeline.table.mode"
    }
}

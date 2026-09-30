import UIKit

/// A file the app renders natively as a document instead of text or Markdown:
/// a CSV/TSV table or a GeoJSON/TopoJSON map. It carries the file's source text
/// and optional path, and answers every question the tool row, the full-screen
/// reader and export ask about those two kinds.
///
/// This file is the one composition point. Callers hold a `DocumentFamily` (as
/// `ToolExpandedContent.document` or `FullScreenCodeContent.document`) and ask it
/// for facts, views or export content; none of them branches on the kind. Adding
/// a document format means one more case here, and the compiler then points at
/// every `switch` in this file that needs it. Call sites that only forward a
/// `.document` value do not change.
///
/// The rendered-fence path (Mermaid, maps, LaTeX in assistant Markdown) does not
/// go through this type: its segments load, measure and update through their own
/// per-fence lifecycles.
enum DocumentFamily: Equatable {
    case delimitedTable(text: String, filePath: String?)
    case geoJSON(text: String, filePath: String?)

    /// The family that renders `fileType`, or nil when it is not a document
    /// format. Exhaustive so a new `FileType` forces a decision here.
    init?(fileType: FileType, text: String, filePath: String?) {
        switch fileType {
        case .csv, .tsv:
            self = .delimitedTable(text: text, filePath: filePath)
        case .geojson, .topojson:
            self = .geoJSON(text: text, filePath: filePath)
        case .markdown, .html, .code, .json, .image, .audio, .video, .pdf, .usdz,
             .binary, .plain, .latex, .orgMode, .mermaid, .graphviz:
            return nil
        }
    }

    var text: String {
        switch self {
        case .delimitedTable(let text, _), .geoJSON(let text, _):
            return text
        }
    }

    var filePath: String? {
        switch self {
        case .delimitedTable(_, let filePath), .geoJSON(_, let filePath):
            return filePath
        }
    }

    /// Stable label for change detection and perf telemetry.
    var kindName: String {
        switch self {
        case .delimitedTable: return "delimitedTable"
        case .geoJSON: return "geoJSON"
        }
    }

    // MARK: - Tool row traits

    /// What the expanded tool row needs to know about a hosted document. Every
    /// family scrolls itself inside the capped viewport, takes tap/pinch
    /// activation and opens full screen, so only the height floor varies.
    struct InlineTraits: Equatable {
        /// Smallest height the hosted view may measure to inside the capped viewport.
        let minViewportHeight: CGFloat
    }

    var inline: InlineTraits {
        switch self {
        case .delimitedTable:
            return InlineTraits(minViewportHeight: 1)
        case .geoJSON:
            return InlineTraits(minViewportHeight: 180)
        }
    }

    // MARK: - Full-screen reader traits

    /// Content the reader shows when the user toggles to Source.
    var sourceContent: FullScreenCodeContent {
        switch self {
        case .delimitedTable(let text, let filePath):
            return .plainText(content: text, filePath: filePath)
        case .geoJSON(let text, let filePath):
            return .code(content: text, language: "json", filePath: filePath, startLine: 1)
        }
    }

    func sourceToggleTitle(showingSource: Bool) -> String {
        switch self {
        case .delimitedTable:
            return showingSource ? String(localized: "Table") : String(localized: "Source")
        case .geoJSON:
            return showingSource ? String(localized: "Rendered") : String(localized: "Source")
        }
    }

    /// Reader-preference family; nil when the rendered view ignores preferences.
    var readerFamily: FullScreenReaderContentFamily? {
        switch self {
        case .delimitedTable: return .renderedDocument
        case .geoJSON: return nil
        }
    }

    // MARK: - Export

    func shareableContent(fileName: String?) -> FileShareService.ShareableContent {
        switch self {
        case .delimitedTable(let text, _): return .plainText(text, fileName: fileName)
        case .geoJSON(let text, _): return .json(text, fileName: fileName)
        }
    }

    // MARK: - iOS factory

    /// The view for the tool row's hosted surface, or nil when `existing` already
    /// displays this document (same source, and for tables the same theme), so the
    /// caller keeps it. The parse plan is resolved once for both the check and
    /// the new view.
    @MainActor
    func makeInlineView(itemID: String, reusing existing: UIView?) -> UIView? {
        switch self {
        case .delimitedTable(let text, let filePath):
            let plan = DelimitedTableViewerPlan.resolved(path: filePath, text: text)
            if let table = existing as? DelimitedTableRenderView, table.displays(plan) {
                return nil
            }
            let view = DelimitedTableRenderView(plan: plan)
            view.accessibilityIdentifier = "chat.timeline.row.\(itemID).delimitedTable"
            return view

        case .geoJSON(let text, let filePath):
            let plan = GeoJSONViewerPlan.resolved(path: filePath, text: text)
            if let map = existing as? GeoJSONMapView, map.displays(plan) {
                return nil
            }
            let view = GeoJSONMapView(plan: plan)
            view.accessibilityIdentifier = "chat.timeline.row.\(itemID).geojson"
            return view
        }
    }

    /// The rendered body the full-screen reader installs.
    @MainActor
    func makeFullScreenBody(
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences
    ) -> UIView {
        switch self {
        case .delimitedTable(let text, let filePath):
            let view = DelimitedTableRenderView(
                plan: DelimitedTableViewerPlan.resolved(path: filePath, text: text),
                palette: palette
            )
            view.applyReaderPreferences(readerPreferences)
            view.accessibilityIdentifier = "full-screen.delimited-table.body"
            return view

        case .geoJSON(let text, let filePath):
            let view = GeoJSONMapView(
                plan: GeoJSONViewerPlan.resolved(path: filePath, text: text)
            )
            view.applyReaderPreferences(readerPreferences)
            view.accessibilityIdentifier = "full-screen.geojson.body"
            return view
        }
    }
}

import Foundation
import XCTest

/// Prints an XCUI accessibility snapshot and audit as markdown for agent review.
///
/// This is a printer, not a golden. Frames and empty `Other` leaves are omitted.
@MainActor
enum UIValidateDump {
    struct AuditIssue: Sendable {
        let type: String
        let compact: String
        let detailed: String
        let element: String
        /// Why this issue is a known audit false positive; nil for a real finding.
        var waivedReason: String? = nil
    }

    static func renderTree(_ snapshot: XCUIElementSnapshot) -> String {
        var lines = ["# accessibility tree", ""]
        lines.append(contentsOf: renderNode(snapshot, depth: 0))
        if lines.last == "" {
            lines.append("- (empty)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func renderAudit(_ issues: [AuditIssue]) -> String {
        var lines = ["# accessibility audit", ""]
        let findings = issues.filter { $0.waivedReason == nil }
        let waived = issues.filter { $0.waivedReason != nil }
        if findings.isEmpty {
            lines.append("No accessibility audit issues.")
        }
        for issue in findings {
            lines.append(contentsOf: renderIssue(issue))
        }
        // Waived issues stay visible so a reviewer can still judge them.
        if !waived.isEmpty {
            lines.append("")
            lines.append("## Waived (known audit false positives)")
            lines.append("")
            for issue in waived {
                lines.append(contentsOf: renderIssue(issue))
                if let reason = issue.waivedReason {
                    lines.append("  Waived: \(reason)")
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func renderIssue(_ issue: AuditIssue) -> [String] {
        var head = "- \(issue.type)"
        if !issue.element.isEmpty {
            head += ": \(issue.element)"
        }
        var lines = [head]
        if !issue.compact.isEmpty {
            lines.append("  \(issue.compact)")
        }
        if !issue.detailed.isEmpty, issue.detailed != issue.compact {
            lines.append("  \(issue.detailed)")
        }
        return lines
    }

    static func write(
        directory: URL,
        screen: String,
        tree: String,
        audit: String,
        screenshot: XCUIScreenshot
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeUTF8(tree, to: directory.appendingPathComponent("tree.md"))
        try writeUTF8(audit, to: directory.appendingPathComponent("audit.md"))
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("screen.png"))

        let manifest = """
        {
          "screen": \(jsonString(screen)),
          "writtenAt": \(jsonString(ISO8601DateFormatter().string(from: Date()))),
          "files": ["tree.md", "audit.md", "screen.png"]
        }
        """
        try writeUTF8(manifest, to: directory.appendingPathComponent("manifest.json"))
    }

    static func collectAuditIssues(from app: XCUIApplication) -> [AuditIssue] {
        final class IssueBox: @unchecked Sendable {
            var issues: [AuditIssue] = []
            /// `<preview>|<type>` of each element-less issue already waived: only the first of
            /// a kind is, so a second one is a finding.
            var elementlessWaived: Set<String> = []
        }
        let box = IssueBox()
        let previewFrames = ["sessionRows.preview", "sessionRows.preview.label"].compactMap { identifier -> CGRect? in
            let element = app.descendants(matching: .any)[identifier]
            return element.exists ? element.frame : nil
        }
        let sampledPreviews = SampledPreview.all.compactMap { preview -> (identifier: String, frame: CGRect, reason: String)? in
            let element = app.descendants(matching: .any)[preview.identifier]
            return element.exists ? (preview.identifier, element.frame, preview.reason) : nil
        }
        // The Extensions rows: each cell's label reads "<name>, <detail>".
        let extensionRows = app.collectionViews["workspace.edit.extensions.list"].cells.allElementsBoundByIndex
            .filter { $0.exists && $0.identifier.isEmpty }
            .map { (label: $0.label, frame: $0.frame) }
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                box.issues.append(
                    AuditIssue(
                        type: auditTypeName(issue.auditType),
                        compact: issue.compactDescription,
                        detailed: issue.detailedDescription,
                        element: describeElement(issue.element),
                        waivedReason: waivedReason(
                            for: issue, previewFrames: previewFrames, sampledPreviews: sampledPreviews,
                            extensionRows: extensionRows, elementlessWaived: &box.elementlessWaived
                        )
                    )
                )
                return true
            }
        } catch {
            box.issues.append(
                AuditIssue(
                    type: "audit-error",
                    compact: String(describing: error),
                    detailed: "",
                    element: ""
                )
            )
        }
        return box.issues
    }

    private static func renderNode(_ snapshot: XCUIElementSnapshot, depth: Int) -> [String] {
        let children = snapshot.children
        let identifier = snapshot.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmptyOther = snapshot.elementType == .other
            && identifier.isEmpty
            && label.isEmpty

        var lines: [String] = []
        if !(isEmptyOther && children.isEmpty) {
            if !(isEmptyOther && children.count == 1) {
                lines.append(String(repeating: "  ", count: depth) + "- " + nodeLine(snapshot))
            }
        }

        let childDepth = (isEmptyOther && children.count == 1) ? depth : depth + (lines.isEmpty ? 0 : 1)
        let nextDepth = lines.isEmpty ? depth : childDepth
        for child in children {
            lines.append(contentsOf: renderNode(child, depth: nextDepth))
        }
        return lines
    }

    private static func nodeLine(_ snapshot: XCUIElementSnapshot) -> String {
        var parts = [roleName(snapshot.elementType)]
        let identifier = snapshot.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty {
            parts.append("id=\(identifier)")
        }
        let label = snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            parts.append("\"\(escape(label))\"")
        }
        if let value = snapshot.value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != label {
                parts.append("value=\(escape(trimmed))")
            }
        }
        if !snapshot.isEnabled {
            parts.append("disabled")
        }
        if snapshot.isSelected {
            parts.append("selected")
        }
        return parts.joined(separator: " ")
    }

    private static func roleName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "application"
        case .window: return "window"
        case .group: return "group"
        case .other: return "other"
        case .button: return "button"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .textView: return "textView"
        case .secureTextField: return "secureTextField"
        case .image: return "image"
        case .scrollView: return "scrollView"
        case .collectionView: return "collectionView"
        case .table: return "table"
        case .cell: return "cell"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .toolbar: return "toolbar"
        case .searchField: return "searchField"
        case .switch: return "switch"
        case .slider: return "slider"
        case .link: return "link"
        case .webView: return "webView"
        case .alert: return "alert"
        case .sheet: return "sheet"
        case .dialog: return "dialog"
        case .toggle: return "toggle"
        default: return "type(\(type.rawValue))"
        }
    }

    private static func describeElement(_ element: XCUIElement?) -> String {
        guard let element else { return "" }
        var parts = [roleName(element.elementType)]
        if !element.identifier.isEmpty {
            parts.append("id=\(element.identifier)")
        }
        if !element.label.isEmpty {
            parts.append("\"\(escape(element.label))\"")
        }
        return parts.joined(separator: " ")
    }

    /// The audit reports `textClipped` on the system `UISearchTextField` placeholder
    /// on every `ScreenSearchController` screen, at the default text size too, while
    /// the screenshots draw it in full at every size. The field is UIKit's own.
    ///
    /// The Session Rows editor's preview draws `SessionRowView` over sample data. The audit
    /// reports known debt there: the dimmed labels' `contrast`, fixed-size `dynamicType` labels,
    /// `hitRegion` of non-interactive subviews, the cost label's `sufficientElementDescription`,
    /// and `textClipped` of the row and the "PREVIEW · SAMPLE DATA" label at accessibility sizes.
    /// Only issues whose element sits inside the preview's frames are waived; the editor and
    /// `SessionRowView` are unchanged since 7665a92f0.
    ///
    /// The Workspace Extensions rows draw their detail line (where the extension lives) in the
    /// monospaced design through `UIFont.scaledMonospaced`, which scales through
    /// `UIFontMetrics(forTextStyle:)` like every other label; the audit reports `dynamicType` on it
    /// anyway. Only a static text inside a row of that list whose label is the row's detail is waived.
    ///
    /// Two settings previews draw real app text the audit misreads (`SampledPreview`): Voice's
    /// mic mark, which scales with a cap inside its disc, and Text's code sample, which is
    /// fixed-size on purpose. The audit
    /// finds their text by looking at the screen, so it often reports `dynamicType`
    /// or `elementDetection` without an element. Those two types are waived on a page
    /// only while its preview is on screen. An issue that names an element is waived
    /// only when the element sits inside the preview's frame; an element-less one is
    /// waived once per type per preview per dump, and a second is a finding. The reason
    /// is in the waiver text; the rest of the page is audited as everywhere else.
    private static func waivedReason(
        for issue: XCUIAccessibilityAuditIssue,
        previewFrames: [CGRect],
        sampledPreviews: [(identifier: String, frame: CGRect, reason: String)],
        extensionRows: [(label: String, frame: CGRect)],
        elementlessWaived: inout Set<String>
    ) -> String? {
        if issue.auditType == .textClipped, issue.element?.elementType == .searchField {
            return "textClipped on the system search field, which draws its text in full"
        }
        if issue.auditType == .dynamicType,
           let element = issue.element, element.elementType == .staticText,
           extensionRows.contains(where: {
               $0.label.hasSuffix(", \(element.label)") && $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame)
           }) {
            return "UIFontMetrics-scaled monospaced detail; audit misreads the monospaced design"
        }
        if issue.auditType == .dynamicType || issue.auditType == .elementDetection {
            for preview in sampledPreviews {
                if let element = issue.element {
                    if preview.frame.insetBy(dx: -1, dy: -1).contains(element.frame) {
                        return "\(auditTypeName(issue.auditType)) on a preview: \(preview.reason)"
                    }
                } else if elementlessWaived.insert("\(preview.identifier)|\(auditTypeName(issue.auditType))").inserted {
                    return "\(auditTypeName(issue.auditType)) on a preview: \(preview.reason)"
                }
            }
        }
        if [.dynamicType, .textClipped, .hitRegion, .sufficientElementDescription, .contrast].contains(issue.auditType),
           let frame = issue.element?.frame,
           previewFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) }) {
            return "\(auditTypeName(issue.auditType)) in the Session Rows preview: known debt in SessionRowView "
                + "(dimmed-label contrast, fixed-size labels) and the \"PREVIEW · SAMPLE DATA\" label clipping, "
                + "not a sample-data artifact; the editor is unchanged since 7665a92f0"
        }
        return nil
    }

    /// A settings preview whose text is fixed-size by design.
    private struct SampledPreview {
        let identifier: String
        let reason: String

        static let all = [
            SampledPreview(
                identifier: "settings.voice.micPreview",
                reason: "the mic's \"EN\" grows with Dynamic Type up to half the 44 pt disc "
                    + "(MicButtonChromeView.languageMarkFont: a scaled system font with a cap, exact at the standard "
                    + "size). The audit flags it at the standard size only and finds nothing at AX5; the row's label "
                    + "names the preview"
            ),
            SampledPreview(
                identifier: "settings.text.preview.code",
                reason: "the code sample deliberately follows Code Text Size, not Dynamic Type, as code does in chat"
            ),
        ]
    }

    private static func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contrast"
        case .dynamicType: return "dynamicType"
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .textClipped: return "textClipped"
        case .trait: return "trait"
        case .all: return "all"
        default: return "audit(\(type.rawValue))"
        }
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func jsonString(_ value: String) -> String {
        "\"\(escape(value))\""
    }

    private static func writeUTF8(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: "UIValidateDump",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode \(url.lastPathComponent)"]
            )
        }
        try data.write(to: url, options: .atomic)
    }
}

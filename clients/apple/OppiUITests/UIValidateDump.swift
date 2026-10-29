import Foundation
import XCTest

/// Prints an XCUI accessibility snapshot as markdown for agent review, and optionally Apple's
/// automation-relevant accessibility audit (`OPPI_UI_VALIDATE_AUDIT=1`).
///
/// This is a printer, not a golden. Frames and empty `Other` leaves are omitted.
@MainActor
enum UIValidateDump {
    struct AuditIssue: Sendable {
        let type: String
        let compact: String
        let detailed: String
        let element: String
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
        if issues.isEmpty {
            lines.append("No accessibility audit issues.")
        }
        for issue in issues {
            lines.append(contentsOf: renderIssue(issue))
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

    /// Writes `tree.md`, `screen.png`, `manifest.json`, and `audit.md` when `audit` is non-nil.
    static func write(
        directory: URL,
        screen: String,
        tree: String,
        audit: String?,
        screenshot: XCUIScreenshot
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auditURL = directory.appendingPathComponent("audit.md")
        try writeUTF8(tree, to: directory.appendingPathComponent("tree.md"))
        if let audit {
            try writeUTF8(audit, to: auditURL)
        } else {
            // A directory reused from an audited run must not keep a stale audit.md.
            try? FileManager.default.removeItem(at: auditURL)
        }
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("screen.png"))

        let files = (["tree.md"] + (audit == nil ? [] : ["audit.md"]) + ["screen.png"])
            .map(jsonString).joined(separator: ", ")
        let manifest = """
        {
          "screen": \(jsonString(screen)),
          "writtenAt": \(jsonString(ISO8601DateFormatter().string(from: Date()))),
          "files": [\(files)]
        }
        """
        try writeUTF8(manifest, to: directory.appendingPathComponent("manifest.json"))
    }

    /// The audit types that bear on automation. `dynamicType`, `textClipped`, and `contrast` are
    /// visual accessibility, which is not an Oppi validation target (AGENTS.md).
    private static let auditTypes: XCUIAccessibilityAuditType = [
        .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
    ]

    static func collectAuditIssues(from app: XCUIApplication) -> [AuditIssue] {
        final class IssueBox: @unchecked Sendable {
            var issues: [AuditIssue] = []
        }
        let box = IssueBox()
        do {
            try app.performAccessibilityAudit(for: auditTypes) { issue in
                box.issues.append(
                    AuditIssue(
                        type: auditTypeName(issue.auditType),
                        compact: issue.compactDescription,
                        detailed: issue.detailedDescription,
                        element: describeElement(issue.element)
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
        let frame = element.frame
        parts.append("@(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
        return parts.joined(separator: " ")
    }

    private static func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .trait: return "trait"
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

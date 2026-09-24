import Foundation

/// DOM-only review anchor. This is not a generalized semantic target and does
/// not claim an original source line. The loaded source hash identifies the
/// HTML string Oppi loaded, not the live DOM.
struct HTMLDOMElementAnchor: Codable, Sendable, Equatable {
    var sourceSHA256: String
    var navigationGeneration: UInt64
    var sessionId: String
    var filePath: String?
    var readableLabel: String
    var sanitizedText: String
    var locatorDescription: String
    var fingerprint: String
    var limitation: String?
    var lookupScope: String

    static let mainFrameAndOpenShadowScope = "main-frame-and-open-shadow-roots"

    func promptLines() -> [String] {
        var lines = ["**Rendered element:** \(readableLabel)"]
        // Page-order context, when needed, is included in readableLabel at
        // selection time. The private DOM locator is never rendered as prose.
        if let limitation, !limitation.isEmpty {
            lines.append("**Lookup limitation:** \(Self.limitationText(limitation))")
        }
        // The source hash, fingerprint, and locator remain on the persisted
        // anchor for freshness checks; they are not useful prose for a reviewer.
        let text = sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != readableLabel {
            lines.append("**Visible text:** \(text)")
        }
        return lines
    }

    private static func limitationText(_ raw: String) -> String {
        switch raw {
        case "embeddedFrame":
            return "Embedded frame. The comment is on the frame element, not the inner document."
        case "closedShadowHost":
            return "Closed shadow root or custom-element container. Inner content was not inspected."
        default:
            return raw
        }
    }
}

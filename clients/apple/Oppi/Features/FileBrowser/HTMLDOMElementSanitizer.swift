import CryptoKit
import CoreGraphics
import Foundation

enum HTMLDOMSourceIdentity {
    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum HTMLDOMLookupLimitation: String, Equatable, Sendable {
    case embeddedFrame
    case closedShadowHost
}

struct HTMLDOMLocatorStep: Equatable, Sendable {
    var tag: String
    var siblingIndex: Int
    var entersOpenShadow: Bool

    var canonical: String {
        "\(tag):\(siblingIndex):\(entersOpenShadow ? 1 : 0)"
    }
}

struct HTMLDOMViewportMetrics: Equatable, Sendable {
    var pageZoom: CGFloat
    var scrollZoomScale: CGFloat
    var visualViewportScale: CGFloat
    var visualViewportOffset: CGPoint
    /// Native inset between the WKWebView bounds and its CSS viewport origin.
    var viewportOriginInView: CGPoint
    var contentOffset: CGPoint

    /// View points per CSS viewport pixel. Depending on the WebKit path, page
    /// zoom can remain separate or be reflected inversely in the reported
    /// scroll/visual scale, while pinch contributes a non-unit scale.
    var viewPointsPerCSSPixel: CGFloat {
        let page = pageZoom > 0 ? pageZoom : 1
        let nativeScale = (scrollZoomScale > 0 ? scrollZoomScale : 1) * page
        if abs(nativeScale - 1) > 0.001 {
            return nativeScale
        }
        let visualScale = (visualViewportScale > 0 ? visualViewportScale : 1) * page
        return visualScale > 0 ? visualScale : 1
    }
}

enum HTMLDOMViewportMapping {
    /// View points are viewport-relative, matching `elementFromPoint` and
    /// `getBoundingClientRect`. Scroll is already reflected there, including
    /// while UIScrollView pinch zoom is active, so content offset is not added.
    static func cssViewportPoint(fromViewPoint point: CGPoint, metrics: HTMLDOMViewportMetrics) -> CGPoint {
        let scale = metrics.viewPointsPerCSSPixel
        return CGPoint(
            x: (point.x - metrics.viewportOriginInView.x) / scale,
            y: (point.y - metrics.viewportOriginInView.y) / scale
        )
    }

    static func viewRect(fromCSSViewportRect rect: CGRect, metrics: HTMLDOMViewportMetrics) -> CGRect {
        let scale = metrics.viewPointsPerCSSPixel
        return CGRect(
            x: metrics.viewportOriginInView.x + rect.origin.x * scale,
            y: metrics.viewportOriginInView.y + rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

enum HTMLDOMSelectionRejection: Error, Equatable, Sendable {
    case staleGeneration
    case sessionMismatch
    case sourceHashMismatch
    case disconnected
    case fingerprintMismatch
    case payloadTooLarge
    case invalidPayload
    case lookupFailed
    case noElement
    case notReady

    var userMessage: String {
        switch self {
        case .staleGeneration, .sourceHashMismatch:
            return "The page reloaded. Pick the element again. Nothing was saved."
        case .sessionMismatch:
            return "This comment is no longer attached to the same session. Nothing was saved."
        case .disconnected, .fingerprintMismatch:
            return "That element changed or is gone. Pick it again. Nothing was saved."
        case .payloadTooLarge:
            return "Element description is too large to comment on. Nothing was saved."
        case .invalidPayload, .lookupFailed, .noElement:
            return "Couldn't read that element. Nothing was saved."
        case .notReady:
            return "The page is not ready. Nothing was saved."
        }
    }
}

struct HTMLDOMSanitizedElement: Equatable, Sendable {
    var tag: String
    var elementId: String?
    var classes: [String]
    var role: String?
    var accessibleName: String?
    var visibleText: String
    /// Content-world token for this exact node. Not written into the page DOM.
    var nodeToken: String
    /// Digest of the full normalized visible text, including text past the stored excerpt.
    var textDigest: String
    var safeURL: String?
    var inputType: String?
    var locator: [HTMLDOMLocatorStep]
    var limitation: HTMLDOMLookupLimitation?
    var isConnected: Bool
    var hasParent: Bool
    var cssBounds: CGRect

    var readableLabel: String {
        var label = tag
        if let elementId, !elementId.isEmpty {
            label += "#\(elementId)"
        }
        if let inputType, !inputType.isEmpty {
            label += " type=\(inputType)"
        }
        if let role, !role.isEmpty {
            label += " role=\(role)"
        }
        if let accessibleName, !accessibleName.isEmpty {
            label += " \"\(accessibleName)\""
        } else if !visibleText.isEmpty {
            let excerpt = visibleText.count > 80 ? String(visibleText.prefix(80)) : visibleText
            label += " \"\(excerpt)\""
        }
        if let limitation {
            label += " (\(limitation.rawValue))"
        }
        return label
    }

    var summaryText: String {
        let text = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == accessibleName {
            return readableLabel
        }
        return "\(readableLabel)\n\(text)"
    }

    var locatorDescription: String {
        locator.map { step in
            let prefix = step.entersOpenShadow ? "shadow>" : ""
            return "\(prefix)\(step.tag):\(step.siblingIndex)"
        }.joined(separator: " > ")
    }

    var fingerprint: String {
        let parts = [
            tag,
            elementId ?? "",
            classes.joined(separator: "."),
            role ?? "",
            accessibleName ?? "",
            visibleText,
            nodeToken,
            textDigest,
            safeURL ?? "",
            inputType ?? "",
            locator.map(\.canonical).joined(separator: "/"),
            limitation?.rawValue ?? "",
        ]
        return HTMLDOMSourceIdentity.sha256Hex(parts.joined(separator: "\u{1e}"))
    }
}

struct HTMLDOMSelectionSnapshot: Equatable, Sendable {
    var generation: UInt64
    var sessionId: String
    var sourceSHA256: String
    var element: HTMLDOMSanitizedElement

    var fingerprint: String { element.fingerprint }

    func anchor() -> HTMLDOMElementAnchor {
        HTMLDOMElementAnchor(
            sourceSHA256: sourceSHA256,
            navigationGeneration: generation,
            sessionId: sessionId,
            filePath: nil,
            readableLabel: element.readableLabel,
            sanitizedText: element.visibleText,
            locatorDescription: element.locatorDescription,
            fingerprint: fingerprint,
            limitation: element.limitation?.rawValue,
            lookupScope: HTMLDOMElementAnchor.mainFrameAndOpenShadowScope
        )
    }
}

enum HTMLDOMSelectionFreshness {
    /// A matching loaded-source hash is not enough. The live element must still
    /// be connected, in the same navigation generation and session, and carry
    /// the same sanitized fingerprint.
    static func revalidated(
        snapshot: HTMLDOMSelectionSnapshot,
        live: HTMLDOMSanitizedElement?,
        currentGeneration: UInt64,
        currentSessionId: String,
        currentSourceSHA256: String,
        filePath: String?
    ) -> Result<HTMLDOMElementAnchor, HTMLDOMSelectionRejection> {
        guard snapshot.generation == currentGeneration else { return .failure(.staleGeneration) }
        guard snapshot.sessionId == currentSessionId else { return .failure(.sessionMismatch) }
        guard snapshot.sourceSHA256 == currentSourceSHA256 else { return .failure(.sourceHashMismatch) }
        guard let live, live.isConnected else { return .failure(.disconnected) }
        guard live.fingerprint == snapshot.fingerprint else { return .failure(.fingerprintMismatch) }
        var anchor = snapshot.anchor()
        anchor.filePath = filePath
        return .success(anchor)
    }
}

enum HTMLDOMSanitizer {
    static let maxSerializedBytes = 8_192
    static let maxTextLength = 240
    static let maxNameLength = 120
    static let maxFieldLength = 2_000
    static let maxLocatorDepth = 32
    static let maxClasses = 6
    static let maxURLLength = 180

    private static let forbiddenKeys: Set<String> = [
        "outerhtml", "innerhtml", "innertext", "textcontent", "value", "password", "onclick", "onerror",
    ]
    private static let allowedAttributes: Set<String> = [
        "id", "class", "role", "aria-label", "alt", "title", "type", "href", "src", "name",
    ]

    static func sanitize(_ raw: [String: Any]) -> Result<HTMLDOMSanitizedElement, HTMLDOMSelectionRejection> {
        if serializedCount(raw) > maxSerializedBytes {
            return .failure(.payloadTooLarge)
        }
        if containsForbiddenKey(raw) {
            return .failure(.invalidPayload)
        }
        guard let tag = sanitizedToken(string(raw["tagName"]), maxLength: 64),
              tag.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else {
            return .failure(.invalidPayload)
        }
        let attributes = dictionary(raw["attributes"]) ?? [:]
        if containsForbiddenKey(attributes) || attributes.keys.contains(where: { $0.lowercased().hasPrefix("on") }) {
            return .failure(.invalidPayload)
        }
        for (key, value) in attributes {
            guard allowedAttributes.contains(key.lowercased()) else { continue }
            if let text = string(value), text.count > maxFieldLength {
                return .failure(.payloadTooLarge)
            }
        }

        let visibleText = cleanedText(string(raw["visibleText"]) ?? "")
        if (string(raw["visibleText"]) ?? "").count > maxTextLength {
            return .failure(.payloadTooLarge)
        }
        guard let nodeToken = sanitizedToken(string(raw["nodeToken"]), maxLength: 32),
              let textDigest = sanitizedToken(string(raw["textDigest"]), maxLength: 64),
              textDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return .failure(.invalidPayload)
        }
        let sensitiveControl = bool(raw["isSensitive"]) == true || isSensitiveFormControl(tag: tag)
        let accessibleName = sensitiveControl ? nil : boundedName(string(raw["accessibleName"]))
        let locator = locatorSteps(raw["locator"])
        guard !locator.isEmpty, locator.count <= maxLocatorDepth else {
            return .failure(.invalidPayload)
        }
        guard let bounds = bounds(raw["bounds"]) else {
            return .failure(.invalidPayload)
        }

        let href = firstString(attributes, keys: ["href", "src"])
        return .success(HTMLDOMSanitizedElement(
            tag: tag,
            elementId: sensitiveControl ? nil : sanitizedIdentifier(string(attributes["id"])),
            classes: sensitiveControl ? [] : sanitizedClasses(string(attributes["class"])),
            role: sensitiveControl ? nil : sanitizedToken(string(attributes["role"]), maxLength: 40),
            accessibleName: accessibleName,
            visibleText: visibleText,
            nodeToken: nodeToken,
            textDigest: textDigest,
            safeURL: href.flatMap(sanitizedURL),
            inputType: sanitizedToken(string(attributes["type"]), maxLength: 40),
            locator: locator,
            limitation: string(raw["limitation"]).flatMap(HTMLDOMLookupLimitation.init(rawValue:)),
            isConnected: bool(raw["isConnected"]) ?? false,
            hasParent: bool(raw["hasParent"]) ?? false,
            cssBounds: bounds
        ))
    }

    private static func isSensitiveFormControl(tag: String) -> Bool {
        tag == "input" || tag == "textarea" || tag == "select" || tag == "option"
    }

    static func sanitizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxFieldLength else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("blob:")
            || lower.hasPrefix("file:") || lower.hasPrefix("vbscript:") {
            return nil
        }
        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment
        if withoutQuery.contains("@"), withoutQuery.contains("://") {
            return nil
        }
        if let scheme = URL(string: withoutQuery)?.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return nil }
        }
        return relativeURL(withoutQuery)
    }

    private static func relativeURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength else { return nil }
        guard !trimmed.contains("<"), !trimmed.contains(">"), !trimmed.lowercased().contains("javascript:") else {
            return nil
        }
        return trimmed
    }

    private static func cleanedText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)javascript:", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)on[a-z]+\\s*=", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = cleanedText(raw)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxNameLength {
            return nil
        }
        return cleaned
    }

    private static func sanitizedIdentifier(_ raw: String?) -> String? {
        guard let token = sanitizedToken(raw, maxLength: 80) else { return nil }
        guard token.range(of: "^[A-Za-z][A-Za-z0-9_.:-]*$", options: .regularExpression) != nil else {
            return nil
        }
        return token
    }

    private static func sanitizedToken(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        guard !trimmed.contains("<"), !trimmed.lowercased().contains("javascript:") else { return nil }
        return trimmed
    }

    private static func sanitizedClasses(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(whereSeparator: { $0.isWhitespace })
            .prefix(maxClasses)
            .compactMap { sanitizedToken(String($0), maxLength: 40) }
    }

    private static func locatorSteps(_ value: Any?) -> [HTMLDOMLocatorStep] {
        guard let items = array(value) else { return [] }
        var steps: [HTMLDOMLocatorStep] = []
        for item in items {
            guard let dict = dictionary(item),
                  let tag = sanitizedToken(string(dict["tag"]), maxLength: 64)?.lowercased(),
                  tag.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  let index = int(dict["siblingIndex"]),
                  index >= 0, index < 10_000 else {
                return []
            }
            steps.append(HTMLDOMLocatorStep(
                tag: tag,
                siblingIndex: index,
                entersOpenShadow: bool(dict["entersOpenShadow"]) ?? false
            ))
        }
        return steps
    }

    private static func bounds(_ value: Any?) -> CGRect? {
        guard let dict = dictionary(value),
              let x = cgFloat(dict["x"]),
              let y = cgFloat(dict["y"]),
              let width = cgFloat(dict["width"]),
              let height = cgFloat(dict["height"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              abs(x) < 100_000, abs(y) < 100_000,
              width >= 0, height >= 0, width < 100_000, height < 100_000 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func containsForbiddenKey(_ raw: [String: Any]) -> Bool {
        raw.keys.contains { forbiddenKeys.contains($0.lowercased()) }
    }

    private static func serializedCount(_ raw: [String: Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return maxSerializedBytes + 1
        }
        return data.count
    }

    private static func firstString(_ raw: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = string(raw[key]) {
                return value
            }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        if let string = value as? String { return string }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let dict = value as? NSDictionary else { return nil }
        var converted: [String: Any] = [:]
        for (key, entry) in dict {
            guard let key = key as? String else { continue }
            converted[key] = entry
        }
        return converted
    }

    static func array(_ value: Any?) -> [Any]? {
        if let array = value as? [Any] { return array }
        if let array = value as? NSArray { return array.map { $0 } }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func cgFloat(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(truncating: number) }
        if let double = value as? Double { return CGFloat(double) }
        return nil
    }
}

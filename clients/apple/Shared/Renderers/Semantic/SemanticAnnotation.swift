import CoreGraphics
import CryptoKit
import Foundation

enum SemanticSpanRole: String, Equatable, Sendable, Codable {
    case declaration
    case reference
}

enum SemanticSourceOrigin: String, Equatable, Sendable, Codable {
    case source
    case derived
    case diagram
    case dom
}

/// UTF-8 byte offsets into the original source. `endOffset` and `endColumn` are exclusive.
/// Columns are 1-based UTF-8 byte columns, not UTF-16 code units or grapheme clusters.
struct SemanticSourceSpan: Equatable, Sendable, Codable {
    var startOffset: Int
    var endOffset: Int
    var startLine: Int
    var startColumn: Int
    var endLine: Int
    var endColumn: Int
    var role: SemanticSpanRole
    var excerpt: String
}

struct SemanticTarget: Equatable, Sendable, Codable {
    var id: String
    var kind: String
    var label: String
    var displayKey: String
    var spans: [SemanticSourceSpan]
    var sourceOrigin: SemanticSourceOrigin
    var sourceRevision: String
    var originatingTargetID: String?
    var limitation: String?

    init(
        id: String,
        kind: String,
        label: String,
        displayKey: String,
        spans: [SemanticSourceSpan],
        sourceOrigin: SemanticSourceOrigin,
        sourceRevision: String,
        originatingTargetID: String? = nil,
        limitation: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.displayKey = displayKey
        self.spans = spans
        self.sourceOrigin = sourceOrigin
        self.sourceRevision = sourceRevision
        self.originatingTargetID = originatingTargetID
        self.limitation = limitation
    }
}

/// Filled outline copied from a renderer path. Curves stay curves so hit testing
/// does not fall back to the bounding rectangle.
struct SemanticPath: Equatable, Sendable {
    enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    var elements: [Element]

    init(elements: [Element]) {
        self.elements = elements
    }

    init(cgPath: CGPath) {
        var elements: [Element] = []
        cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                elements.append(.move(element.points[0]))
            case .addLineToPoint:
                elements.append(.line(element.points[0]))
            case .addQuadCurveToPoint:
                elements.append(.quad(to: element.points[1], control: element.points[0]))
            case .addCurveToPoint:
                elements.append(.curve(
                    to: element.points[2],
                    control1: element.points[0],
                    control2: element.points[1]
                ))
            case .closeSubpath:
                elements.append(.close)
            @unknown default:
                break
            }
        }
        self.elements = elements
    }

    var isEmpty: Bool { elements.isEmpty }

    var bounds: CGRect {
        cgPath().boundingBoxOfPath
    }

    func cgPath() -> CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .quad(let end, let control):
                path.addQuadCurve(to: end, control: control)
            case .curve(let end, let control1, let control2):
                path.addCurve(to: end, control1: control1, control2: control2)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    func representativeStrokePoint() -> CGPoint? {
        var current: CGPoint?
        for element in elements {
            switch element {
            case .move(let point):
                current = point
            case .line(let end):
                guard let start = current else {
                    current = end
                    continue
                }
                return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            case .quad(let end, let control):
                guard let start = current else {
                    current = end
                    continue
                }
                return CGPoint(
                    x: start.x * 0.25 + control.x * 0.5 + end.x * 0.25,
                    y: start.y * 0.25 + control.y * 0.5 + end.y * 0.25
                )
            case .curve(let end, let control1, let control2):
                guard let start = current else {
                    current = end
                    continue
                }
                return CGPoint(
                    x: start.x * 0.125 + control1.x * 0.375 + control2.x * 0.375 + end.x * 0.125,
                    y: start.y * 0.125 + control1.y * 0.375 + control2.y * 0.375 + end.y * 0.125
                )
            case .close:
                break
            }
        }
        return current
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let path = cgPath()
        guard !path.isEmpty else { return false }
        if path.contains(point, using: .winding, transform: .identity) {
            return true
        }
        guard tolerance > 0 else { return false }
        return strokeContains(point, strokeWidth: 0, tolerance: tolerance)
    }

    /// Stroke-only hit test. Unclosed curves must not treat the implicit
    /// closing chord as a filled interior.
    func strokeContains(_ point: CGPoint, strokeWidth: CGFloat, tolerance: CGFloat) -> Bool {
        let path = cgPath()
        guard !path.isEmpty else { return false }
        let width = max(strokeWidth, 0) + max(tolerance, 0) * 2
        guard width > 0 else { return false }
        let stroked = path.copy(
            strokingWithWidth: width,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return stroked.contains(point, using: .winding, transform: .identity)
    }
}

enum SemanticGeometry: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case sector(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat)
    case polyline(points: [CGPoint], strokeWidth: CGFloat)
    case polygon(points: [CGPoint])
    case path(SemanticPath)
    case strokedPath(SemanticPath, strokeWidth: CGFloat)
}

enum SemanticChooserTitle {
    static func text(label: String, displayKey: String) -> String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = displayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty { return trimmedKey }
        if trimmedKey.isEmpty || trimmedLabel == trimmedKey { return trimmedLabel }
        return "\(trimmedLabel) · \(trimmedKey)"
    }

    static func text(for target: SemanticTarget) -> String {
        text(label: target.label, displayKey: target.displayKey)
    }
}

enum SemanticHighlightStyle {
    static func lineWidth(for geometry: SemanticGeometry) -> CGFloat {
        switch geometry {
        case .polyline(_, let strokeWidth), .strokedPath(_, let strokeWidth):
            return max(strokeWidth, 0.5)
        default:
            return 2
        }
    }
}

enum SemanticHitSampling {
    static func point(for targetID: String, in map: SemanticAnnotationMap) -> CGPoint? {
        let regions = map.regions.filter { $0.targetID == targetID }
        let ordered = regions.sorted { preference($0.geometry) > preference($1.geometry) }
        for region in ordered {
            guard let point = point(in: region.geometry),
                  region.geometry.contains(point, tolerance: 0) else { continue }
            return point
        }
        return regions.first.flatMap { point(in: $0.geometry) }
    }

    static func point(in geometry: SemanticGeometry) -> CGPoint? {
        switch geometry {
        case .rectangle(let rect), .ellipse(let rect):
            return CGPoint(x: rect.midX, y: rect.midY)
        case .sector(let center, let radius, let startAngle, let endAngle):
            let mid = startAngle + (endAngle - startAngle) / 2
            return CGPoint(x: center.x + cos(mid) * radius * 0.5, y: center.y + sin(mid) * radius * 0.5)
        case .polyline(let points, _):
            guard points.count >= 2 else { return points.first }
            return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        case .polygon(let points):
            guard !points.isEmpty else { return nil }
            let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
            let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
            return CGPoint(x: x, y: y)
        case .path(let path):
            let bounds = path.bounds
            guard bounds.width > 0 || bounds.height > 0 else { return nil }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        case .strokedPath(let path, _):
            return path.representativeStrokePoint()
        }
    }

    private static func preference(_ geometry: SemanticGeometry) -> Int {
        switch geometry {
        case .rectangle, .ellipse: return 3
        case .sector, .polygon, .path, .strokedPath: return 2
        case .polyline: return 1
        }
    }
}

struct SemanticRegion: Equatable, Sendable {
    var targetID: String
    var geometry: SemanticGeometry
    var precedence: Int
}

struct SemanticHitResult: Equatable, Sendable {
    var targets: [SemanticTarget]

    var isAmbiguous: Bool { targets.count > 1 }

    static let none = SemanticHitResult(targets: [])
}

struct SemanticAnnotationMap: Equatable, Sendable {
    var sourceRevision: String
    var targets: [SemanticTarget]
    var regions: [SemanticRegion]

    func target(id: String) -> SemanticTarget? {
        targets.first { $0.id == id }
    }

    /// Layout-space hit test. `tolerance` is in the same space as `point`.
    /// Overlapping distinct targets stay ambiguous; repeated regions of one target collapse.
    func hitTest(point: CGPoint, tolerance: CGFloat, clip: CGRect? = nil) -> SemanticHitResult {
        if let clip, !clip.contains(point) {
            return .none
        }
        var matchedIDs: [String] = []
        var bestPrecedence: [String: Int] = [:]
        for region in regions where region.geometry.contains(point, tolerance: tolerance) {
            let previous = bestPrecedence[region.targetID] ?? Int.min
            if bestPrecedence[region.targetID] == nil {
                matchedIDs.append(region.targetID)
            }
            if region.precedence > previous {
                bestPrecedence[region.targetID] = region.precedence
            }
        }
        let ordered = matchedIDs.sorted { lhs, rhs in
            let left = bestPrecedence[lhs] ?? 0
            let right = bestPrecedence[rhs] ?? 0
            if left != right { return left > right }
            return lhs < rhs
        }
        let resolved = ordered.compactMap { target(id: $0) }
        return SemanticHitResult(targets: resolved)
    }
}

enum SemanticSourceRevision {
    static func hash(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum SemanticCoordinateTransform {
    static func layoutPoint(
        viewPoint: CGPoint,
        contentOrigin: CGPoint,
        zoomScale: CGFloat
    ) -> CGPoint {
        let scale = zoomScale == 0 ? 1 : zoomScale
        return CGPoint(
            x: (viewPoint.x - contentOrigin.x) / scale,
            y: (viewPoint.y - contentOrigin.y) / scale
        )
    }

    static func layoutTolerance(screenTolerance: CGFloat, zoomScale: CGFloat) -> CGFloat {
        let scale = zoomScale == 0 ? 1 : abs(zoomScale)
        return screenTolerance / scale
    }
}

extension SemanticGeometry {
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case .rectangle(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .ellipse(let rect):
            return Self.ellipseContains(point, rect: rect, tolerance: tolerance)
        case .sector(let center, let radius, let startAngle, let endAngle):
            return Self.sectorContains(
                point,
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                tolerance: tolerance
            )
        case .polyline(let points, let strokeWidth):
            return Self.polylineDistance(point, points: points) <= strokeWidth / 2 + tolerance
        case .polygon(let points):
            return Self.polygonContains(point, points: points)
                || Self.polylineDistance(point, points: points + (points.first.map { [$0] } ?? [])) <= tolerance
        case .path(let path):
            return path.contains(point, tolerance: tolerance)
        case .strokedPath(let path, let strokeWidth):
            return path.strokeContains(point, strokeWidth: strokeWidth, tolerance: tolerance)
        }
    }

    private static func ellipseContains(_ point: CGPoint, rect: CGRect, tolerance: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let rx = rect.width / 2 + tolerance
        let ry = rect.height / 2 + tolerance
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) <= 1
    }

    private static func sectorContains(
        _ point: CGPoint,
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        let sweep = normalizedSweep(from: startAngle, to: endAngle)
        guard sweep > 0 else { return false }
        let angle = atan2(dy, dx)
        let onArc = distance <= radius + tolerance && angleDelta(angle, from: startAngle) <= sweep + 0.000_1
        if distance <= radius, angleDelta(angle, from: startAngle) <= sweep + 0.000_1 {
            return true
        }
        if tolerance <= 0 { return false }
        if onArc, distance >= radius - tolerance { return true }
        let startPoint = CGPoint(x: center.x + cos(startAngle) * radius, y: center.y + sin(startAngle) * radius)
        let endPoint = CGPoint(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius)
        return segmentDistance(point, center, startPoint) <= tolerance
            || segmentDistance(point, center, endPoint) <= tolerance
    }

    private static func normalizedSweep(from start: CGFloat, to end: CGFloat) -> CGFloat {
        var sweep = end - start
        if sweep < 0 { sweep += 2 * .pi }
        return sweep
    }

    private static func angleDelta(_ angle: CGFloat, from start: CGFloat) -> CGFloat {
        var delta = angle - start
        while delta < 0 { delta += 2 * .pi }
        while delta >= 2 * .pi { delta -= 2 * .pi }
        return delta
    }

    private static func polygonContains(_ point: CGPoint, points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var previous = points[points.count - 1]
        for current in points {
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / ((previous.y - current.y) == 0 ? 1 : (previous.y - current.y)) + current.x)
            if intersects { inside.toggle() }
            previous = current
        }
        return inside
    }

    private static func polylineDistance(_ point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else {
            return points.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .greatestFiniteMagnitude
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in points.indices.dropLast() {
            best = min(best, segmentDistance(point, points[index], points[index + 1]))
        }
        return best
    }

    private static func segmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 0.000_1 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

struct ReviewCommentSemanticAnchor: Codable, Equatable, Sendable {
    var sourceRevision: String
    var targetID: String
    var kind: String
    var label: String
    var displayKey: String
    var sourceOrigin: SemanticSourceOrigin
    var spans: [SemanticSourceSpan]
    var originatingTargetID: String?
    var limitation: String?
    var isStale: Bool

    init(
        sourceRevision: String,
        targetID: String,
        kind: String,
        label: String,
        displayKey: String,
        sourceOrigin: SemanticSourceOrigin,
        spans: [SemanticSourceSpan],
        originatingTargetID: String? = nil,
        limitation: String? = nil,
        isStale: Bool = false
    ) {
        self.sourceRevision = sourceRevision
        self.targetID = targetID
        self.kind = kind
        self.label = label
        self.displayKey = displayKey
        self.sourceOrigin = sourceOrigin
        self.spans = spans
        self.originatingTargetID = originatingTargetID
        self.limitation = limitation
        self.isStale = isStale
    }

    func markedStaleAgainst(currentRevision: String) -> ReviewCommentSemanticAnchor {
        guard sourceRevision != currentRevision else { return self }
        var copy = self
        copy.isStale = true
        return copy
    }

    var promptLines: [String] {
        var lines = ["**Diagram object:** \(SemanticChooserTitle.text(label: label, displayKey: displayKey))"]
        if isStale {
            lines.append("**Status:** stale — the original reference was kept and was not re-anchored")
        }
        if let limitation, !limitation.isEmpty {
            lines.append("**Limitation:** \(limitation)")
        }
        if !spans.isEmpty {
            lines.append("**Source context:**")
            for span in spans {
                lines.append("- Line \(span.startLine)\(span.endLine == span.startLine ? "" : "–\(span.endLine)"): \(span.excerpt)")
            }
        }
        return lines
    }
}

extension SemanticTarget {
    func semanticAnchor() -> ReviewCommentSemanticAnchor {
        ReviewCommentSemanticAnchor(
            sourceRevision: sourceRevision,
            targetID: id,
            kind: kind,
            label: label,
            displayKey: displayKey,
            sourceOrigin: sourceOrigin,
            spans: spans,
            originatingTargetID: originatingTargetID,
            limitation: limitation
        )
    }
}

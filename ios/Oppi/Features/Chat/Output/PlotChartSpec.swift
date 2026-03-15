import Foundation

/// Lightweight chart grammar consumed by Oppi's native Swift Charts renderer.
///
/// v1 focus is pragmatic: parse `plot` tool args and `tool_end.details.ui[]`
/// payloads into a shape that can be rendered natively in expanded tool rows.
struct PlotChartSpec: Sendable, Equatable, Hashable {
    struct Row: Sendable, Equatable, Hashable, Identifiable {
        let id: Int
        let values: [String: Value]

        func number(for key: String?) -> Double? {
            guard let key, let value = values[key] else { return nil }
            switch value {
            case .number(let n): return n
            case .string(let s): return Double(s)
            case .bool: return nil
            }
        }

        func seriesLabel(for key: String?) -> String? {
            guard let key, let value = values[key] else { return nil }
            switch value {
            case .string(let s): return s
            case .number(let n):
                if n.rounded() == n {
                    return String(Int(n))
                }
                return String(format: "%.3f", n)
            case .bool(let b):
                return b ? "true" : "false"
            }
        }
    }

    enum Value: Sendable, Equatable, Hashable {
        case number(Double)
        case string(String)
        case bool(Bool)
    }

    struct Axis: Sendable, Equatable, Hashable {
        var label: String?
        var invert: Bool = false
    }

    struct Interaction: Sendable, Equatable, Hashable {
        var xSelection: Bool = true
        var xRangeSelection: Bool = false
        var scrollableX: Bool = false
        var xVisibleDomainLength: Double?
    }

    struct RenderHints: Sendable, Equatable, Hashable {
        struct XAxis: Sendable, Equatable, Hashable {
            enum AxisType: String, Sendable, Hashable {
                case auto
                case time
                case numeric
                case category
            }

            enum LabelFormat: String, Sendable, Hashable {
                case auto
                case dateShort = "date-short"
                case dateDay = "date-day"
                case numberShort = "number-short"
            }

            enum Strategy: String, Sendable, Hashable {
                case auto
                case startEndWeekly = "start-end-weekly"
                case stride
            }

            var type: AxisType?
            var maxVisibleTicks: Int?
            var labelFormat: LabelFormat?
            var strategy: Strategy?

            var isEmpty: Bool {
                type == nil && maxVisibleTicks == nil && labelFormat == nil && strategy == nil
            }
        }

        struct YAxis: Sendable, Equatable, Hashable {
            enum ZeroBaseline: String, Sendable, Hashable {
                case auto
                case always
                case never
            }

            var maxTicks: Int?
            var nice: Bool?
            var zeroBaseline: ZeroBaseline?

            var isEmpty: Bool {
                maxTicks == nil && nice == nil && zeroBaseline == nil
            }
        }

        struct Legend: Sendable, Equatable, Hashable {
            enum Mode: String, Sendable, Hashable {
                case auto
                case show
                case hide
                case inline
            }

            var mode: Mode?
            var maxItems: Int?

            var isEmpty: Bool {
                mode == nil && maxItems == nil
            }
        }

        struct Grid: Sendable, Equatable, Hashable {
            enum Vertical: String, Sendable, Hashable {
                case none
                case major
            }

            enum Horizontal: String, Sendable, Hashable {
                case major
            }

            var vertical: Vertical?
            var horizontal: Horizontal?

            var isEmpty: Bool {
                vertical == nil && horizontal == nil
            }
        }

        var xAxis: XAxis?
        var yAxis: YAxis?
        var legend: Legend?
        var grid: Grid?

        var isEmpty: Bool {
            xAxis == nil && yAxis == nil && legend == nil && grid == nil
        }
    }

    enum MarkType: String, Sendable, Hashable {
        case line
        case area
        case bar
        case point
        case rectangle
        case rule
        case sector
    }

    enum Interpolation: String, Sendable, Hashable {
        case linear
        case cardinal
        case catmullRom
        case monotone
        case stepStart
        case stepCenter
        case stepEnd
    }

    struct Mark: Sendable, Equatable, Hashable, Identifiable {
        let id: String
        let type: MarkType
        var x: String?
        var y: String?
        var xStart: String?
        var xEnd: String?
        var yStart: String?
        var yEnd: String?
        var angle: String?
        var xValue: Double?
        var yValue: Double?
        var series: String?
        var label: String?
        var interpolation: Interpolation?
    }

    struct DetailsChartPayload: Sendable, Equatable, Hashable {
        let spec: PlotChartSpec
        let fallbackText: String?
    }

    struct Annotation: Sendable, Equatable, Hashable, Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let text: String
        let anchor: AnnotationAnchor

        enum AnnotationAnchor: String, Sendable, Hashable {
            case top
            case bottom
            case leading
            case trailing
        }
    }

    var title: String?
    var rows: [Row]
    var marks: [Mark]
    var xAxis: Axis
    var yAxis: Axis
    var interaction: Interaction
    var renderHints: RenderHints? = nil
    var colorScale: [String: String]? = nil
    var annotations: [Annotation]? = nil
    var preferredHeight: Double?

    var isRenderable: Bool {
        !rows.isEmpty && !marks.isEmpty
    }

    /// Whether all values in a column can be interpreted as numbers.
    /// Returns `true` when every row's value for `key` is `.number` or a
    /// numeric string. If no row contains `key`, defaults to `true`.
    func columnIsNumeric(_ key: String?) -> Bool {
        guard let key else { return true }
        for row in rows {
            guard let value = row.values[key] else { continue }
            switch value {
            case .number: continue
            case .string(let s):
                if Double(s) == nil { return false }
            case .bool: return false
            }
        }
        // No rows with this key → default to numeric (renders nothing either way).
        return true
    }

    static func fromPlotArgs(_ args: [String: JSONValue]?) -> Self? {
        guard let args else { return nil }

        let root = args["spec"]?.objectValue ?? args
        let title = args["title"]?.stringValue ?? root["title"]?.stringValue

        return fromSpecRoot(root, titleOverride: title)
    }

    static func fromToolDetails(_ details: JSONValue?) -> DetailsChartPayload? {
        guard let uiEntries = details?.objectValue?["ui"]?.arrayValue else {
            return nil
        }

        for entryValue in uiEntries {
            guard let entry = entryValue.objectValue,
                  isChartEntry(entry) else {
                continue
            }

            guard let specObject = entry["spec"]?.objectValue else {
                continue
            }

            let entryTitle = nonEmptyTrimmed(entry["title"]?.stringValue)
            guard let spec = fromSpecRoot(specObject, titleOverride: entryTitle) else {
                continue
            }

            let fallbackText = nonEmptyTrimmed(entry["fallbackText"]?.stringValue)
            return DetailsChartPayload(spec: spec, fallbackText: fallbackText)
        }

        return nil
    }

    static func collapsedTitle(from args: [String: JSONValue]?, details: JSONValue?) -> String? {
        if let detailsTitle = collapsedTitle(from: details) {
            return detailsTitle
        }

        return collapsedTitle(from: args)
    }

    static func collapsedTitle(from args: [String: JSONValue]?) -> String? {
        if let title = nonEmptyTrimmed(args?["title"]?.stringValue) {
            return title
        }

        let root = args?["spec"]?.objectValue ?? args
        if let title = nonEmptyTrimmed(root?["title"]?.stringValue) {
            return title
        }

        return nil
    }

    // MARK: - Private

    private static func fromSpecRoot(
        _ root: [String: JSONValue],
        titleOverride: String?
    ) -> Self? {
        let title = nonEmptyTrimmed(titleOverride) ?? nonEmptyTrimmed(root["title"]?.stringValue)

        let rowsArray = root["dataset"]?.objectValue?["rows"]?.arrayValue
            ?? root["rows"]?.arrayValue
            ?? []

        let rows: [Row] = rowsArray.enumerated().compactMap { index, value in
            guard let object = value.objectValue else { return nil }
            var parsed: [String: Value] = [:]
            parsed.reserveCapacity(object.count)

            for (key, raw) in object {
                if let n = raw.numberValue, n.isFinite {
                    parsed[key] = .number(n)
                } else if let s = raw.stringValue {
                    parsed[key] = .string(s)
                } else if let b = raw.boolValue {
                    parsed[key] = .bool(b)
                }
            }

            guard !parsed.isEmpty else { return nil }
            return Row(id: index, values: parsed)
        }

        let marksArray = root["marks"]?.arrayValue ?? []
        let marks: [Mark] = marksArray.enumerated().compactMap { index, value in
            guard let object = value.objectValue,
                  let typeRaw = object["type"]?.stringValue,
                  let type = MarkType(rawValue: typeRaw.lowercased()) else {
                return nil
            }

            let id = nonEmptyTrimmed(object["id"]?.stringValue)
            let markID = id ?? "mark-\(index)-\(type.rawValue)"

            var mark = Mark(id: markID, type: type)
            mark.x = nonEmptyTrimmed(object["x"]?.stringValue)
            mark.y = nonEmptyTrimmed(object["y"]?.stringValue)
            mark.xStart = nonEmptyTrimmed(object["xStart"]?.stringValue)
            mark.xEnd = nonEmptyTrimmed(object["xEnd"]?.stringValue)
            mark.yStart = nonEmptyTrimmed(object["yStart"]?.stringValue)
            mark.yEnd = nonEmptyTrimmed(object["yEnd"]?.stringValue)
            mark.angle = nonEmptyTrimmed(object["angle"]?.stringValue)
            mark.xValue = object["xValue"]?.numberValue
            mark.yValue = object["yValue"]?.numberValue
            mark.series = nonEmptyTrimmed(object["series"]?.stringValue)
            mark.label = nonEmptyTrimmed(object["label"]?.stringValue)

            if let interpolationRaw = object["interpolation"]?.stringValue {
                let normalized = normalizeInterpolation(interpolationRaw)
                mark.interpolation = Interpolation(rawValue: normalized)
            }

            return mark
        }

        let axes = root["axes"]?.objectValue
        let xAxisObject = axes?["x"]?.objectValue
        let yAxisObject = axes?["y"]?.objectValue

        var interaction = Interaction()
        if let interactionObject = root["interaction"]?.objectValue {
            interaction.xSelection = interactionObject["xSelection"]?.boolValue ?? interaction.xSelection
            interaction.xRangeSelection = interactionObject["xRangeSelection"]?.boolValue ?? interaction.xRangeSelection
            interaction.scrollableX = interactionObject["scrollableX"]?.boolValue ?? interaction.scrollableX
            interaction.xVisibleDomainLength = interactionObject["xVisibleDomainLength"]?.numberValue
        }

        let spec = Self(
            title: title,
            rows: rows,
            marks: marks,
            xAxis: Axis(
                label: nonEmptyTrimmed(xAxisObject?["label"]?.stringValue)
                    ?? nonEmptyTrimmed(root["xLabel"]?.stringValue),
                invert: xAxisObject?["invert"]?.boolValue ?? false
            ),
            yAxis: Axis(
                label: nonEmptyTrimmed(yAxisObject?["label"]?.stringValue)
                    ?? nonEmptyTrimmed(root["yLabel"]?.stringValue),
                invert: yAxisObject?["invert"]?.boolValue ?? false
            ),
            interaction: interaction,
            renderHints: parseRenderHints(root["renderHints"]?.objectValue),
            colorScale: parseColorScale(root["colorScale"]?.objectValue),
            annotations: parseAnnotations(root["annotations"]?.arrayValue),
            preferredHeight: root["height"]?.numberValue
        )

        return spec.isRenderable ? spec : nil
    }

    private static func parseRenderHints(_ object: [String: JSONValue]?) -> RenderHints? {
        guard let object else { return nil }

        var hints = RenderHints()

        if let xAxisObject = object["xAxis"]?.objectValue {
            var xAxis = RenderHints.XAxis()
            if let token = normalizedToken(xAxisObject["type"]?.stringValue) {
                xAxis.type = RenderHints.XAxis.AxisType(rawValue: token)
            }
            xAxis.maxVisibleTicks = clampedInt(xAxisObject["maxVisibleTicks"], min: 2, max: 8)
            if let token = normalizedToken(xAxisObject["labelFormat"]?.stringValue) {
                xAxis.labelFormat = RenderHints.XAxis.LabelFormat(rawValue: token)
            }
            if let token = normalizedToken(xAxisObject["strategy"]?.stringValue) {
                xAxis.strategy = RenderHints.XAxis.Strategy(rawValue: token)
            }

            if !xAxis.isEmpty {
                hints.xAxis = xAxis
            }
        }

        if let yAxisObject = object["yAxis"]?.objectValue {
            var yAxis = RenderHints.YAxis()
            yAxis.maxTicks = clampedInt(yAxisObject["maxTicks"], min: 2, max: 8)
            yAxis.nice = yAxisObject["nice"]?.boolValue
            if let token = normalizedToken(yAxisObject["zeroBaseline"]?.stringValue) {
                yAxis.zeroBaseline = RenderHints.YAxis.ZeroBaseline(rawValue: token)
            }

            if !yAxis.isEmpty {
                hints.yAxis = yAxis
            }
        }

        if let legendObject = object["legend"]?.objectValue {
            var legend = RenderHints.Legend()
            if let token = normalizedToken(legendObject["mode"]?.stringValue) {
                legend.mode = RenderHints.Legend.Mode(rawValue: token)
            }
            legend.maxItems = clampedInt(legendObject["maxItems"], min: 1, max: 5)

            if !legend.isEmpty {
                hints.legend = legend
            }
        }

        if let gridObject = object["grid"]?.objectValue {
            var grid = RenderHints.Grid()
            if let token = normalizedToken(gridObject["vertical"]?.stringValue) {
                grid.vertical = RenderHints.Grid.Vertical(rawValue: token)
            }
            if let token = normalizedToken(gridObject["horizontal"]?.stringValue) {
                grid.horizontal = RenderHints.Grid.Horizontal(rawValue: token)
            }

            if !grid.isEmpty {
                hints.grid = grid
            }
        }

        return hints.isEmpty ? nil : hints
    }

    private static func parseColorScale(_ object: [String: JSONValue]?) -> [String: String]? {
        guard let object, !object.isEmpty else { return nil }
        var scale: [String: String] = [:]
        for (key, value) in object {
            guard let hex = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hex.isEmpty else { continue }
            scale[key] = hex
        }
        return scale.isEmpty ? nil : scale
    }

    private static func parseAnnotations(_ array: [JSONValue]?) -> [Annotation]? {
        guard let array, !array.isEmpty else { return nil }
        var annotations: [Annotation] = []
        for (index, entry) in array.enumerated() {
            guard let object = entry.objectValue,
                  let x = object["x"]?.numberValue,
                  let y = object["y"]?.numberValue,
                  let text = nonEmptyTrimmed(object["text"]?.stringValue) else { continue }
            let anchorRaw = object["anchor"]?.stringValue?.lowercased() ?? "top"
            let anchor = Annotation.AnnotationAnchor(rawValue: anchorRaw) ?? .top
            annotations.append(Annotation(id: index, x: x, y: y, text: text, anchor: anchor))
        }
        return annotations.isEmpty ? nil : annotations
    }

    private static func normalizedToken(_ value: String?) -> String? {
        nonEmptyTrimmed(value)?.lowercased()
    }

    private static func clampedInt(_ value: JSONValue?, min: Int, max: Int) -> Int? {
        guard let number = value?.numberValue, number.isFinite else {
            return nil
        }

        let rounded = Int(number.rounded())
        return Swift.max(min, Swift.min(max, rounded))
    }

    private static func collapsedTitle(from details: JSONValue?) -> String? {
        guard let uiEntries = details?.objectValue?["ui"]?.arrayValue else {
            return nil
        }

        for entryValue in uiEntries {
            guard let entry = entryValue.objectValue,
                  isChartEntry(entry) else {
                continue
            }

            if let title = nonEmptyTrimmed(entry["title"]?.stringValue) {
                return title
            }

            if let title = nonEmptyTrimmed(entry["spec"]?.objectValue?["title"]?.stringValue) {
                return title
            }
        }

        return nil
    }

    private static func isChartEntry(_ object: [String: JSONValue]) -> Bool {
        guard object["kind"]?.stringValue?.lowercased() == "chart" else {
            return false
        }

        guard let version = object["version"]?.numberValue else {
            return false
        }

        return abs(version - 1) < 0.000_001
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeInterpolation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Normalize snake/kebab/camel to a lowercase token and map to enum raw values.
        let token = trimmed
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()

        switch token {
        case "catmullrom": return "catmullRom"
        case "stepstart": return "stepStart"
        case "stepcenter": return "stepCenter"
        case "stepend": return "stepEnd"
        default: return token
        }
    }
}

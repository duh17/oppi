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

    var title: String?
    var rows: [Row]
    var marks: [Mark]
    var xAxis: Axis
    var yAxis: Axis
    var interaction: Interaction
    var preferredHeight: Double?

    var isRenderable: Bool {
        !rows.isEmpty && !marks.isEmpty
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
            preferredHeight: root["height"]?.numberValue
        )

        return spec.isRenderable ? spec : nil
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

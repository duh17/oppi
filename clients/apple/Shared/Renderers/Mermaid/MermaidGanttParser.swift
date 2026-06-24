import Foundation

/// Parser for Mermaid gantt chart syntax.
///
/// Handles: title, dateFormat, axisFormat, excludes, sections, and tasks
/// with status markers (active, done, crit, milestone), dates, durations,
/// and `after` dependencies.
enum MermaidGanttParser {
    struct Options: Equatable, Sendable {
        var displayMode: GanttDisplayMode = .standard
        var topAxis = false
    }

    nonisolated static func parse(lines: [String], options: Options = Options()) -> GanttDiagram {
        var title: String?
        var dateFormat = "YYYY-MM-DD"
        var axisFormat: String?
        var tickInterval: String?
        var weekend: String?
        var weekday: String?
        var todayMarker: String?
        var excludes: [String] = []
        var sections: [GanttSection] = []
        var clicks: [GanttClick] = []

        // Accumulate tasks for the current section.
        var currentSectionName: String?
        var currentTasks: [GanttTask] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Directives
            if let value = line.strippingPrefix("title ") {
                title = MermaidTextUtils.normalizeLabel(value)
                continue
            }
            if let value = line.strippingPrefix("dateFormat ") {
                dateFormat = value
                continue
            }
            if let value = line.strippingPrefix("axisFormat ") {
                axisFormat = value
                continue
            }
            if let value = line.strippingPrefix("excludes ") {
                excludes.append(contentsOf: splitExcludes(value))
                continue
            }
            if let value = line.strippingPrefix("tickInterval ") {
                tickInterval = value
                continue
            }
            if let value = line.strippingPrefix("weekend ") {
                weekend = value
                continue
            }
            if let value = line.strippingPrefix("weekday ") {
                weekday = value
                continue
            }
            if let value = line.strippingPrefix("todayMarker ") {
                todayMarker = value
                continue
            }
            if let click = parseClick(line) {
                clicks.append(click)
                continue
            }

            // Section header
            if let value = line.strippingPrefix("section ") {
                // Flush previous section.
                flushSection(
                    name: currentSectionName,
                    tasks: &currentTasks,
                    into: &sections
                )
                currentSectionName = MermaidTextUtils.normalizeLabel(value)
                continue
            }

            // Task line: "Name :metadata"
            if let task = parseTask(line) {
                currentTasks.append(task)
            }
        }

        // Flush last section.
        flushSection(name: currentSectionName, tasks: &currentTasks, into: &sections)

        return GanttDiagram(
            title: title,
            dateFormat: dateFormat,
            sections: sections,
            axisFormat: axisFormat,
            excludes: excludes,
            tickInterval: tickInterval,
            weekend: weekend,
            weekday: weekday,
            todayMarker: todayMarker,
            displayMode: options.displayMode,
            topAxis: options.topAxis,
            clicks: clicks
        )
    }

    private static func parseClick(_ line: String) -> GanttClick? {
        guard let rest = line.strippingPrefix("click ") else { return nil }
        let pieces = rest.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        ).map(String.init)
        guard pieces.count == 3 else { return nil }

        let taskId = pieces[0].trimmingCharacters(in: .whitespaces)
        let action = pieces[1].lowercased()
        let payload = unquote(pieces[2].trimmingCharacters(in: .whitespaces))
        guard !taskId.isEmpty, !payload.isEmpty else { return nil }

        switch action {
        case "href":
            return GanttClick(taskId: taskId, action: .href(payload))
        case "call":
            return GanttClick(taskId: taskId, action: .call(payload))
        default:
            return nil
        }
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\""
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func splitExcludes(_ value: String) -> [String] {
        value.split { char in
            char == "," || char.isWhitespace
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    private static func splitDependencyRefs(_ value: String) -> [String] {
        value.split { char in
            char == "," || char.isWhitespace
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    // MARK: - Section flushing

    private static func flushSection(
        name: String?,
        tasks: inout [GanttTask],
        into sections: inout [GanttSection]
    ) {
        guard !tasks.isEmpty else { return }
        let sectionName = name ?? "Default"
        sections.append(GanttSection(name: sectionName, tasks: tasks))
        tasks = []
    }

    // MARK: - Task parsing

    /// Parse a task line like:
    ///   `Research           :done, des1, 2024-01-01, 2024-01-05`
    ///   `Testing            :after impl2, 3d`
    ///   `Staging            :2024-01-20, 2d`
    ///   `Production         :milestone, after impl2, 0d`
    private static func parseTask(_ line: String) -> GanttTask? {
        // Split on first `:` — left is name, right is metadata.
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }

        let name = String(line[line.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Don't match directive-like lines that slipped through.
        let lowerName = name.lowercased()
        if lowerName == "title" || lowerName == "dateformat"
            || lowerName == "axisformat" || lowerName == "excludes"
            || lowerName.hasPrefix("section") {
            return nil
        }

        let metadata = String(line[line.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)

        let parts = metadata.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var status: GanttTaskStatus = .normal
        var id: String?
        var startDate: String?
        var endDate: String?
        var duration: String?
        var afterId: String?
        var afterIds: [String] = []
        var untilIds: [String] = []

        // Classify each part.
        var remaining: [String] = []
        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "done":
                status = (status == .critical) ? .done : .done
            case "active":
                status = .active
            case "crit":
                status = .critical
            case "milestone":
                status = .milestone
            case "vert":
                status = .vert
            default:
                remaining.append(part)
            }
        }

        // Handle combined status: `crit, done` → done takes precedence for display,
        // but `crit` is more visually distinct. Mermaid treats `crit, done` as critical+done.
        // We'll just use the last status marker set above. For `crit, done`, done wins.
        // Re-scan to handle crit+done properly:
        let allLower = parts.map { $0.lowercased() }
        if allLower.contains("crit") && allLower.contains("done") {
            status = .critical
        } else if allLower.contains("crit") {
            status = .critical
        }

        // Remaining parts: [id?, start, end_or_duration].
        // `after b a` and `until b c` can appear where start/end specifiers do.
        var timelineParts: [String] = []
        for part in remaining {
            let lower = part.lowercased()
            if lower.hasPrefix("after ") {
                let refs = splitDependencyRefs(String(part.dropFirst(6)))
                afterIds.append(contentsOf: refs)
                afterId = afterId ?? refs.first
            } else if lower.hasPrefix("until ") {
                untilIds.append(contentsOf: splitDependencyRefs(String(part.dropFirst(6))))
            } else {
                timelineParts.append(part)
            }
        }

        // Classify non-dependency parts.
        // Patterns:
        //   [id, start, end]    — 3 parts
        //   [id, after X, dur]  — already handled after above
        //   [start, end]        — 2 parts, no id
        //   [id, start_or_dur]  — ambiguous: id if not date-like or duration-like
        //   [dur]               — 1 part, just duration
        //   [start]             — 1 part, just start date
        let rest = timelineParts

        switch rest.count {
        case 0:
            break
        case 1:
            // Single value: duration/date, or an id when dependency timing is supplied separately.
            let val = rest[0]
            if afterId != nil || !untilIds.isEmpty, !isDuration(val), !isDateLike(val) {
                id = val
            } else if isDuration(val) {
                duration = val
            } else {
                startDate = val
            }
        case 2:
            let first = rest[0]
            let second = rest[1]

            if afterId != nil {
                // Already have start from "after". Second is end/duration.
                if isDuration(second) {
                    duration = second
                } else {
                    endDate = second
                }
                // First must be the id.
                id = first
            } else if isDateLike(first) {
                // Both are date/duration: start + end/duration.
                startDate = first
                if isDuration(second) {
                    duration = second
                } else {
                    endDate = second
                }
            } else {
                // First is id, second is start or duration.
                id = first
                if isDuration(second) {
                    duration = second
                } else {
                    startDate = second
                }
            }
        default:
            // 3+ parts: [id, start, end_or_duration] or [id, after X, dur].
            if afterId != nil {
                // "after" already consumed. Rest: [id, end/dur] or [id, ..., end/dur].
                id = rest[0]
                let last = rest[rest.count - 1]
                if isDuration(last) {
                    duration = last
                } else {
                    endDate = last
                }
            } else {
                // [id, start, end_or_duration]
                id = rest[0]
                startDate = rest[1]
                let last = rest[rest.count - 1]
                if isDuration(last) {
                    duration = last
                } else {
                    endDate = last
                }
            }
        }

        return GanttTask(
            name: MermaidTextUtils.normalizeLabel(name),
            id: id,
            status: status,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            afterId: afterId,
            afterIds: afterIds,
            untilIds: untilIds
        )
    }

    // MARK: - Classification helpers

    /// Check if a string looks like a Mermaid duration: `500ms`, `30s`, `1.5d`, `2w`, `1M`, `1y`.
    private static func isDuration(_ value: String) -> Bool {
        let pattern = #"^\d+(?:\.\d+)?(?:ms|s|m|h|d|w|M|y)$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Check if a string looks like a date (contains digits and dashes/slashes).
    private static func isDateLike(_ value: String) -> Bool {
        // Matches patterns like 2024-01-01, 01/05, etc.
        let hasDigit = value.contains(where: \.isNumber)
        let hasSeparator = value.contains("-") || value.contains("/")
        return hasDigit && hasSeparator
    }
}

// MARK: - String helper

private extension String {
    /// Returns the remainder after a prefix, or nil if the prefix doesn't match.
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

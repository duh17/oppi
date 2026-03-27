import Foundation

/// Parser for Mermaid gantt chart syntax.
///
/// Handles: title, dateFormat, axisFormat, excludes, sections, and tasks
/// with status markers (active, done, crit, milestone), dates, durations,
/// and `after` dependencies.
enum MermaidGanttParser {
    nonisolated static func parse(lines: [String]) -> GanttDiagram {
        var title: String?
        var dateFormat = "YYYY-MM-DD"
        var axisFormat: String?
        var excludes: [String] = []
        var sections: [GanttSection] = []

        // Accumulate tasks for the current section.
        var currentSectionName: String?
        var currentTasks: [GanttTask] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Directives
            if let value = line.strippingPrefix("title ") {
                title = value
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
                excludes.append(contentsOf: value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
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
                currentSectionName = value
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
            excludes: excludes
        )
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
            || lowerName.hasPrefix("section")
        {
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

        // Remaining parts: [id?, start, end_or_duration]
        // "after xxx" can be a start specifier.
        var idx = 0

        // Check for "after xxx" — can appear as a single part or split across parts.
        while idx < remaining.count {
            let part = remaining[idx]
            if part.lowercased().hasPrefix("after ") {
                let ref = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                afterId = ref
                idx += 1
                continue
            }
            break
        }

        // If no "after" found yet, classify remaining parts.
        // Patterns:
        //   [id, start, end]    — 3 parts
        //   [id, after X, dur]  — already handled after above
        //   [start, end]        — 2 parts, no id
        //   [id, start_or_dur]  — ambiguous: id if not date-like or duration-like
        //   [dur]               — 1 part, just duration
        //   [start]             — 1 part, just start date
        let rest = Array(remaining[idx...])

        switch rest.count {
        case 0:
            break
        case 1:
            // Single value: duration or date.
            let val = rest[0]
            if isDuration(val) {
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
            } else if first.lowercased().hasPrefix("after ") {
                afterId = String(first.dropFirst(6)).trimmingCharacters(in: .whitespaces)
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
                // Check if second element is "after X".
                let second = rest[1]
                if second.lowercased().hasPrefix("after ") {
                    id = rest[0]
                    afterId = String(second.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if rest.count > 2 {
                        let last = rest[rest.count - 1]
                        if isDuration(last) {
                            duration = last
                        } else {
                            endDate = last
                        }
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
        }

        return GanttTask(
            name: name,
            id: id,
            status: status,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            afterId: afterId
        )
    }

    // MARK: - Classification helpers

    /// Check if a string looks like a duration: `3d`, `1w`, `2h`, `30m`, `5s`.
    private static func isDuration(_ value: String) -> Bool {
        let pattern = #"^\d+[dwmhs]$"#
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

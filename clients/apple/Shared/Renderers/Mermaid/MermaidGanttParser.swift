import Foundation

/// Parser for Mermaid gantt chart syntax.
///
/// Handles: title, dateFormat, axisFormat, excludes, sections, and tasks
/// with status markers (active, done, crit, milestone), dates, durations,
/// and `after` dependencies.
enum MermaidGanttParser {
    nonisolated static func parse(lines: [String]) -> GanttDiagram {
        // TODO: implement
        .empty
    }
}

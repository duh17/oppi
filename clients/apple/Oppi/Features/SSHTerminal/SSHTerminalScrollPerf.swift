import os

/// Signpost intervals for the terminal's scroll pipeline, so Instruments (the
/// os_signpost instrument, category `SSHTerminalScroll`) shows where a gesture's
/// frame time goes: the display-link frame (`drawFrame`) and its two big parts
/// (`engineFrame`, `encode`), the output the main actor parses between frames
/// (`ingest`), a Rex snapshot's history decode (`restoreHistory`), and the
/// whole gesture (`scrollGesture`, begun and ended by `SSHTerminalScrollMeter`).
enum SSHTerminalScrollPerf {
    static let signposter = OSSignposter(subsystem: AppIdentifiers.subsystem, category: "SSHTerminalScroll")

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}

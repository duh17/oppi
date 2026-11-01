import Foundation

/// How many hosts may open their Rex connection in one pass of the Terminal page.
///
/// The page lists every saved host in Rex mode, so a page of ten hosts would ask for
/// ten sign-ins at once. The page hands out this many grants per pass; the rest wait
/// for the next pass, which a settling connection asks for. Listing is never
/// limited — only what dials.
struct SSHTerminalConnectBudget {
    /// First connections that may start in one pass.
    static let inFlight = 2

    private var remaining: Int

    init(_ capacity: Int = SSHTerminalConnectBudget.inFlight) {
        remaining = capacity
    }

    /// A grant for one first connection, or nil when this pass has none left.
    mutating func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

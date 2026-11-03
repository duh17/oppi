import Foundation

/// What a cache holds: its entry count and the byte cost each entry was given,
/// per its owner's own records. `NSCache` exposes neither, and the entries it
/// evicts by itself are invisible to that owner, so a footprint is capped by the
/// cache's limits before it is reported.
struct CacheFootprint: Equatable {
    var entries = 0
    var bytes = 0

    var isEmpty: Bool { entries == 0 && bytes == 0 }

    /// Adds one entry's cost. A cost of `.max` says the entry's memory cannot be
    /// described, and the cache cannot hold more than its byte limit anyway, so
    /// the tally saturates at that limit instead of overflowing.
    mutating func record(_ cost: Int, limit: Int) {
        entries += 1
        bytes = cost >= limit - bytes ? limit : bytes + cost
    }

    func capped(entries entryLimit: Int, bytes byteLimit: Int) -> Self {
        Self(entries: min(entries, entryLimit), bytes: min(bytes, byteLimit))
    }
}

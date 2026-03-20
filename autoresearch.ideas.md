# Optimization Ideas

## High Impact (algorithmic)
- Pre-calculated heights for finalized assistant messages: cache on `isDone` transition, skip self-sizing for history items
- Height cache warmed during `loadSession()` trace replay — eliminates cascade for cold start
- Skip layoutIfNeeded() for off-screen cells during attached streaming (only visible cells matter)
- Batch multiple structural changes into one animated apply (tool start+output+end in single snapshot)

## Medium Impact (framework avoidance)
- Adaptive coalescer interval: faster for simple timelines (< 30 items), slower for heavy
- Structural insert animation tuning: shorter duration, lighter easing
- Reduce reconfigureItems candidates during streaming (most items are immutable)
- Use `reloadItems` vs `reconfigureItems` selectively based on change type

## Lower Impact (allocation/micro)
- ProcessBatch: avoid intermediate array allocations in event grouping
- ItemIndex: inline hash function for String IDs
- ChatItem Equatable: short-circuit on id before comparing payloads
- Use ContiguousArray for items/IDs in hot paths

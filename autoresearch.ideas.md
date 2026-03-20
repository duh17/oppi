# Optimization Ideas

## Tried / Exhausted
- ~~Pre-calculated heights for finalized assistant messages~~ — tried via CellHeightCache, issue is layout ESTIMATE not measurement speed
- ~~Batch multiple structural changes into one animated apply~~ — done (tool start+output+end batched)
- ~~Reduce reconfigureItems candidates during streaming~~ — done (isStreamingMutableItem narrowing)
- ~~Skip layoutIfNeeded() for off-screen cells~~ — coordinator already skips during attached streaming
- ~~Height cache warmed during loadSession()~~ — CellHeightCache doesn't help with compositional layout's global estimate
- ~~Use `reloadItems` vs `reconfigureItems` selectively~~ — reconfigure is already the right path
- ~~Incremental NSTextStorage append~~ — correctness risk with inline markdown transitions

## Architectural (beyond autoresearch scope)
These require major refactoring, not micro-optimization loops:
- Custom UICollectionViewLayout with per-item height estimates (replaces compositional layout)
- Incremental NSTextStorage updates with formatting-aware diff (needs CommonMark AST diffing)
- Async markdown finalization (deferred cell rendering pipeline)
- Adaptive coalescer interval — needs bench to use real DeltaCoalescer, not direct processBatch

## Untried (micro, likely < 1% each)
- Disable animation for structural insert during streaming — saves UIKit animation transaction overhead
- ChatItem Equatable: short-circuit on id hash before comparing payloads
- ContiguousArray for items/IDs in hot paths
- ProcessBatch: avoid intermediate array allocations in event grouping

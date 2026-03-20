# Optimization Ideas — EXHAUSTED

All practical optimizations within the autoresearch loop have been tried.
Remaining opportunities require architectural changes.

## Architectural (beyond autoresearch scope)
- Custom UICollectionViewLayout with per-item height estimates (replaces compositional layout)
- Incremental NSTextStorage updates with formatting-aware diff (needs CommonMark AST diffing)
- Async markdown finalization (deferred cell rendering pipeline)
- Adaptive coalescer interval — needs bench to use real DeltaCoalescer

## Confirmed dead ends
- CellHeightCache (layout estimate problem, not measurement speed)
- Incremental textStorage append (correctness risk with inline markdown)
- Markdown pre-warming on agentEnd (moves cost, doesn't reduce it)
- Plan rebuild fast path (plan build is ~10μs, not the bottleneck)
- withRemovedIDs Set skip (5μs vs 55ms total)
- Lower estimated item height (drift was a measurement artifact, not height gap)
- ChatItem Equatable short-circuit / ContiguousArray / ProcessBatch arrays (micro, <1%)

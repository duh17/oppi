{
  "id": "f6bbaf82",
  "title": "iOS test: pure logic — DeltaCoalescer, ToolEventMapper, stores, extensions",
  "tags": [
    "ios",
    "testing",
    "coverage"
  ],
  "status": "done",
  "created_at": "2026-02-07T21:16:25.778Z"
}

## Goal

Test all pure-logic Core/ files with no OS dependencies. These are the easiest wins for coverage.

## Files + Coverage Target

| File | Current | Exec Lines | Target |
|------|---------|------------|--------|
| DeltaCoalescer.swift | 4% (2/49) | 49 | 90%+ |
| ToolEventMapper.swift | 0% (0/19) | 19 | 90%+ |
| SessionStore.swift | 4% (1/24) | 24 | 90%+ |
| PermissionStore.swift | 5% (1/22) | 22 | 90%+ |
| WorkspaceStore.swift | 10% (3/30) | 30 | 90%+ |
| Date+Relative.swift | 0% (0/17) | 17 | 90%+ |
| String+Path.swift | 0% (0/9) | 9 | 90%+ |

**Estimated delta: ~150 lines newly covered**

## Test Plan

### DeltaCoalescer
- Verify text/thinking deltas are batched at 33ms
- Verify tool/permission/error events flush immediately
- Verify `flushNow()` delivers pending batch
- Verify empty batches don't fire onFlush
- Verify onFlush callback receives all buffered events

### ToolEventMapper
- start → output → end sequence produces correct toolEventIds
- Multiple sequential tools get distinct IDs
- reset() clears state
- output/end without start (orphan events)

### SessionStore
- upsert inserts new session
- upsert updates existing session
- activeSessionId tracking
- sessions list ordering

### PermissionStore
- add + pending(for:) filtering
- resolve removes from pending
- expire marks expired

### WorkspaceStore
- upsert + remove
- load from API (needs mock or direct state set)

### Date+Relative
- Seconds, minutes, hours, days, weeks ago formatting
- Edge cases: future dates, zero interval

### String+Path
- lastPathComponent extraction
- Empty string, no separator, trailing separator

## Test Files to Create/Update
- `PiRemoteTests/DeltaCoalescerTests.swift` (new)
- `PiRemoteTests/ToolEventMapperTests.swift` (new)
- `PiRemoteTests/StoreTests.swift` (new — SessionStore, PermissionStore, WorkspaceStore)
- `PiRemoteTests/ExtensionTests.swift` (new — Date+Relative, String+Path)

## Verification
```bash
cd ios && xcodegen generate && xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  -enableCodeCoverage YES test
```
Check xccov report for each file >= 90%.

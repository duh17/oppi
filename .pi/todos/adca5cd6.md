{
  "id": "adca5cd6",
  "title": "iOS test: networking — ServerConnection routing + APIClient with URLProtocol mock",
  "tags": [
    "ios",
    "testing",
    "coverage"
  ],
  "status": "done",
  "created_at": "2026-02-07T21:17:13.505Z"
}

## Goal

Test the two largest untested Core/ files: ServerConnection message routing and APIClient REST calls. These are the biggest coverage gaps by line count.

## Files + Coverage Target

| File | Current | Exec Lines | Target |
|------|---------|------------|--------|
| ServerConnection.swift | 10% (19/186) | 186 | 90%+ |
| APIClient.swift | 0% (0/153) | 153 | 90%+ |

**Estimated delta: ~290 lines newly covered**

## Test Plan

### ServerConnection (10% → 90%)

The bulk of ServerConnection is `handleServerMessage()` — a pure routing function that dispatches to stores and the coalescer. Fully testable without network.

Tests needed:
- Route `.connected` → sessionStore.upsert
- Route `.state` → sessionStore.upsert
- Route `.permissionRequest` → permissionStore.add + coalescer + notification
- Route `.permissionExpired` → permissionStore.expire + coalescer
- Route `.permissionCancelled` → permissionStore.remove
- Route `.agentStart` → coalescer
- Route `.textDelta` → coalescer
- Route `.toolStart` → coalescer via toolMapper
- Route `.toolOutput` → coalescer via toolMapper
- Route `.toolEnd` → coalescer via toolMapper
- Route `.agentEnd` → coalescer
- Route `.sessionEnded` → coalescer
- Route `.error` → coalescer
- Route `.extensionUIRequest` → sets activeExtensionDialog
- Route `.extensionUINotification` → sets extensionToast
- Route `.unknown` → no-op
- Stale session guard: message for non-active session is ignored
- `configure()` with valid credentials returns true
- `configure()` with malformed host returns false
- `disconnectSession()` clears state
- `flushAndSuspend()` flushes coalescer

**Approach:** Instantiate ServerConnection directly, call `configure()`, then test `handleServerMessage()` by inspecting stores/state. No network needed.

### APIClient (0% → 90%)

Use `URLProtocol` subclass to intercept HTTP requests and return canned responses.

Tests needed:
- `health()` returns true on 200
- `health()` returns false on non-200
- `me()` decodes User
- `listSessions()` decodes session array
- `createSession()` sends correct body, decodes response
- `getSession()` returns session + messages
- `stopSession()` fallback when response has no session
- `getSessionTrace()` decodes trace events
- `deleteSession()` sends DELETE
- `listModels()` decodes models
- `registerDeviceToken()` sends correct body
- Error handling: 401, 500, malformed JSON
- `checkStatus()` extracts server error message

**Approach:** Create `MockURLProtocol` that captures requests and returns preset responses. Register in a custom `URLSessionConfiguration` passed to APIClient.

## Test Files to Create
- `PiRemoteTests/ServerConnectionTests.swift` (new)
- `PiRemoteTests/APIClientTests.swift` (new)
- `PiRemoteTests/Helpers/MockURLProtocol.swift` (new, reusable)

## Verification
```bash
cd ios && xcodegen generate && xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  -enableCodeCoverage YES test
```

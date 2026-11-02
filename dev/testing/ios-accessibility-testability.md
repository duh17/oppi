# iOS accessibility and agent testability

Part of [Testing Guide](README.md); same standard. The contract for controls a semantic journey (a person or XCUITest) must identify, activate, and observe. It does not require labelling every button or replace gesture and visual tests.

## Tool timeline headers

- The cell keeps `chat.timeline.row.<itemID>`; the actionable header is its own element, `chat.timeline.row.<itemID>.header` (stable item id, never an index or rendered text).
- With an owner activation installed the header is a button, and accessibility activation calls the same owner as collection selection, resolving the row by item id when it runs (never an index path captured at configuration). With no owner action it has no button trait and activation returns false.
- The label is a non-blank spoken summary (`Shell` plus the command; `Read`/`Write`/`Edit` plus the summary). The value is `Running`, `Completed`, `Failed`, or `Interrupted`, plus `Expanded`/`Collapsed` for a button.
- The header frame never overlaps body controls, which stay separate elements; `Open Current File` stays a custom action on the header. Reuse clears or replaces identifiers, labels, values, traits, custom actions, and hidden state.

## Identifier naming

An identifier is `<surface>.<area>[.<element>][.<key>]`: lowerCamelCase ASCII segments joined by dots, no hyphens, spaces, or display text. `<surface>` is the owning screen or component (`chat`, `composer`, `session`, `workspace`, `server`, `settings`, `fileBrowser`, `fileViewer`, `fullScreen`, `quickSession`, `sshTerminal`, `liveVoice`, `extension`, `review`, `harness`, `diag`); never add a second root for one screen.

- A repeated element ends in a stable model key (item, session, workspace, server id, path), never an index or text: `fileBrowser.row.<path>`, `chat.messageQueue.remove.<itemId>`.
- One control keeps one id across presentation modes (`fullScreen.code.close`); system Back stays `BackButton`.
- Two controls on screen at once never share an id (`expanded.composer.model` vs `session.toolbar.model`).
- An actionable row puts its id on the button, not the cell; a cell carries an id only when read-only. A row with two actions holds two real buttons (`<id>`, `<id>.disclosure`) whose touch and VoiceOver activation run the same owner action, because a content-configuration cell is itself an element and hides its children. A one-action row drawn in the list's content views stays one cell element with the id, `.button` trait, and an `accessibilityActivate()` that runs the selection's owner action (`app.cells[id]`). A recycled cell clears its id first.
- Tests find controls by id, never label; labels are copy. Known ids: `server.switcher` (label `Current server: <name>`), `fileBrowser.row.<path>` (folders end in `/`), `fileViewer.previous`/`next`, `session.toolbar.model` (label `Model`, value the model name). System chrome without an id is found by its system label; dismiss search with `XCUIApplication.dismissSearch(_:)` (`QAVerificationSupport/OppiUITestSupport.swift`).
- Existing ids stay unless the change already touches that screen and its tests (`settings.chatStyle`, `settings.row.*`); the hyphenated families (`workspace-file-editor.*`, `fullscreen-code.*`, `semantic-pick.*`, `review-comment.*`, `extension-strip-*`) are the baseline.

### The guard

`scripts/ax-id-guard.ts` runs in the iOS architecture check and first in the pre-push Apple lane. It fails on:

1. **A test identifier the app does not define:** every dotted lowerCamel literal in `OppiUITests`, `OppiE2ETests`, and `QAVerificationSupport` must match a literal or interpolated template in the app sources; prefix arguments (`accessibilityPrefix:`, `identifierPrefix:`) cover any key. A check that a removed id is absent passes whatever the app does: delete it or point it at the current id. A target absent on purpose carries `// ax-id-guard: absent-on-purpose` on its line or the line above.
2. **A new identifier that breaks the naming rule:** `scripts/ax-id-baseline.json` holds per-file counts that only go down; `bun scripts/ax-id-guard.ts --update` after renames, committed with them. Ordinary runs never write it.

`--collisions` lists conforming literals set by more than one app file (ids a query must scope).

## Live Voice call controls

- `chat.liveVoice.mute` is present for the whole call; its value always carries the call state (`Muted`, `Connecting`, `Listening`, `Speaking`, the failure), so read the state there. `chat.liveVoice.state` exists only while the field is empty. `chat.liveVoice.end` holds the send position for the whole call; `chat.send` appears beside it only with text. `chat.liveVoice.start` is another session's mic slot during a call.
- Elsewhere: `liveVoice.callStrip.open` (value: status and duration), `.mute`, `.route`, `.end` (hidden or `Dismiss` after a failure); a row on the call has `session.callBadge.<sessionId>`.

## Semantic journey proof

Query inside the relevant container and require exactly one match before activating; re-query after state changes; scroll the container a bounded number of steps. A missing or ambiguous target fails, and a coordinate tap is not semantic proof. The QA driver already refuses `firstMatch`, index matches, and coordinate taps ([qa-verification.md](qa-verification.md)); do not copy that list into another driver. In-process `accessibilityActivate` tests prove forwarding, reuse, and frame separation, not VoiceOver order (not an Oppi target). `UIValidateDump` does not print visibility, hittability, hints, or custom actions. Paired-server journeys: [iOS E2E tests](apple.md#ios-e2e-tests).

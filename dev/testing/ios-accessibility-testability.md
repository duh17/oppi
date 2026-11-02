# iOS accessibility and agent testability

Part of [Testing Guide](README.md). The contract for controls a semantic journey (a person or XCUITest) must identify, activate, and observe; it does not require labelling every button or replace gesture and visual tests.

## Visual accessibility is not a target

No captures at accessibility text sizes, no VoiceOver passes, and no fixes, waivers, tests, or follow-ups for Apple's accessibility audit (`dynamicType`, `textClipped`, `contrast`) unless Chen reports the bug. Use system text styles (or `UIFont.scaled` with `adjustsFontForContentSizeCategory`) and stop. The automation semantics this guide describes stay required.

## Tool timeline headers

- The cell keeps `chat.timeline.row.<itemID>`; the actionable header is its own element, `chat.timeline.row.<itemID>.header` (stable item id, never an index or rendered text).
- With an owner activation installed the header is a button whose accessibility activation calls the same owner as collection selection, resolving the row by item id when it runs (never an index path captured at configuration); without one it has no button trait and activation returns false.
- The label is a non-blank spoken summary; the value is the run state (`Running`, `Completed`, `Failed`, `Interrupted`), plus `Expanded`/`Collapsed` for a button.
- The header frame never overlaps body controls, which stay separate elements; `Open Current File` stays a custom action on the header. Reuse clears or replaces identifiers, labels, values, traits, custom actions, and hidden state.

## Identifier naming

An identifier is `<surface>.<area>[.<element>][.<key>]`: lowerCamelCase ASCII segments joined by dots, no hyphens, spaces, or display text. `<surface>` is the owning screen or component (`chat`, `composer`, `session`, `workspace`, `server`, `settings`, `fileBrowser`, `fileViewer`, `fullScreen`, `quickSession`, `sshTerminal`, `liveVoice`, `extension`, `review`, `harness`, `diag`); never add a second root for one screen.

- A repeated element ends in a stable model key (item, session, workspace, server id, path), never an index or text: `fileBrowser.row.<path>`, `chat.messageQueue.remove.<itemId>`.
- One control keeps one id across presentation modes (`fullScreen.code.close`); system Back stays `BackButton`.
- Two controls on screen at once never share an id (`expanded.composer.model` vs `session.toolbar.model`).
- An actionable row puts its id on the button, not the cell; a cell carries an id only when read-only. A row with two actions holds two real buttons (`<id>`, `<id>.disclosure`) whose touch and VoiceOver activation run the same owner action, because a content-configuration cell is itself an element and hides its children. A one-action row drawn in the list's content views stays one cell element with the id, `.button` trait, and an `accessibilityActivate()` that runs the selection's owner action (`app.cells[id]`). A recycled cell clears its id first.
- Tests find controls by id, never label (labels are copy). System chrome without an id is found by its system label; dismiss search with `XCUIApplication.dismissSearch(_:)` (`QAVerificationSupport/OppiUITestSupport.swift`).
- Existing ids stay unless the change already touches that screen and its tests (`settings.chatStyle`, `settings.row.*`); the hyphenated families (`workspace-file-editor.*`, `fullscreen-code.*`, `semantic-pick.*`, `review-comment.*`, `extension-strip-*`) are the baseline.

### The guard

`scripts/ax-id-guard.ts` runs in the iOS architecture check and first in the pre-push Apple lane. It fails on:

1. **A test identifier the app does not define:** every dotted lowerCamel literal in `OppiUITests`, `OppiE2ETests`, and `QAVerificationSupport` must match a literal or interpolated template in the app sources; prefix arguments (`accessibilityPrefix:`, `identifierPrefix:`) cover any key. A check that a removed id is absent passes whatever the app does: delete it or point it at the current id. A target absent on purpose carries `// ax-id-guard: absent-on-purpose` on its line or the line above.
2. **A new identifier that breaks the naming rule:** `scripts/ax-id-baseline.json` holds per-file counts that only go down; `bun scripts/ax-id-guard.ts --update` after renames, committed with them. Ordinary runs never write it.

`--collisions` lists conforming literals set by more than one app file (ids a query must scope).

## Live Voice call controls

- `chat.liveVoice.mute` is present for the whole call and its value always carries the call state, so read the state there; `chat.liveVoice.state` exists only while the field is empty. `chat.liveVoice.end` holds the send position for the whole call (`chat.send` appears beside it only with text); `chat.liveVoice.start` is another session's mic slot during a call.
- Elsewhere: `liveVoice.callStrip.open` (value: status and duration), `.mute`, `.route`, `.end`; a row on the call has `session.callBadge.<sessionId>`.

## Semantic journey proof

Query inside the relevant container and require exactly one match before activating; re-query after state changes; scroll the container a bounded number of steps. A missing or ambiguous target fails, and a coordinate tap is not semantic proof. The QA driver already enforces this ([What it refuses](qa-verification.md#what-it-refuses)); do not copy that list into another driver. In-process `accessibilityActivate` tests prove forwarding, reuse, and frame separation, not VoiceOver order. `UIValidateDump` does not print visibility, hittability, hints, or custom actions.

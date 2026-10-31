# iOS accessibility and agent testability

Use native control semantics so a person and an XCUITest driver can identify a control, activate it, and observe the result. This page is the contributor contract for controls a semantic journey must drive. It is not a requirement to label every textual `Button`, and it does not replace gesture or visual tests.

## Tool timeline headers

- The timeline cell keeps `chat.timeline.row.<itemID>`.
- The independently actionable header is its own element: `chat.timeline.row.<itemID>.header`. The identifier is the stable item ID, never a row index or rendered text.
- When the timeline owner installs an activation, the header is a button. Accessibility activation calls that owner. The owner resolves the row by item ID when it runs, not from an index path captured at configuration time. Collection selection uses the same owner.
- The label is a spoken tool summary and must not be blank. Expanded shell rows speak `Shell` plus the command even when the painted title is empty. File rows speak `Read`, `Write`, or `Edit` plus the visible summary, because the icon is not spoken.
- The value is the execution state: `Running`, `Completed`, `Failed`, or `Interrupted`. A button also appends `Expanded` or `Collapsed`. Those words are English fixture strings, not identifiers.
- A header with no owner action does not use the button trait, and accessibility activation returns false. Do not advertise an expansion the owner will not perform.
- Interactive ask rows expand for inspection on the same owner as a tap, so their headers are buttons. That activation changes expansion state; it is not a no-op.
- The header stays distinct from expanded body content. Body controls, including audio play and expand controls and tip dismiss, stay separate elements. The header accessibility frame must not overlap those controls.
- When `Open Current File` is available, that custom action stays on the header element.
- Reuse clears or replaces identifiers, labels, values, traits, custom actions, and hidden state, including placeholder or non-tool chrome.

## Identifier naming

An identifier is `<surface>.<area>[.<element>][.<key>]`. Segments are lowerCamelCase ASCII joined by dots, with no hyphens, spaces, or display text. `<surface>` is the screen or shared component that owns the control (`chat`, `composer`, `session`, `workspace`, `server`, `settings`, `fileBrowser`, `fileViewer`, `fullScreen`, `quickSession`, `sshTerminal`, `liveVoice`, `extension`, `review`, `harness`, `diag`). Use the root the owning screen's route is called; do not add a second root for one screen.

- **A repeated element ends in a stable model key** (item id, session id, workspace id, server id, path, symbol name), never an index or rendered text: `lockBadge.locked.<sessionId>`, `fileBrowser.row.<path>`, `chat.messageQueue.remove.<itemId>`. Without the key every row gets the same id and a test must fall back to `firstMatch`.
- **One control, one id across presentation modes.** The code viewer's leave control is `fullScreen.code.close` as a sheet and when pushed. System Back stays `BackButton`.
- **Two controls on screen at once do not share an id.** The expanded composer sits over the chat's composer bar, so its model and thinking buttons are `expanded.composer.model` and `expanded.composer.thinking`; the bar keeps `session.toolbar.model` and `session.toolbar.thinking`.
- **An actionable row puts its id on the button**, not the cell. A cell carries an id only for a read-only row. A Rex session on the Terminal tab has two actions (open it, show its panes), so its cell holds two real buttons and draws no list content of its own: the row (a `UIButton` drawing the name and detail, whose touch and VoiceOver activation both run `touchUpInside`, the same owner action; found as `app.buttons[id]`) and the disclosure (`app.buttons[id + ".disclosure"]`). The row button carries the swipe's actions (and the disclosure's) as custom actions. A list cell that draws text through a content configuration is itself an element and hides such children, which is why the session cell draws in a button. A one-action row whose content is in the list's content views (a Rex pane on the Terminal tab, the multiplexer overview's rows) stays a single cell element: it carries the id, label, value, and `.button` trait, overrides `accessibilityActivate()` to run the same owner action as its selection, and a test finds it as `app.cells[id]`. A cell that is recycled for several row kinds clears its id first (`cell.accessibilityIdentifier = nil`), so a recycled action row does not keep its id as another row.
- **A test finds a control by its id, not its label.** The label is copy, and a test reads it only to assert the copy. Controls that tests reach: `server.switcher` (the server pill or rail item; its label is `Current server: <name>`), `fileBrowser.row.<path>` (a folder's path ends in `/`), `fileViewer.previous` and `fileViewer.next`. System chrome without an id (alert buttons) is found by its system label; the search bar's dismiss, which differs by width, goes through `XCUIApplication.dismissSearch(_:)` in `QAVerificationSupport/OppiUITestSupport.swift`.

Existing identifiers stay unless a change already touches that screen and its tests. `settings.chatStyle` and `settings.row.*` stay. The hyphenated families (`workspace-file-editor.*`, `fullscreen-code.*`, `semantic-pick.*`, `review-comment.*`, `extension-strip-*`) are the baseline below.

### The guard

`scripts/ax-id-guard.ts` runs in the iOS architecture check (`bun server/scripts/check-architecture-boundaries.ts --scope ios`) and, directly, at the start of the pre-push Apple lane, so a push that changes any Apple source, UI or E2E test, or the guard itself runs it. It fails on two things:

1. **A test identifier the app does not define.** Every dotted, lowerCamel-rooted string literal in `OppiUITests`, `OppiE2ETests`, and `QAVerificationSupport` must match a string literal or an interpolated template in the app sources (`Oppi`, `OppiCore`, `Shared`, `OppiDebugHarness`, the extensions). An id built from a prefix argument (`accessibilityPrefix:`, `identifierPrefix:`) plus a key resolves for any key under that prefix. A lookup of a removed id fails on a simulator, and a check that it is absent passes whatever the app does, so delete the check or point it at the current id. A target that is absent on purpose (the QA negative proofs) carries `// ax-id-guard: absent-on-purpose` on its line or the line above. A flat kebab id, or a template with fewer than four literal characters, is not judged.
2. **A new identifier that breaks the naming rule.** The identifiers that already break it are a ratchet: `scripts/ax-id-baseline.json` holds a count per file, a file absent from it has baseline 0, and a count may only go down. After renaming ids, `bun scripts/ax-id-guard.ts --update` lowers the baseline; commit the reduced file with the rename. Ordinary runs never write it. Only literals set through `accessibilityIdentifier`, `identifier:`, or `accessibilityPrefix:` are counted.

`bun scripts/ax-id-guard.ts --collisions` also lists each conforming literal that more than one app file sets (the ids a query must scope).

## Model control

The model control keeps `session.toolbar.model`. Its purpose label is `Model`. Its value is the displayed model name. The expanded composer's own copy is `expanded.composer.model` (see Identifier naming).

## Live Voice call controls

During a call the chat input bar is the call surface:

- `chat.liveVoice.mute` is the mic slot. It is present for the whole call, its label is `Mute` or `Unmute`, and its value always carries the call state: `Muted`, or the status (`Connecting`, `Listening`, `Speaking`, the failure). Read the call state from this value.
- `chat.liveVoice.state` is the visible status in the empty field. It exists only while the field is empty; the user's live transcript or a typed message replaces it.
- `chat.liveVoice.end` holds the send position for the whole call, including after a failure until End. `chat.send` sits beside it only while there is text to send.
- `chat.liveVoice.start` is another session's mic slot while a call has the microphone: label `Live Voice`; activation asks to end the other call (End & Call, Cancel).

Every other screen shows the call strip, `liveVoice.callStrip`:

- `liveVoice.callStrip.open` reopens the call's session. Its label names the call and session (`Live Voice call, <title>`, `Live Voice call failed, <title>`, or just `Live Voice call` while a lock hides the title); its value is the status, `Muted` when muted, and the duration, read when focused.
- `liveVoice.callStrip.mute`: label `Mute`, value `Muted` or `Not muted`. Hidden after a failure.
- `liveVoice.callStrip.route` is the system audio route picker. Hidden after a failure.
- `liveVoice.callStrip.end`: label `End call`, or `Dismiss` after a failure.
- A session row on the call has `session.callBadge.<sessionId>`, spoken in the row's label.

## Semantic journey proof

Query inside the relevant container and require one match before activation. Re-query after state changes or list virtualization. Scroll that container a bounded number of steps to reveal offscreen content. A missing or ambiguous target fails; a coordinate tap is not semantic proof.

The QA driver already refuses `firstMatch`, index matches, and coordinate taps. See [qa-verification.md](qa-verification.md). Do not copy that refusal list into another driver.

In-process `accessibilityActivate` tests prove forwarding, reuse, and frame separation. They do not prove VoiceOver reading order, which is not an Oppi target (see `AGENTS.md`). Device checks stay human-only.

`UIValidateDump` prints a role, nonempty identifiers and labels, a string value only when it differs from the label, `disabled`, and `selected`. It does not print visibility, hittability, hints, or custom actions. This page does not add a runner. Paired-server journey commands stay in [Apple: iOS E2E tests](apple.md#ios-e2e-tests).

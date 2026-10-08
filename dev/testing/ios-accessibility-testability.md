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

## Model control

The model control keeps `session.toolbar.model`. Its purpose label is `Model`. Its value is the displayed model name.

## Semantic journey proof

Query inside the relevant container and require one match before activation. Re-query after state changes or list virtualization. Scroll that container a bounded number of steps to reveal offscreen content. A missing or ambiguous target fails; a coordinate tap is not semantic proof.

The QA driver already refuses `firstMatch`, index matches, and coordinate taps. See [qa-verification.md](qa-verification.md). Do not copy that refusal list into another driver.

In-process `accessibilityActivate` tests prove forwarding, reuse, and frame separation. They do not prove VoiceOver reading order. VoiceOver and device checks stay human-only.

`UIValidateDump` prints a role, nonempty identifiers and labels, a string value only when it differs from the label, `disabled`, and `selected`. It does not print visibility, hittability, hints, or custom actions. This page does not add a runner. Paired-server journey commands stay in [Apple: iOS E2E tests](apple.md#ios-e2e-tests).

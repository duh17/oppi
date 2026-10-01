# Oppi server architecture: Tool inspection

Part of [Oppi server architecture](../architecture-server.md). Producer facts, the mobile-renderer registry, and full tool-output ownership.

## Tool inspection facts

`MobileRendererRegistry` owns tool identity and matches Pi's exact tool name. Its focused modules own collapsed segments (`mobile-renderer-segments.ts`), input/output facts (`mobile-renderer-facts.ts`), display names (`mobile-renderer-display.ts`), and availability (`mobile-renderer-availability.ts`). The registry keeps sidecar loading and invalid-warning deduplication in one place; there is no second registry. Built-in `bash` and arbitrary renderer sidecars declare command fields through `inputPresentation.fields` (`role: "command"`, `language: "shell"`) and terminal output through `outputPresentation.kind`. Session protocol projection and trace replay consume these facts; neither keeps a shell-name list. History resolves facts from the current registry even when summary segments are not requested.

Built-in read/write/edit declare `filePath`, `fileContent`, `edits` (oldText/newText pairs), and optional `lineOffset`/`lineLimit` roles. Output kinds `fileContent` and `diffOfEdits` carry optional `provenance: requested | result`; write content is requested, read content and result diffs are results. Args-derived edit previews remain requested. Sidecars can declare the same facts for any exact tool name. Apple models tolerate missing/unknown fields and use generic inspection without facts.

Explicit result `details.outputPresentation` overrides the static declaration. `details.expandedText` also overrides it: terminal format keeps terminal semantics; other formats emit structured semantics so clients clear an earlier terminal declaration. Unknown explicit kinds degrade to structured output. Missing facts on old servers select generic inspection, not a client tool-name fallback.

## Full output and snapshot lifetime

Result `outputAvailability` projects Pi truncation and full-output-source availability as `{ complete, totalBytes?, source? }`. The optional source is `"sidecar"`, never a filesystem path. Live and history publication strip `details.fullOutputPath` and path-bearing truncation members after deriving availability; the original details remain server-owned for sidecar lookup. A source fact permits tool-call-ID reads but does not promise the file survives a stopped session. Terminal transport over 8 KB sends bounded replace-mode tail previews. Live `tool_output.outputAvailability` advertises the full-output endpoint: HEAD/Range and JSON read Pi's file when present, otherwise Oppi's current uncut runtime snapshot. Pi file paths are captured on updates as well as completion. An untruncated final result replaces the preview with full inline text, matching history. `ToolOutputSnapshots` in `tool-output-sidecar.ts` owns each runtime's in-memory uncut output and the tool-end-to-trace handoff. The protocol translator calls this owner instead of maintaining a partial-result map. Pi-truncated snapshots remain delta baselines and cannot be served as full output. Oppi keeps its complete handoff snapshot until `turn_end`, after Pi has appended results; subsequent endpoint reads can use complete trace text. Truncated trace text never substitutes for a missing Pi file. Clients preserve preview completeness until full inline output or a complete sidecar read arrives. Input roles, output semantics, and completeness are independent facts carried through live events and trace replay.

## Setting authority and outline projection

The registry also declares `outputPresentation.settingEffect: "voiceReplyMode"` for session-setting producers. Explicit result details can override content semantics, but cannot grant themselves a setting effect. Managed events, mirror events, and history use the same declaration.

Lightweight trace outlines use this registry too. They carry bounded arguments, input/output facts, display metadata, and selected diff details so clients outside the local trace window do not classify raw tool names. Compaction is a separate session entry, not a synthetic tool.

Neither the session runtime nor the terminal mirror captures Pi tool-result TUI render snapshots. Generic output with empty text renders structured result details using the client document renderer. This does not remove the separate terminal mirror runtime or its owner-socket protocol.

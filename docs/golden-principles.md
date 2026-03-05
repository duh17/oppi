# Golden Principles

Mechanical invariants that keep Oppi legible, safe, and agent-friendly.

## Boundaries

- **Parse external data at the boundary and pass only validated typed values downstream.**  
  Why: Boundary parsing localizes trust decisions and prevents wire-shape leaks from contaminating core logic.  
  Verify: `AGENTS.md` (Code Quality: "Validate at boundaries") and type contracts in `server/src/types.ts` (manual review of route/parser call sites).

- **Update protocol contracts in lockstep across server types, iOS models, and protocol tests.**  
  Why: Paired updates prevent schema drift that breaks cross-platform sessions in subtle ways.  
  Verify: `AGENTS.md` (Protocol Discipline), `server/src/types.ts`, `ios/Oppi/Core/Models/ServerMessage.swift`, `ios/Oppi/Core/Models/ClientMessage.swift`, `docs/testing/requirements-matrix.md` (`RQ-PROTO-001`, `RQ-PROTO-002`).

- **Decode unknown server message types as non-fatal unknown cases and continue processing.**  
  Why: Forward-compatible decoding lets newer servers interoperate with older clients without crashing.  
  Verify: `ios/Oppi/Core/Models/ServerMessage.swift` (`case unknown(type:)`, `default: self = .unknown(type:)`) and `docs/testing/requirements-matrix.md` (`RQ-PROTO-001`).

## Store isolation

- **Keep each `@Observable` store focused on one concern and avoid cross-store coupling in view update paths.**  
  Why: Single-concern stores reduce re-render churn and make state ownership obvious during debugging.  
  Verify: `AGENTS.md` (Observable stores guidance) and store composition in `ios/Oppi/Core/Networking/ServerConnection.swift` (manual review of view read paths).

- **Centralize orchestration in `ServerConnection` and treat stores/reducers as leaf collaborators.**  
  Why: A single coordinator avoids split-brain lifecycle logic across networking, permissions, and timeline state.  
  Verify: class docs and wiring in `ios/Oppi/Core/Networking/ServerConnection.swift`.

- **Reduce timeline events through deterministic reducer functions and keep side effects outside the reducer pipeline.**  
  Why: Deterministic reductions make replay, regression testing, and incremental rendering reliable.  
  Verify: reducer docs and `processBatch/process/loadSession` flow in `ios/Oppi/Core/Runtime/TimelineReducer.swift` plus invariant tests listed in `docs/testing/requirements-matrix.md` (`RQ-TL-001`, `RQ-TL-004`).

## Concurrency

- **Annotate `@Observable` classes with `@MainActor` unless a documented exception is required.**  
  Why: Main-actor ownership prevents accidental cross-thread mutation in UI-facing state stores.  
  Verify: `AGENTS.md` (Swift rules) and declarations in `ios/Oppi/Core/Networking/ServerConnection.swift` and `ios/Oppi/Core/Runtime/TimelineReducer.swift`.

- **Run heavy CPU work in `Task.detached` instead of inherited-main-actor tasks.**  
  Why: Detached work preserves UI responsiveness by preventing background parsing from blocking the main actor.  
  Verify: markdown prewarm implementation in `ios/Oppi/Core/Runtime/TimelineReducer.swift` (`Task.detached`) and manual review of `.task` call sites.

- **Ban force unwraps in production Swift code.**  
  Why: Eliminating force unwraps turns latent runtime crashes into explicit, testable failure handling.  
  Verify: `AGENTS.md` (Swift rules) and `ios/.swiftlint.yml` (`force_unwrapping` opt-in rule).

## Rendering

- **Use `UITextView` (non-editable, non-scrollable) for multi-line text that can grow unbounded. Use `UILabel` for short fixed-size text (titles, badges, 1-2 lines).**  
  Why: `UILabel` computes full CoreText layout upfront — O(n^2) for multi-line attributed strings (577ms at 300 lines). `UITextView` uses TextKit lazy layout — O(viewport) regardless of content size (13ms at 300 lines). `UITextView` is heavier per instance, so it's wasteful for short text.  
  Verify: `UITextView` usage in `ToolTimelineRowContent.swift` (`expandedLabel`, `outputLabel`, `commandLabel`), `ThinkingTimelineRowContent.swift` (`textLabel`), `AssistantMarkdownContentView.swift` (`codeLabel`, `tableLabel`). `UILabel` retained for title/icon/badge labels.

- **Build attributed strings with `NSMutableAttributedString`, never SwiftUI `AttributedString` concatenation.**  
  Why: `AttributedString` `+` is O(n) per append, making N appends O(n^2). `NSMutableAttributedString.append()` is amortized O(1). For a 500-line file this is 64ms vs 12ms.  
  Verify: `SyntaxHighlighter.highlight()` and `ANSIParser.attributedString()` return `NSAttributedString`. SwiftUI sites convert via `AttributedString(nsResult)` at the `Task.detached` boundary.

- **Cache rendered output across streaming ticks. Never reset `attributedText` to plain text if content hasn't changed.**  
  Why: Streaming ticks re-call `apply()` at 33ms intervals. Resetting highlighted text to plain on each tick causes visible flicker and wastes the async highlight work.  
  Verify: `NativeCodeBlockView.highlightedText` cache in `AssistantMarkdownContentView.swift`. `ToolRowRenderCache` in tool row strategies.

## Server conventions

- **Avoid `any` in TypeScript and model uncertain values as explicit boundary types.**  
  Why: Explicit types keep protocol and policy logic inspectable for both humans and agents.  
  Verify: `AGENTS.md` (TypeScript rules) and `server/eslint.config.js` (`@typescript-eslint/no-explicit-any`).

- **Emit structured logs with deterministic error messages for every user-visible failure path.**  
  Why: Stable log shapes make incident triage and test assertions reproducible across runs.  
  Verify: `AGENTS.md` ("structured logs, deterministic error messages") and manual review of server handlers.

- **Express policy in declarative configs and evaluate it through the centralized policy engine.**  
  Why: Declarative policy avoids scattered permission `if` logic and keeps approvals auditable.  
  Verify: `AGENTS.md` (Server Navigation), `server/src/policy.ts` (compiled declarative policy + layered evaluation), and `config/policy-modes/` (manual review).

## Code organization

- **Treat `Oppi.xcodeproj` as generated output and change `project.yml` before regenerating with XcodeGen.**  
  Why: Editing generated artifacts causes drift and lost changes on the next generation pass.  
  Verify: `AGENTS.md` (generated project rule).

- **Keep extensions and skills in standard discovery locations so automation can load them predictably.**  
  Why: Stable paths remove environment-specific guesswork during agent bootstrap and workspace sync.  
  Verify: `server/src/types.ts` (`Workspace.extensions` comment referencing `~/.pi/agent/extensions`) and `/Users/chenda/.pi/agent/AGENTS.md` (skills path conventions).

- **Mirror product invariants to explicit test files and keep the requirements matrix current.**  
  Why: A maintained matrix prevents silent coverage gaps when architecture evolves.  
  Verify: `docs/testing/requirements-matrix.md` and coherence checks in `docs/testing/README.md` (`npm run check:testing-policy`).

## Process

- **Use conventional commits (`feat:`, `fix:`, `chore:`, `docs:`) with concise subjects.**  
  Why: Consistent commit taxonomy improves changelog generation and review triage.  
  Verify: `AGENTS.md` (Git rules/style) and `/Users/chenda/.pi/agent/AGENTS.md` (commit convention + subject length guidance).

- **Stage only explicitly changed files and never use bulk staging commands.**  
  Why: Scoped staging prevents accidental commits of unrelated work from parallel sessions.  
  Verify: `AGENTS.md` (Git Rules + Forbidden Operations).

- **Run required quality gates before committing and treat warnings/infos as failures to resolve.**  
  Why: Pre-commit gates catch protocol, lint, and platform regressions before they reach reviewers.  
  Verify: `AGENTS.md` (Commands + Definition of Done) and `docs/testing/README.md` (required gate commands).

## Privacy

- **Keep behavior analytics off, and make diagnostics mode an explicit build/runtime choice.**  
  Why: Separating analytics from diagnostics keeps product data private while allowing operational observability when needed.  
  Verify: `docs/telemetry.md` (TL;DR + mode matrix) and release defaults in `ios/scripts/release.sh`.

- **Never upload prompt text, assistant output, tool arguments, or transcript content as telemetry.**  
  Why: Conversation content is product data, not diagnostics metadata.  
  Verify: `docs/telemetry.md` (Explicit non-goals).

- **Gate diagnostics channels behind `OPPI_TELEMETRY_MODE` and support explicit public-mode shutdown.**  
  Why: A single gate keeps diagnostics predictable and allows hard-disable in privacy-sensitive contexts.  
  Verify: `docs/telemetry.md` (single telemetry gate + channel behavior details).

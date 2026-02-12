# Pi Remote — Agent Principles

This file defines project-level guardrails for `~/workspace/pios`.
Keep this file concise and principle-focused.

Use detailed operational workflows from:
- `ios/AGENTS.md` (iOS architecture/patterns)
- `README.md`, `DESIGN.md`, `IMPLEMENTATION.md`
- `oppi-dev` skill (deploy/debug/incident loops)

## Mission

Pi Remote is a mobile-supervised coding agent platform:
- `pi-remote/`: Node.js server/runtime, policy engine, permission gate
- `ios/`: Oppi iOS client (SwiftUI)

## Security Invariants (non-negotiable)

Security is the top priority, especially in host mode.

- **Fail closed.** If gate extension is missing/disconnected, deny tool calls.
- **Default to ask** in host mode unless explicitly allowed by policy.
- **Never weaken the gate** for convenience.
- **Hard denies are immutable** (privilege escalation, credential exfiltration, system config abuse).
- **Workspace/path boundaries must hold.**
- **Host bash is read-only by default.** Non-allowlisted commands require approval.

When uncertain, choose the safer behavior and call it out.

## Working Model

If user gives no concrete task:
1. Read `README.md`
2. Ask which module to work on (`pi-remote` or `ios`)

Then:
- For `pi-remote`: focus on core server/policy/session/gate files.
- For `ios`: follow `ios/AGENTS.md`.

## Architecture Principles

- No heavy framework abstraction in server core: prefer explicit Node primitives.
- Preserve JSON-lines RPC semantics between server and pi.
- Preserve layered policy semantics: hard deny → bounds → user/learned rules → default.
- Keep permissioning behavior explainable and auditable.
- Maintain clear separation of concerns (routes, sessions, gate, policy, storage).

## Protocol Discipline

When changing client/server message contracts:
1. Update `pi-remote/src/types.ts`
2. Update iOS models (`ServerMessage.swift`, `ClientMessage.swift`)
3. Update protocol tests on both sides

No partial protocol updates.

## Change Discipline

- Do not remove intentional behavior without confirming.
- Prefer backward-compatible migrations for storage/runtime changes.
- Keep changes scoped; avoid opportunistic refactors unless requested.
- Surface risks, trade-offs, and verification steps clearly.

## Testing Expectations

- For user-reported bugs, prefer adding a regression test with the fix.
- This is a strong preference, not a hard blocker.
- If a regression test is trivial and low-risk, include it in the same change.
- If not practical, document why and provide manual verification steps.

## Code Quality (TypeScript)

- Avoid `any` unless unavoidable.
- Use top-level imports only (no inline dynamic imports for normal codepaths).
- Verify external API types from installed packages before assuming shapes.
- Do not “fix” type errors by removing functionality.

## Commands (minimal)

- `cd pi-remote && npx tsc --noEmit`
- `cd pi-remote && npx vitest run`
- `cd ios && xcodebuild ... build/test` (see `ios/AGENTS.md` for exact commands)

## Git / Commit Rules

- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Keep subject under 72 chars
- Never `git add .` / `git add -A`
- Never destructive reset/clean/stash shortcuts
- Never commit unless user asks
- Track files you changed

## Communication Style

- Be concise, direct, and technical.
- No fluff.
- Be kind and explicit about uncertainty/risk.

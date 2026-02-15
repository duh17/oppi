# Bug: chained bash commands bypass permission prompts

- **Date:** 2026-02-10
- **Status:** Fixed (2026-02-10, pending release)
- **Severity:** High (policy bypass)
- **Area:** `oppi-server/src/policy.ts` (`parseBashCommand`, `matchesRule`)

## Summary

A command like:

```bash
cd /Users/dev/workspace/myproject && git push
```

executes without a permission request, even though `git push` is configured as `ask`.

This was observed in iOS chat (screenshot attached in report context): the push succeeded immediately instead of prompting on phone.

## Expected

Any `git push` should trigger a permission prompt, including when it appears in a chained shell command.

## Actual

Policy falls through to default `allow` for chained commands where the first segment is benign (`cd`, `echo`, etc.).

## Reproduction

### Runtime repro (reported)

1. Start a host-mode session.
2. Send: `cd /Users/dev/workspace/myproject && git push`
3. Observe: no `permission_request`; push runs directly.

### Unit-level repro

```ts
const host = new PolicyEngine("host");

host.evaluate({ tool: "bash", input: { command: "git push" }, toolCallId: "1" }).action
// => "ask"

host.evaluate({
  tool: "bash",
  input: { command: "cd /Users/dev/workspace/myproject && git push" },
  toolCallId: "2",
}).action
// => "allow"
```

Container preset is also affected for chained rules (example: `cd /tmp && rm -rf foo` bypasses the `rm` ask rule).

## Likely root cause

`matchesRule()` checks `rule.exec` using `parseBashCommand(command)`.

For chained commands, `parseBashCommand()` only returns the first executable token (`cd` in `cd ... && git push`).

So rules like:

- `exec: "git", pattern: "git push*"`
- `exec: "rm", pattern: "rm *-*r*"`
- `exec: "ssh"`

never match when those commands are in later chain segments.

Because pattern matching is applied to the full raw command string (which starts with `cd ...`), it also misses anchored patterns like `git push*`.

## Impact

Any bash policy rule that relies on executable/pattern matching can be bypassed by prefixing a benign command and chaining with `&&`/`;`/`||`.

Examples:

- `cd <repo> && git push`
- `true && npm publish`
- `echo ok && ssh host`
- `cd /tmp && rm -rf foo` (container preset)

## Suggested fix direction

1. Parse shell command chains into segments (`&&`, `||`, `;`, newline).
2. Evaluate policy against each executable segment.
3. Use strongest resulting action across segments (`deny` > `ask` > `allow`).
4. Add regression tests for chained commands in `policy-host.test.ts` and `policy.test.ts`.

## Regression tests to add

- `cd /x && git push` => `ask`
- `true; ssh user@host` => `ask`
- `cd /tmp && rm -rf foo` (container) => `ask`
- `echo hi && npm publish` => `ask`
- ensure non-risky chains still behave as expected

## Fix implemented

- Added top-level command-chain parsing for bash (`&&`, `||`, `;`, newline).
- Policy now evaluates hard-deny/rule matches per chain segment, not only first token.
- Structural heuristics (pipe-to-shell, data egress) now evaluate per segment.
- Added regression coverage in:
  - `oppi-server/tests/policy-fuzz.test.ts`
  - `oppi-server/tests/policy-host.test.ts`
  - `oppi-server/tests/policy.test.ts`

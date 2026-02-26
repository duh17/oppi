# Prompt Engineering for Subagents

Structure prompts for dispatched sessions to maximize clarity and prevent conflicts.

## Prompt Structure

1. **Identity** — what TODO or task the agent owns
2. **Context** — what shared infrastructure already exists
3. **Scope** — exact file list the agent owns (for parallel safety)
4. **Process** — read, replace, delete, verify steps
5. **Boundary** — explicit "do NOT touch" for parallel runs
6. **Commit message** — exact conventional commit format
7. **Verification** — what checks to run before committing

## Example

```
Working on TODO-f96928a0: migrate network test files to shared test support.

Shared support files already exist at tests/support/:
- TestFactories.ts: makeTestSession(), makeTestConnection()
- TestWaiters.ts: waitForTestCondition()

Migrate these SPECIFIC files only:
- ServerConnectionTests.ts — replace private makeConnection(), makeSession() with shared versions. Delete private definitions.
- ReliabilityTests.ts — replace private makeCredentials(), makeConnection(). Delete definitions.

IMPORTANT: Do NOT touch files outside this list. Other agents are migrating other files in parallel.

After migration, run npm test to verify all tests pass.
Commit with: refactor: migrate network tests to shared test support
```

## Guidelines

- **State what already exists.** Agents waste time re-investigating when prior phases are not described.
- **Name exact shared functions.** Write `makeTestSession()` from `TestFactories.ts`, not "use the shared factories".
- **Agents may exceed scope.** One agent might migrate callers when told only to create files. This is usually fine if file sets stay disjoint. Add explicit scope boundaries to control this.
- **Specify the commit message.** Agents that commit autonomously should use the exact format provided.

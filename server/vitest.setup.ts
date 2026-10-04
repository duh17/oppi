/**
 * Isolate every Vitest worker from developer-machine state.
 *
 * Git exports repository-local variables to hooks. Tests that create fixture
 * repositories must not inherit those variables and mutate the checkout instead.
 * Integration and unit paths that call discoverLocalSessions / getPiSessionsRoot
 * must also not cold-scan ~/.pi/agent/sessions (thousands of JSONLs on busy machines).
 * OPPI_LOCAL_SESSIONS_ROOT is read dynamically by local-sessions.ts.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function sanitizeGitLocalEnvironment(
  environment: NodeJS.ProcessEnv,
  localVariableNames: Iterable<string>,
): void {
  for (const name of localVariableNames) delete environment[name];

  // GIT_CONFIG_COUNT is repository-local, but Git does not include its numbered
  // key/value companions in `rev-parse --local-env-vars`.
  for (const name of Object.keys(environment)) {
    if (/^GIT_CONFIG_(?:KEY|VALUE)_\d+$/.test(name)) delete environment[name];
  }
}

/**
 * OPPI_TAILSCALE_BIN redirects every `tailscale` lookup. A developer who exports
 * it for the macOS app CLI would make in-process tests bypass their fake-PATH
 * setups and run `<bin> cert` for real. Tests that need a specific binary set it
 * themselves; CLI spawns get a stopped fake from tests/harness/cli-process.ts.
 */
export function clearTailscaleBinaryOverride(environment: NodeJS.ProcessEnv): void {
  delete environment.OPPI_TAILSCALE_BIN;
}
clearTailscaleBinaryOverride(process.env);

const gitLocalVariableNames = execFileSync("git", ["rev-parse", "--local-env-vars"], {
  encoding: "utf8",
})
  .split("\n")
  .filter(Boolean);
sanitizeGitLocalEnvironment(process.env, gitLocalVariableNames);

const existing = process.env.OPPI_LOCAL_SESSIONS_ROOT?.trim();
const localSessionsRoot =
  existing && existing.length > 0
    ? existing
    : mkdtempSync(join(tmpdir(), "oppi-vitest-local-sessions-"));

mkdirSync(localSessionsRoot, { recursive: true });
process.env.OPPI_LOCAL_SESSIONS_ROOT = localSessionsRoot;

// Best-effort cleanup for worker-temp roots we created. Leave pre-set roots alone
// so callers can point a single suite at a fixture tree.
if (!existing) {
  const cleanup = (): void => {
    rmSync(localSessionsRoot, { recursive: true, force: true });
  };
  process.once("exit", cleanup);
}

// Pi reads mcp.json, settings, trust, and credentials from its agent dir. Sessions
// started by tests must never connect the developer's MCP servers or read their
// logins; tests that need Pi config point PI_CODING_AGENT_DIR at their own fixture.
const piAgentDir = mkdtempSync(join(tmpdir(), "oppi-vitest-pi-agent-"));
process.env.PI_CODING_AGENT_DIR = piAgentDir;
process.once("exit", () => rmSync(piAgentDir, { recursive: true, force: true }));

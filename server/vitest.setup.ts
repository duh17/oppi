/**
 * Isolate every Vitest worker from the developer's real Pi TUI sessions tree.
 *
 * Integration and unit paths that call discoverLocalSessions / getPiSessionsRoot
 * must not cold-scan ~/.pi/agent/sessions (thousands of JSONLs on busy machines).
 * OPPI_LOCAL_SESSIONS_ROOT is read dynamically by local-sessions.ts.
 */
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

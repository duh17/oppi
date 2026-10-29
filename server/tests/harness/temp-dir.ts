/**
 * Temp directories that a test file removes when it finishes.
 *
 * Each file's TMPDIR is private and checked for leftovers (vitest.temp-guard.ts), so a
 * directory made with a bare `mkdtempSync(join(tmpdir(), ...))` fails its file unless the
 * test removes it. `makeTempDir` removes every directory it made in an `afterAll`. That hook
 * registers at import, before the importing file's own hooks, so it runs after them: servers
 * and children the file stops in its own `afterEach`/`afterAll` are gone before removal.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll } from "vitest";

const created: string[] = [];

afterAll(() => {
  for (const dir of created.splice(0))
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

/** `mkdtempSync(join(tmpdir(), prefix))`, removed when the test file finishes. */
export function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  created.push(dir);
  return dir;
}

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

const script = fileURLToPath(new URL("../scripts/ensure-installed-deps.mjs", import.meta.url));
const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/** A dependency-free server directory whose node_modules is out of sync with its lockfile. */
function staleServer(): string {
  const root = mkdtempSync(join(tmpdir(), "ensure-deps-"));
  roots.push(root);
  mkdirSync(join(root, "scripts"));
  cpSync(script, join(root, "scripts", "ensure-installed-deps.mjs"));
  writeFileSync(
    join(root, "package.json"),
    JSON.stringify({ name: "fake-server", version: "1.0.0" }),
  );
  writeFileSync(
    join(root, "package-lock.json"),
    JSON.stringify({
      name: "fake-server",
      version: "1.0.0",
      lockfileVersion: 3,
      packages: { "": { name: "fake-server", version: "1.0.0" } },
    }),
  );
  mkdirSync(join(root, "node_modules"));
  writeFileSync(
    join(root, "node_modules", ".package-lock.json"),
    JSON.stringify({
      lockfileVersion: 3,
      packages: { "node_modules/left-over": { version: "1.0.0" } },
    }),
  );
  return root;
}

function ensure(root: string) {
  return spawnSync("node", [join(root, "scripts", "ensure-installed-deps.mjs")], {
    encoding: "utf8",
  });
}

describe("ensure-installed-deps", () => {
  it("does not reinstall while a build imports packages from server/node_modules", () => {
    const root = staleServer();
    mkdirSync(join(root, "dist", ".builds", "20260101-000000-000000000", "src"), {
      recursive: true,
    });

    const result = ensure(root);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain("dist/.builds/20260101-000000-000000000");
    expect(existsSync(join(root, "node_modules", ".package-lock.json"))).toBe(true);
  });

  it("reinstalls once every build has its own node_modules", () => {
    const root = staleServer();
    mkdirSync(join(root, "dist", ".builds", "20260101-000000-000000000", "node_modules"), {
      recursive: true,
    });

    const result = ensure(root);

    expect(result.stderr).toContain("npm ci in server/");
    expect(result.status).toBe(0);
    expect(
      existsSync(join(root, "dist", ".builds", "20260101-000000-000000000", "node_modules")),
    ).toBe(true);
  });
});

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { CLI, cliSpawnEnv } from "./harness/cli-process.js";

it("flag-off CLI loads no Durable implementation or pi-durable modules", () => {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-cli-graph-"));
  const graph = join(dir, "resolved-urls.txt");
  const hook = join(dir, "resolve-hook.mjs");
  writeFileSync(graph, "");
  writeFileSync(
    hook,
    `import { registerHooks } from "node:module";
import { appendFileSync } from "node:fs";
registerHooks({ resolve(specifier, context, nextResolve) {
  const result = nextResolve(specifier, context);
  appendFileSync(${JSON.stringify(graph)}, result.url + "\\n");
  return result;
} });
`,
  );
  const stdout = execFileSync(process.execPath, ["--import", hook, CLI, "config", "get", "port"], {
    encoding: "utf8",
    env: cliSpawnEnv({ ...process.env, OPPI_DATA_DIR: dir }),
    timeout: 15_000,
  });
  expect(stdout.trim()).toBe("7749");
  const urls = readFileSync(graph, "utf8").trim().split("\n");
  // Check that the hook actually observed the entry point, not an empty trace.
  expect(urls.some((url) => url.endsWith("/cli.js"))).toBe(true);
  expect(
    urls.filter(
      (url) =>
        url.includes("/@earendil-works/pi-durable/") ||
        /\/src\/durable-(backend|harness|event-adapter)\.js$/.test(url),
    ),
  ).toEqual([]);
  console.info(`Flag-off CLI import-graph artifacts: ${dir}`);
}, 20_000);

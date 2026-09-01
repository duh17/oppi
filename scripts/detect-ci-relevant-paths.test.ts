import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const script = join(import.meta.dir, "detect-ci-relevant-paths.sh");
const applePatterns = [
  "clients/apple/**",
  "protocol/**",
  "server/src/types/protocol.ts",
  "server/src/types/session.ts",
  "server/src/types/icon.ts",
  "server/src/types/git.ts",
  "server/src/types/shared.ts",
  "server/src/thinking-levels.ts",
  ".github/workflows/apple.yml",
];
const serverPatterns = [
  "server/**",
  "protocol/**",
  "clients/apple/OppiCore/Models/**",
  ".github/workflows/server.yml",
];

function detect(
  event: string,
  files: string[],
  patterns: string[],
): { stdout: string; status: number } {
  const result = spawnSync("bash", [script, "--event", event, "--files-from", "-", ...patterns], {
    input: files.join("\n") + (files.length > 0 ? "\n" : ""),
    encoding: "utf8",
  });
  return { stdout: result.stdout, status: result.status ?? 1 };
}

describe("detect-ci-relevant-paths", () => {
  test("push is always relevant because the workflow already path-filtered", () => {
    const result = detect("push", ["docs/README.md"], applePatterns);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe("relevant=true");
  });

  test("rejects unknown events instead of skipping coverage", () => {
    const result = detect("workflow_dispatch", ["clients/apple/Oppi/App/OppiApp.swift"], applePatterns);
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
  });

  test.each([
    ["Apple app source", ["clients/apple/Oppi/App/OppiApp.swift"], true],
    ["Apple workflow", [".github/workflows/apple.yml"], true],
    ["protocol snapshot", ["protocol/server-messages.json"], true],
    ["docs only", ["dev/testing/README.md"], false],
    ["server-only change", ["server/src/server.ts"], false],
  ] as const)("Apple PR %s", (_name, files, relevant) => {
    const result = detect("pull_request", [...files], applePatterns);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`relevant=${relevant}`);
  });

  test.each([
    ["server source", ["server/src/server.ts"], true],
    ["Apple protocol models", ["clients/apple/OppiCore/Models/APIResponseTypes.swift"], true],
    ["server workflow", [".github/workflows/server.yml"], true],
    ["docs only", ["README.md"], false],
    ["Apple UI only", ["clients/apple/Oppi/App/OppiApp.swift"], false],
  ] as const)("server PR %s", (_name, files, relevant) => {
    const result = detect("pull_request", [...files], serverPatterns);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`relevant=${relevant}`);
  });
});

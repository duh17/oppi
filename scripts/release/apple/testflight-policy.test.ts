import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import {
  defaultRepoRoot as testflightRepoRoot,
  findReusableArchive,
  isBetaReviewAlreadySubmittedState,
  runXcodebuild,
} from "./testflight";
import { defaultRepoRoot as releaseNotesRepoRoot } from "../release-notes";

const script = resolve(import.meta.dir, "testflight.ts");
const repositoryRoot = resolve(import.meta.dir, "../../..");

async function run(
  ...args: string[]
): Promise<{ exitCode: number; output: string }> {
  const proc = Bun.spawn(["bun", script, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { exitCode, output: stdout + stderr };
}

describe("TestFlight release policy", () => {
  test("documents separate internal, external-group, and beta-review commands", async () => {
    const result = await run("--help");
    expect(result.exitCode).toBe(0);
    expect(result.output).toContain("sync-internal");
    expect(result.output).toContain("add-external-groups");
    expect(result.output).toContain("submit-beta-review");
  });

  test("rejects the old combined follow-up command before reading credentials", async () => {
    const result = await run("sync-followup", "44");
    expect(result.exitCode).not.toBe(0);
    expect(result.output).toContain("was removed");
  });

  test("requires an explicit external group", async () => {
    const result = await run("add-external-groups", "44");
    expect(result.exitCode).not.toBe(0);
    expect(result.output).toContain("at least one explicit group");
  });

  test("suppresses beta-review conflicts only for recognized submitted states", () => {
    expect(
      isBetaReviewAlreadySubmittedState("WAITING_FOR_BETA_REVIEW"),
    ).toBeTrue();
    expect(isBetaReviewAlreadySubmittedState("IN_BETA_TESTING")).toBeTrue();
    expect(isBetaReviewAlreadySubmittedState("UNKNOWN")).toBeFalse();
    expect(
      isBetaReviewAlreadySubmittedState("READY_FOR_BETA_SUBMISSION"),
    ).toBeFalse();
    expect(isBetaReviewAlreadySubmittedState("BETA_REJECTED")).toBeFalse();
  });

  test("tracked scripts locate their checkout independently of the working directory", () => {
    const original = process.cwd();
    process.chdir("/tmp");
    try {
      expect(testflightRepoRoot()).toBe(repositoryRoot);
      expect(releaseNotesRepoRoot()).toBe(repositoryRoot);
    } finally {
      process.chdir(original);
    }
  });

  test("propagates a nonzero xcodebuild exit", async () => {
    const directory = mkdtempSync("/tmp/oppi-xcodebuild-test-");
    const developerDir = resolve(directory, "Developer");
    mkdirSync(developerDir);
    const executable = resolve(directory, "xcodebuild-fail");
    const log = resolve(directory, "xcodebuild.log");
    writeFileSync(executable, "#!/bin/sh\necho archive failed >&2\nexit 42\n");
    chmodSync(executable, 0o755);
    const previous = process.env.DEVELOPER_DIR;
    process.env.DEVELOPER_DIR = developerDir;
    try {
      await expect(
        runXcodebuild(["archive"], log, 10, executable),
      ).rejects.toThrow("xcodebuild failed with exit code 42");
      expect(readFileSync(log, "utf8")).toContain("archive failed");
    } finally {
      if (previous === undefined) delete process.env.DEVELOPER_DIR;
      else process.env.DEVELOPER_DIR = previous;
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("does not retain nothrow pipelines", () => {
    expect(readFileSync(script, "utf8")).not.toContain(".nothrow()");
  });

  test("reuses only the newest verified archive of the same build, commit, and Xcode", () => {
    const root = mkdtempSync("/tmp/oppi-archive-reuse-");
    try {
      const archive = (name: string, identity?: object) => {
        mkdirSync(resolve(root, name, "Oppi.xcarchive"), { recursive: true });
        if (identity) writeFileSync(resolve(root, name, "archive-identity.json"), JSON.stringify(identity));
        return resolve(root, name);
      };
      const want = { build: 56, commit: "c1", xcode: "Xcode 27.1", localConfig: "absent" };
      const older = archive("testflight-20261022-010000", want);
      const newer = archive("testflight-20261022-020000", want);
      archive("testflight-20261022-030000", { ...want, commit: "c2" });
      archive("testflight-20261022-040000"); // archived from a dirty tree: no identity
      expect(findReusableArchive(root, want)).toBe(newer);
      rmSync(resolve(newer, "Oppi.xcarchive"), { recursive: true });
      expect(findReusableArchive(root, want)).toBe(older);
      expect(findReusableArchive(root, { ...want, build: 57 })).toBeNull();
      expect(findReusableArchive(root, { ...want, xcode: "Xcode 27.2" })).toBeNull();
      expect(findReusableArchive(root, { ...want, localConfig: "0f3a" })).toBeNull();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

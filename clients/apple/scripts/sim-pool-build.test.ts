import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildIsCurrent, buildKey, completionArgvForXctestrun, forgetBuild, planRun, recordBuild } from "./sim-pool-build";

describe("planRun", () => {
  test("a test run builds once without test-execution flags and hands them to the test phase", () => {
    const plan = planRun([
      "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test",
      "-only-testing:OppiTests/FooTests", "-skip-testing", "OppiTests/BarTests",
      "-resultBundlePath", "/tmp/r.xcresult", "-retry-tests-on-failure", "-test-iterations", "2",
      "-enableCodeCoverage", "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=X",
    ]);
    expect(plan).toEqual({
      kind: "split",
      scheme: "OppiUnitTests",
      buildArgv: [
        "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "build-for-testing",
        "-enableCodeCoverage", "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=X",
      ],
      testFlags: [
        "-only-testing:OppiTests/FooTests", "-skip-testing", "OppiTests/BarTests",
        "-resultBundlePath", "/tmp/r.xcresult", "-retry-tests-on-failure", "-test-iterations", "2",
        "-enableCodeCoverage", "YES",
      ],
    });
  });

  test("actions without a test run build in place; test products the caller owns only need a slot", () => {
    const build = ["-scheme", "Oppi", "build-for-testing"];
    expect(planRun(build)).toEqual({ kind: "build", buildArgv: build });
    expect(planRun(["-scheme", "Oppi", "build"])).toEqual({ kind: "build", buildArgv: ["-scheme", "Oppi", "build"] });
    expect(planRun(["-scheme", "Oppi", "test-without-building"])).toEqual({ kind: "slot", readsDerivedData: true });
    expect(planRun(["test-without-building", "-xctestrun", "/x/a.xctestrun"])).toEqual({ kind: "slot", readsDerivedData: false });
    // A test plan selects its own xctestrun; no scheme leaves nothing to find one by.
    expect(planRun(["-scheme", "Oppi", "-testPlan", "P", "test"])).toEqual({ kind: "slot", readsDerivedData: false });
    expect(planRun(["test"])).toEqual({ kind: "slot", readsDerivedData: true });
  });

  test("a unit-shard xctestrun run is parsed for completion like the scheme test it stands for", () => {
    const shard = ["test-without-building", "-xctestrun", "/r/Build/Products/OppiUnitTests_iphonesimulator27.1-arm64.xctestrun",
      "-collect-test-diagnostics", "never", "-only-testing:OppiTests", "-skip-testing:OppiTests/A"];
    expect(completionArgvForXctestrun(shard)).toEqual(["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests", "-skip-testing:OppiTests/A"]);
    // Repetition changes what a finished summary means; leave such runs unparsed.
    expect(completionArgvForXctestrun([...shard, "-test-iterations", "3"])).toBeUndefined();
  });
});

describe("build stamp", () => {
  const dirs: string[] = [];
  afterAll(() => {
    for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  });

  function git(root: string, ...args: string[]): void {
    const result = spawnSync("git", ["-C", root, "-c", "user.name=t", "-c", "user.email=t@t", ...args], { encoding: "utf8" });
    if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
  }

  function checkout(): { root: string; apple: string; dd: string } {
    const root = realpathSync.native(mkdtempSync(join(tmpdir(), "build-stamp-")));
    dirs.push(root);
    const apple = join(root, "clients", "apple");
    mkdirSync(join(apple, "Oppi"), { recursive: true });
    writeFileSync(join(apple, "Oppi", "A.swift"), "let a = 1\n");
    writeFileSync(join(root, ".gitignore"), "clients/apple/.build/\nclients/apple/Vendor/\n");
    git(root, "init", "-q", "-b", "main");
    git(root, "add", ".");
    git(root, "commit", "-q", "-m", "init");
    const dd = join(apple, ".build", "dd");
    return { root, apple, dd };
  }

  const input = (fx: { root: string; apple: string }, argv = ["-scheme", "Oppi", "build"]) => ({
    root: fx.root, appleDir: fx.apple, command: "xcodebuild", argv, env: { DEVELOPER_DIR: "/nonexistent/Xcode.app/Contents/Developer" },
  });

  // Run a build the way sim-pool does: forget, "build" (write products), record.
  function build(fx: { root: string; apple: string; dd: string }, products = "one", argv?: string[]): void {
    const key = buildKey(input(fx, argv))!;
    forgetBuild(fx.dd);
    mkdirSync(join(fx.dd, "Build", "Products", "Debug-iphonesimulator", "Oppi.app"), { recursive: true });
    writeFileSync(join(fx.dd, "Build", "Products", "Debug-iphonesimulator", "Oppi.app", "Oppi"), products);
    recordBuild(fx.dd, key, () => buildKey(input(fx, argv)));
  }

  const current = (fx: { root: string; apple: string; dd: string }, argv?: string[]) => buildIsCurrent(fx.dd, buildKey(input(fx, argv))!);

  test("an unchanged checkout reuses its build; any source change rebuilds", () => {
    const fx = checkout();
    expect(current(fx)).toBe(false);
    build(fx);
    expect(current(fx)).toBe(true);
    // Tracked edit, then back to the stamped content.
    writeFileSync(join(fx.apple, "Oppi", "A.swift"), "let a = 2\n");
    expect(current(fx)).toBe(false);
    writeFileSync(join(fx.apple, "Oppi", "A.swift"), "let a = 1\n");
    expect(current(fx)).toBe(true);
    // Untracked file: its presence and its content count.
    writeFileSync(join(fx.apple, "Oppi", "B.swift"), "let b = 1\n");
    expect(current(fx)).toBe(false);
    build(fx);
    expect(current(fx)).toBe(true);
    writeFileSync(join(fx.apple, "Oppi", "B.swift"), "let b = 2\n");
    expect(current(fx)).toBe(false);
  });

  test("a new commit or another branch rebuilds, and switching back does not vouch for products built in between", () => {
    const fx = checkout();
    build(fx, "main-products");
    expect(current(fx)).toBe(true);
    git(fx.root, "switch", "-q", "-c", "other");
    writeFileSync(join(fx.apple, "Oppi", "A.swift"), "let a = 9\n");
    git(fx.root, "commit", "-q", "-am", "other");
    expect(current(fx)).toBe(false);
    build(fx, "other-products");
    expect(current(fx)).toBe(true);
    git(fx.root, "switch", "-q", "main");
    // main's key matches no stamp: the stamp now belongs to the build of `other`.
    expect(current(fx)).toBe(false);
    // An empty commit changes HEAD though the tree is the same.
    build(fx, "main-again");
    git(fx.root, "commit", "-q", "--allow-empty", "-m", "empty");
    expect(current(fx)).toBe(false);
  });

  test("another invocation, other Vendor pins, a different Xcode, or touched products do not reuse the build", () => {
    const fx = checkout();
    build(fx);
    expect(current(fx, ["-scheme", "OppiUnitTests", "build-for-testing"])).toBe(false);
    expect(buildKey({ ...input(fx), env: { DEVELOPER_DIR: "/other/Xcode.app/Contents/Developer" } })).not.toBe(buildKey(input(fx)));
    const pin = join(fx.apple, "Vendor", "TailscaleKit", "BUILD_ID");
    mkdirSync(join(fx.apple, "Vendor", "TailscaleKit"), { recursive: true });
    writeFileSync(pin, "pin-1");
    expect(current(fx)).toBe(false);
    build(fx);
    expect(current(fx)).toBe(true);
    writeFileSync(pin, "pin-2");
    expect(current(fx)).toBe(false);
    writeFileSync(pin, "pin-1");
    expect(current(fx)).toBe(true);
    // A raw xcodebuild rewrites the app behind the pool's back.
    writeFileSync(join(fx.dd, "Build", "Products", "Debug-iphonesimulator", "Oppi.app", "Oppi"), "relinked, longer");
    expect(current(fx)).toBe(false);
  });

  test("a failed or interrupted build leaves no stamp, and sources edited during the build are not vouched for", () => {
    const fx = checkout();
    build(fx);
    // The next build starts: the old stamp is gone even if the build never finishes.
    forgetBuild(fx.dd);
    expect(current(fx)).toBe(false);
    const key = buildKey(input(fx))!;
    writeFileSync(join(fx.apple, "Oppi", "A.swift"), "let a = 3\n");
    recordBuild(fx.dd, key, () => buildKey(input(fx)));
    expect(current(fx)).toBe(false);
  });

  test("a directory that is not a git checkout cannot be keyed", () => {
    const dir = realpathSync.native(mkdtempSync(join(tmpdir(), "build-stamp-nogit-")));
    dirs.push(dir);
    expect(buildKey({ root: dir, appleDir: dir, command: "xcodebuild", argv: [], env: {} })).toBeUndefined();
  });
});

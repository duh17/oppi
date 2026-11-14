import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(dirname(fileURLToPath(import.meta.url)), "generate-project.sh");

describe("generate-project.sh", () => {
  const temps: string[] = [];
  afterEach(() => {
    for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  /** A checkout with the real script, a fake xcodegen that writes a project, and tracked pins. */
  function checkout(fakeVersion = "2.46.0") {
    const root = mkdtempSync(join(tmpdir(), "oppi-generate-project-"));
    temps.push(root);
    const apple = join(root, "apple");
    mkdirSync(join(apple, "scripts"), { recursive: true });
    copyFileSync(script, join(apple, "scripts", "generate-project.sh"));
    writeFileSync(join(apple, "scripts", "xcodegen-version.txt"), "2.46.0\n");
    writeFileSync(join(apple, "project.yml"), "name: Oppi\n");
    writeFileSync(join(apple, "Package.resolved"), "pins-v1\n");
    const bin = join(root, "bin");
    mkdirSync(bin);
    writeFileSync(
      join(bin, "xcodegen"),
      `#!/bin/bash
if [[ "$1" == "--version" ]]; then echo "Version: ${fakeVersion}"; exit 0; fi
echo "$*" >> "${root}/xcodegen.calls"
mkdir -p "${apple}/Oppi.xcodeproj"
echo generated > "${apple}/Oppi.xcodeproj/project.pbxproj"
`,
      { mode: 0o755 },
    );
    const run = () =>
      spawnSync("/bin/bash", [join(apple, "scripts", "generate-project.sh")], {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` },
      });
    const tracked = join(apple, "Package.resolved");
    const copy = join(apple, "Oppi.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved");
    return { root, apple, run, tracked, copy };
  }

  test("another xcodegen version fails naming both versions, before generating anything", () => {
    const fx = checkout("2.45.1");
    const result = fx.run();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("xcodegen 2.45.1");
    expect(result.stderr).toContain("pins 2.46.0");
    expect(existsSync(join(fx.root, "xcodegen.calls"))).toBe(false);
    expect(existsSync(fx.copy)).toBe(false);
  });

  test("a fresh checkout gets the project and the tracked pins copied in", () => {
    const fx = checkout();
    const result = fx.run();
    expect(result.status).toBe(0);
    expect(readFileSync(join(fx.apple, "Oppi.xcodeproj", "project.pbxproj"), "utf8")).toBe("generated\n");
    expect(readFileSync(fx.copy, "utf8")).toBe("pins-v1\n");
  });

  test("pins that package resolution changed in the project are copied back to the tracked file", () => {
    const fx = checkout();
    expect(fx.run().status).toBe(0);
    writeFileSync(fx.copy, "pins-resolved\n");
    const result = fx.run();
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("copied them to clients/apple/Package.resolved");
    expect(readFileSync(fx.tracked, "utf8")).toBe("pins-resolved\n");
    expect(readFileSync(fx.copy, "utf8")).toBe("pins-resolved\n");
    // Copied back once: the next run leaves both alone.
    const again = fx.run();
    expect(again.stderr).toBe("");
    expect(readFileSync(fx.tracked, "utf8")).toBe("pins-resolved\n");
  });

  test("new tracked pins (a pull or branch switch) replace the project's copy, not the other way round", () => {
    const fx = checkout();
    expect(fx.run().status).toBe(0);
    writeFileSync(fx.tracked, "pins-v2\n");
    expect(fx.run().status).toBe(0);
    expect(readFileSync(fx.tracked, "utf8")).toBe("pins-v2\n");
    expect(readFileSync(fx.copy, "utf8")).toBe("pins-v2\n");
  });

  test("pins changed on both sides fail and overwrite neither", () => {
    const fx = checkout();
    expect(fx.run().status).toBe(0);
    writeFileSync(fx.tracked, "pins-v2\n");
    writeFileSync(fx.copy, "pins-resolved\n");
    const result = fx.run();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("changed in both");
    expect(readFileSync(fx.tracked, "utf8")).toBe("pins-v2\n");
    expect(readFileSync(fx.copy, "utf8")).toBe("pins-resolved\n");
  });
});

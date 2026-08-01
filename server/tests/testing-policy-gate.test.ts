import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";

import { checkTestingPolicy } from "../scripts/check-testing-policy.ts";
import vitestConfig from "../vitest.config.ts";

function explicitVitestFileExclusions(source: string): string[] {
  return [...source.matchAll(/(?:^|\s)--exclude\s+([A-Za-z0-9_./-]+)/g)].map(
    (match) => match[1]!,
  );
}

function makeFixture(
  options: {
    packageScripts?: Record<string, string>;
    gates?: Record<string, string[] | { server?: string[]; apple?: string[] }>;
    docs?: string;
    requiredTrackedFiles?: string[];
    runner?: "real" | "missing" | "nonStrictE2E";
  } = {},
) {
  const root = mkdtempSync(path.join(os.tmpdir(), "oppi-testing-policy-"));
  const serverRoot = path.join(root, "server");
  const scriptsDir = path.join(serverRoot, "scripts");
  const docsDir = path.join(root, "docs", "testing");
  mkdirSync(scriptsDir, { recursive: true });
  mkdirSync(docsDir, { recursive: true });

  const packageScripts = options.packageScripts ?? {
    check: "echo check",
    "test:coverage": "echo coverage",
    "test:e2e:linux": "echo e2e",
    "test:gate:pr-fast": "bun scripts/testing-gates.ts pr-fast",
    "test:gate:nightly-deep": "bun scripts/testing-gates.ts nightly-deep",
  };
  writeFileSync(
    path.join(serverRoot, "package.json"),
    JSON.stringify({ scripts: packageScripts }, null, 2),
  );

  const gates = options.gates ?? {
    "pr-fast": ["check", "test:coverage"],
    "nightly-deep": {
      server: ["check", "test:coverage", "test:e2e:linux"],
      apple: ["xcodebuild -scheme Oppi build"],
    },
  };
  writeFileSync(
    path.join(serverRoot, "testing-policy.json"),
    JSON.stringify(
      {
        version: 2,
        gates,
        ...(options.requiredTrackedFiles
          ? { tooling: { requiredTrackedFiles: options.requiredTrackedFiles } }
          : {}),
      },
      null,
      2,
    ),
  );

  writeFileSync(
    path.join(docsDir, "README.md"),
    options.docs ??
      "Uses server/testing-policy.json, npm run test:gate:pr-fast, and test:coverage.\n",
  );

  const runner = options.runner ?? "real";
  if (runner === "real") {
    copyFileSync(
      path.join(process.cwd(), "scripts", "testing-gates.ts"),
      path.join(scriptsDir, "testing-gates.ts"),
    );
  } else if (runner === "nonStrictE2E") {
    writeFileSync(
      path.join(scriptsDir, "testing-gates.ts"),
      `#!/usr/bin/env bun\nconsole.log("[test-gate] cmd: npm run test:e2e:linux");\n`,
    );
  }

  return {
    root,
    serverRoot,
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}

describe("testing policy gate coherence", () => {
  it("passes the current repository policy", () => {
    const result = checkTestingPolicy({
      serverRoot: process.cwd(),
      repoRoot: path.resolve(process.cwd(), ".."),
    });

    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("caps server test worker fan-out for nested subprocesses", () => {
    expect(vitestConfig.test?.maxWorkers).toBe(4);
  });

  it("keeps explicit Vitest exclusions pointed at existing test files", () => {
    const serverRoot = process.cwd();
    const repoRoot = path.resolve(serverRoot, "..");
    const configuredSources = [
      readFileSync(path.join(serverRoot, "package.json"), "utf8"),
      readFileSync(path.join(repoRoot, ".githooks", "pre-push"), "utf8"),
    ];
    const missing = configuredSources
      .flatMap(explicitVitestFileExclusions)
      .filter((relativePath) => !existsSync(path.join(serverRoot, relativePath)));

    expect(missing).toEqual([]);
  });

  it("fails when a required testing file is present but untracked", () => {
    const fixture = makeFixture({ requiredTrackedFiles: ["required-tool.ts"] });
    try {
      writeFileSync(path.join(fixture.root, "required-tool.ts"), "export {};\n");
      const result = checkTestingPolicy({ serverRoot: fixture.serverRoot, repoRoot: fixture.root });

      expect(result.ok).toBe(false);
      expect(result.errors).toContain("required testing file is not tracked: required-tool.ts");
    } finally {
      fixture.cleanup();
    }
  });

  it("fails when the canonical gate runner is missing", () => {
    const fixture = makeFixture({ runner: "missing" });
    try {
      const result = checkTestingPolicy({ serverRoot: fixture.serverRoot, repoRoot: fixture.root });

      expect(result.ok).toBe(false);
      expect(result.errors).toContain(
        "canonical gate runner missing: server/scripts/testing-gates.ts",
      );
    } finally {
      fixture.cleanup();
    }
  });

  it("fails when package gate scripts drift from the canonical runner", () => {
    const fixture = makeFixture({
      packageScripts: {
        check: "echo check",
        "test:coverage": "echo coverage",
        "test:e2e:linux": "echo e2e",
        "test:gate:pr-fast": "node scripts/old-gate.js pr-fast",
        "test:gate:nightly-deep": "bun scripts/testing-gates.ts nightly-deep",
      },
    });
    try {
      const result = checkTestingPolicy({ serverRoot: fixture.serverRoot, repoRoot: fixture.root });

      expect(result.ok).toBe(false);
      expect(result.errors).toContain(
        "package.json script test:gate:pr-fast drifted from canonical runner",
      );
    } finally {
      fixture.cleanup();
    }
  });

  it("fails when a gate references a missing npm script", () => {
    const fixture = makeFixture({
      gates: {
        "pr-fast": ["check", "missing-script"],
        "nightly-deep": { server: ["check"], apple: [] },
      },
    });
    try {
      const result = checkTestingPolicy({ serverRoot: fixture.serverRoot, repoRoot: fixture.root });

      expect(result.ok).toBe(false);
      expect(result.errors).toContain(
        "Gate 'pr-fast' references step 'missing-script' but no npm script exists in package.json",
      );
    } finally {
      fixture.cleanup();
    }
  });

  it("fails when an E2E gate dry-run is not strict", () => {
    const fixture = makeFixture({
      runner: "nonStrictE2E",
      gates: {
        "pr-fast": ["check"],
        "nightly-deep": { server: ["test:e2e:linux"], apple: [] },
      },
    });
    try {
      const result = checkTestingPolicy({ serverRoot: fixture.serverRoot, repoRoot: fixture.root });

      expect(result.ok).toBe(false);
      expect(result.errors).toContain(
        "Gate 'nightly-deep' E2E step 'test:e2e:linux' must run with E2E_STRICT=1",
      );
    } finally {
      fixture.cleanup();
    }
  });
});

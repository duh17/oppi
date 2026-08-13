import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  findComposeMountViolations,
  findScriptMountViolations,
  parseShortVolumeEntry,
} from "../scripts/check-compose-mounts.ts";

const repoRoot = resolve(__dirname, "../..");

describe("parseShortVolumeEntry", () => {
  it("parses a plain bind with options", () => {
    expect(parseShortVolumeEntry("./docker/grafana:/etc/grafana:ro")).toEqual({
      source: "./docker/grafana",
      target: "/etc/grafana",
      options: ["ro"],
    });
  });

  it("keeps ':' inside variable defaults out of the split", () => {
    const parsed = parseShortVolumeEntry("${E2E_MODELS_JSON:-/dev/null}:/data/models.json:ro");
    expect(parsed).toEqual({
      source: "${E2E_MODELS_JSON:-/dev/null}",
      target: "/data/models.json",
      options: ["ro"],
    });
  });

  it("handles nested variable defaults", () => {
    const parsed = parseShortVolumeEntry(
      "${OPPI_DATA_DIR:-${HOME}/.config/oppi}/telemetry:/var/lib/jsonl:ro",
    );
    expect(parsed?.source).toBe("${OPPI_DATA_DIR:-${HOME}/.config/oppi}/telemetry");
    expect(parsed?.options).toEqual(["ro"]);
  });

  it("returns null for non-mount list items", () => {
    expect(parseShortVolumeEntry("/root/workspace")).toBeNull();
  });
});

describe("findComposeMountViolations", () => {
  const compose = (volumes: string[]) =>
    ["services:", "  app:", "    image: node:24", "    volumes:", ...volumes].join("\n");

  it("accepts named volumes and read-only binds", () => {
    const content = compose([
      "      - app-data:/data",
      "      - ./config:/etc/app:ro",
      "      - ${HOME}/.pi/agent:/seed:ro",
    ]);
    expect(findComposeMountViolations("server/docker-compose.test.yml", content)).toEqual([]);
  });

  it("flags writable host binds", () => {
    const content = compose(["      - ../..:/repo", "      - ./reports:/out"]);
    const violations = findComposeMountViolations("server/docker-compose.test.yml", content);
    expect(violations).toHaveLength(2);
    expect(violations[0].reason).toBe("writable host bind mount");
  });

  it("ignores ports, tmpfs, and top-level named volume declarations", () => {
    const content = [
      "services:",
      "  app:",
      '    ports:',
      '      - "7750:7750"',
      "    tmpfs:",
      "      - /root/workspace",
      "    volumes:",
      "      - app-data:/data",
      "volumes:",
      "  app-data:",
    ].join("\n");
    expect(findComposeMountViolations("server/docker-compose.test.yml", content)).toEqual([]);
  });

  it("honors the allowlist only for the exact file and source", () => {
    const allowed = compose(["      - /var/run/docker.sock:/var/run/docker.sock"]);
    expect(findComposeMountViolations("server/docker-compose.yml", allowed)).toEqual([]);
    expect(findComposeMountViolations("server/e2e/docker-compose.e2e.yml", allowed)).toHaveLength(
      1,
    );
  });

  it("requires read_only on long-form bind mounts", () => {
    const writable = compose([
      "      - type: bind",
      "        source: ./reports",
      "        target: /out",
    ]);
    expect(findComposeMountViolations("server/docker-compose.test.yml", writable)).toHaveLength(1);

    const readOnly = compose([
      "      - type: bind",
      "        source: ./reports",
      "        target: /out",
      "        read_only: true",
    ]);
    expect(findComposeMountViolations("server/docker-compose.test.yml", readOnly)).toEqual([]);
  });
});

describe("findScriptMountViolations", () => {
  it("flags container runs with volume flags, including wrapped lines", () => {
    const script = ["docker run -v $(pwd):/work node:24 npm test"].join("\n");
    expect(findScriptMountViolations("scripts/x.sh", script)).toHaveLength(1);

    const wrapped = ["container run --detach \\", "  --volume /tmp:/tmp img"].join("\n");
    expect(findScriptMountViolations("scripts/y.sh", wrapped)).toHaveLength(1);
  });

  it("ignores volume-free container runs and unrelated -v flags", () => {
    const script = [
      "container run --detach --name box --memory 4G img",
      "grep -v foo bar.txt",
      "docker compose -f e2e/docker-compose.e2e.yml up -d",
    ].join("\n");
    expect(findScriptMountViolations("scripts/z.sh", script)).toEqual([]);
  });
});

describe("repository invariant", () => {
  it("tracked compose files contain no unapproved writable host binds", () => {
    const files = execFileSync("git", ["ls-files", "-z", "--", "*compose*.yml", "*compose*.yaml"], {
      cwd: repoRoot,
      encoding: "utf8",
    })
      .split("\0")
      .filter(Boolean);
    expect(files.length).toBeGreaterThan(0);

    for (const file of files) {
      const absolutePath = join(repoRoot, file);
      if (!existsSync(absolutePath)) continue;
      const content = readFileSync(absolutePath, "utf8");
      expect(findComposeMountViolations(file, content)).toEqual([]);
    }
  });
});

#!/usr/bin/env bun

// Container mount guard: containers must never get writable access to host
// directories (repo, worktree, report, or output paths). Compose files may use
// named volumes, tmpfs, or read-only host binds; scripted container runs must
// not pass volume flags at all (use compose files or
// scripts/apple-container-copy-run.sh, which copies instead of mounting).
// Deliberate writable binds are allowlisted below with a reason.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type MountViolation = {
  file: string;
  line: number;
  text: string;
  reason: string;
};

type WritableBindException = {
  file: string;
  source: string;
  reason: string;
};

// Every entry widens what a container can corrupt on the host. Keep this list
// short, and never allowlist the repo checkout or another working tree.
export const WRITABLE_BIND_EXCEPTIONS: WritableBindException[] = [
  // server/docker-compose.yml is the deployment compose, not a validation lane.
  {
    file: "server/docker-compose.yml",
    source: "${HOME}/.config/fetch",
    reason: "fetch allowlist shared with host web skills",
  },
  {
    file: "server/docker-compose.yml",
    source: "${HOME}/.cache/fetch",
    reason: "fetch cache shared with host web skills",
  },
  {
    file: "server/docker-compose.yml",
    source: "${HOME}/.cache/agent-web",
    reason: "browser cache shared with host web skills",
  },
  {
    file: "server/docker-compose.yml",
    source: "/var/run/docker.sock",
    reason: "docker-based wrappers inside oppi sessions",
  },
];

// Mask ${...} spans so ':' inside variable defaults does not split the mount
// spec (e.g. ${E2E_MODELS_JSON:-/dev/null}:/data/models.json:ro).
function maskVariableSpans(entry: string): string {
  return entry.replace(/\$\{[^}]*\}/g, (span) => "_".repeat(span.length));
}

export function parseShortVolumeEntry(
  entry: string,
): { source: string; target: string; options: string[] } | null {
  const unquoted = entry.replace(/^(["'])(.*)\1$/, "$2").trim();
  const masked = maskVariableSpans(unquoted);

  const parts: string[] = [];
  let start = 0;
  for (let index = 0; index <= masked.length; index += 1) {
    if (index === masked.length || masked[index] === ":") {
      parts.push(unquoted.slice(start, index));
      start = index + 1;
    }
  }

  if (parts.length < 2 || parts.length > 3) {
    return null;
  }

  return {
    source: parts[0],
    target: parts[1],
    options: parts[2] ? parts[2].split(",") : [],
  };
}

function isHostPathSource(source: string): boolean {
  return /^[./~$]/.test(source);
}

function isAllowlistedWritableBind(file: string, source: string): boolean {
  return WRITABLE_BIND_EXCEPTIONS.some(
    (exception) => exception.file === file && exception.source === source,
  );
}

export function findComposeMountViolations(file: string, content: string): MountViolation[] {
  const violations: MountViolation[] = [];
  const lines = content.split("\n");
  let volumesIndent: number | null = null;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^\s*(#|$)/.test(line)) {
      continue;
    }

    const indent = line.length - line.trimStart().length;
    if (volumesIndent !== null && indent <= volumesIndent) {
      volumesIndent = null;
    }

    if (volumesIndent === null) {
      if (/^\s*volumes:\s*$/.test(line)) {
        volumesIndent = indent;
      }
      continue;
    }

    const listItem = line.match(/^\s*-\s+(.*?)\s*$/);
    if (!listItem) {
      continue;
    }

    // Long-form mount: `- type: bind` followed by a more-indented key block.
    if (/^type:\s*/.test(listItem[1])) {
      const type = listItem[1].replace(/^type:\s*/, "").trim();
      let source = "";
      let readOnly = false;
      let cursor = index + 1;
      while (cursor < lines.length) {
        const blockLine = lines[cursor];
        if (/^\s*(#|$)/.test(blockLine)) {
          cursor += 1;
          continue;
        }
        const blockIndent = blockLine.length - blockLine.trimStart().length;
        if (blockIndent <= indent || /^\s*-\s/.test(blockLine)) {
          break;
        }
        const sourceMatch = blockLine.match(/^\s*source:\s*(.*?)\s*$/);
        if (sourceMatch) {
          source = sourceMatch[1];
        }
        if (/^\s*read_only:\s*true\s*$/.test(blockLine)) {
          readOnly = true;
        }
        cursor += 1;
      }

      if (type === "bind" && !readOnly && !isAllowlistedWritableBind(file, source)) {
        violations.push({
          file,
          line: index + 1,
          text: line.trim(),
          reason: "long-form bind mount without read_only: true",
        });
      }
      index = cursor - 1;
      continue;
    }

    const mount = parseShortVolumeEntry(listItem[1]);
    if (!mount || !isHostPathSource(mount.source)) {
      continue;
    }
    if (mount.options.includes("ro")) {
      continue;
    }
    if (isAllowlistedWritableBind(file, mount.source)) {
      continue;
    }

    violations.push({
      file,
      line: index + 1,
      text: line.trim(),
      reason: "writable host bind mount",
    });
  }

  return violations;
}

const CONTAINER_RUN_PATTERN = /\b(docker|podman|nerdctl|container)\b.*\b(run|create)\b/;
const VOLUME_FLAG_PATTERN = /(^|[\s"'])(-v|--volume|--mount)([\s="']|$)/;

export function findScriptMountViolations(file: string, content: string): MountViolation[] {
  const violations: MountViolation[] = [];
  const physicalLines = content.split("\n");

  // Join backslash continuations so flags on wrapped lines are still seen.
  let index = 0;
  while (index < physicalLines.length) {
    const startLine = index + 1;
    let logical = physicalLines[index];
    while (logical.endsWith("\\") && index + 1 < physicalLines.length) {
      index += 1;
      logical = logical.slice(0, -1) + " " + physicalLines[index];
    }
    index += 1;

    if (CONTAINER_RUN_PATTERN.test(logical) && VOLUME_FLAG_PATTERN.test(logical)) {
      violations.push({
        file,
        line: startLine,
        text: logical.trim().slice(0, 120),
        reason: "container run with a volume flag; use a compose file or copy-run instead",
      });
    }
  }

  return violations;
}

function listTrackedFiles(repoRoot: string, patterns: string[]): string[] {
  const output = execFileSync("git", ["ls-files", "-z", "--", ...patterns], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  return output.split("\0").filter(Boolean);
}

function run(): void {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDir, "../..");
  const selfPath = path.relative(repoRoot, fileURLToPath(import.meta.url));

  const violations: MountViolation[] = [];

  for (const file of listTrackedFiles(repoRoot, ["*compose*.yml", "*compose*.yaml"])) {
    const absolutePath = path.join(repoRoot, file);
    if (!existsSync(absolutePath)) continue;
    const content = readFileSync(absolutePath, "utf8");
    violations.push(...findComposeMountViolations(file, content));
  }

  const scriptFiles = listTrackedFiles(repoRoot, ["*.sh", "*.bash", "*.mjs", "*.ts"]).filter(
    (file) =>
      file !== selfPath && !/(^|\/)tests?\//.test(file) && !/\.(test|spec)\.[cm]?ts$/.test(file),
  );
  for (const file of scriptFiles) {
    const absolutePath = path.join(repoRoot, file);
    if (!existsSync(absolutePath)) continue;
    const content = readFileSync(absolutePath, "utf8");
    violations.push(...findScriptMountViolations(file, content));
  }

  if (violations.length === 0) {
    console.log("Container mount checks passed.");
    return;
  }

  console.error("Container mount check failed.");
  for (const violation of violations) {
    console.error(`- ${violation.file}:${violation.line} ${violation.reason}`);
    console.error(`    ${violation.text}`);
  }
  console.error(
    "Containers must not get writable host binds. Use named volumes, tmpfs, `:ro`, or scripts/apple-container-copy-run.sh.",
  );
  process.exit(1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run();
}

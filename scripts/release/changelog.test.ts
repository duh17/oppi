import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assembleSections, cutChangelog, readFragments } from "./changelog";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fragmentsDir(files: Record<string, string>): string {
  const dir = mkdtempSync(join(tmpdir(), "changelog-fragments-"));
  dirs.push(dir);
  writeFileSync(join(dir, "README.md"), "# Changelog fragments\n");
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

describe("changelog fragments", () => {
  test("assemble in section order, then file-name order, skipping empty sections", () => {
    const dir = fragmentsDir({
      "migration-notes/server.md": "- **Compatibility:** Needs `oppi-server@0.56.0`.\n",
      "fixed/b-second.md": "- **Server:** Second fix.\n",
      "added/panes.md": "- **Client:** Panes.\n- **Server:** Layouts.\n\n",
      "fixed/a-first.md": "\n- **Client:** First fix.\n",
    });

    expect(assembleSections(readFragments(dir))).toBe(
      [
        "### Added",
        "",
        "- **Client:** Panes.",
        "- **Server:** Layouts.",
        "",
        "### Fixed",
        "",
        "- **Client:** First fix.",
        "- **Server:** Second fix.",
        "",
        "### Migration notes",
        "",
        "- **Compatibility:** Needs `oppi-server@0.56.0`.",
        "",
      ].join("\n"),
    );
  });

  test("reject a folder that names no section and a fragment that is not a bullet", () => {
    expect(() => readFragments(fragmentsDir({ "bugfixes/x.md": "- **Client:** X.\n" }))).toThrow(
      "not a changelog section folder",
    );
    expect(() => readFragments(fragmentsDir({ "fixed/x.md": "Fixed X.\n" }))).toThrow("must hold Markdown bullets");
  });

  test("cut puts the release below [Unreleased] and above the previous release", () => {
    const changelog = [
      "# Changelog",
      "",
      "## [Unreleased]",
      "<!-- fragments -->",
      "",
      "## [0.55.0] - 2026-11-14",
      "",
      "### Fixed",
      "",
      "- Old.",
      "",
    ].join("\n");

    const cut = cutChangelog(changelog, "0.56.0", "2026-11-20", "### Added\n\n- New.\n");

    expect(cut).toBe(
      [
        "# Changelog",
        "",
        "## [Unreleased]",
        "<!-- fragments -->",
        "",
        "## [0.56.0] - 2026-11-20",
        "",
        "### Added",
        "",
        "- New.",
        "",
        "## [0.55.0] - 2026-11-14",
        "",
        "### Fixed",
        "",
        "- Old.",
        "",
      ].join("\n"),
    );
    expect(() => cutChangelog(cut, "0.56.0", "2026-11-20", "### Added\n\n- New.\n")).toThrow("already has a [0.56.0]");
    expect(() => cutChangelog(changelog, "0.56.0", "2026-11-20", "")).toThrow("no changelog fragments");
  });
});

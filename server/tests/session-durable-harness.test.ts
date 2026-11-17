import { describe, expect, it } from "vitest";

import { relativeChangedFiles } from "../src/session-durable-harness.js";

describe("relativeChangedFiles", () => {
  const root = "/srv/work";

  it("keeps paths inside the folder in plain form, each once", () => {
    expect(
      relativeChangedFiles(
        ["notes/plan.md", "./notes/plan.md", "/srv/work/out/report.pdf", "a//b/./c.txt", " x.md "],
        root,
      ),
    ).toEqual(["notes/plan.md", "out/report.pdf", "a/b/c.txt", "x.md"]);
  });

  it("drops a path that leaves the folder, but keeps a name that starts with two dots", () => {
    expect(
      relativeChangedFiles(["../x", "a/../../x", "/srv/other/x", "..hidden/x", "a/..b"], root),
    ).toEqual(["..hidden/x", "a/..b"]);
  });

  it("drops home, URL, and control-character paths, and one over 1 KiB", () => {
    expect(
      relativeChangedFiles(
        [
          "~/notes.md",
          "https://example.com/a",
          "file:///etc/x",
          "bad\u0007name",
          "a/".repeat(600) + "x",
          "ok.md",
        ],
        root,
      ),
    ).toEqual(["ok.md"]);
  });

  it("drops an absolute path while the folder is unknown", () => {
    expect(relativeChangedFiles(["/srv/work/a.md", "b.md"], undefined)).toEqual(["b.md"]);
  });
});

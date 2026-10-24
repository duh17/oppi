import { describe, expect, it, vi } from "vitest";

import { buildControlSystemPrompt } from "../src/control-prompt.js";

const packagedDocs = vi.hoisted(() => ({ path: undefined as string | undefined }));
vi.mock("../src/oppi-docs.js", () => ({ getOppiDocsPath: () => packagedDocs.path }));

describe("buildControlSystemPrompt", () => {
  it("names the create or revise subject and the target", () => {
    expect(buildControlSystemPrompt({ domain: "skills", intent: "create" }, "/docs")).toContain(
      "This session: Create Skill.",
    );
    expect(
      buildControlSystemPrompt(
        { domain: "workspaces", intent: "revise", targetName: "  Notes\n“home” " },
        "/docs",
      ),
    ).toContain("This session: Revise Workspace “Notes home”.");
  });

  it("points at the docs directory, or the repository docs when none is packaged", () => {
    expect(buildControlSystemPrompt({ domain: "themes", intent: "create" }, "/opt/docs")).toContain(
      "Oppi documentation: /opt/docs.",
    );
    packagedDocs.path = undefined;
    const fallback = buildControlSystemPrompt({ domain: "themes", intent: "create" });
    expect(fallback).toContain("the `docs/` directory of the Oppi repository");
    expect(fallback).not.toContain("undefined");
  });
});

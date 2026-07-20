/**
 * Tests for MobileRendererRegistry and built-in tool renderers.
 */
import { describe, expect, it } from "vitest";
import { MobileRendererRegistry, type StyledSegment } from "../src/mobile-renderer.js";

function textOf(segs: StyledSegment[] | undefined): string {
  return (segs || []).map((s) => s.text).join("");
}

function styleOf(segs: StyledSegment[] | undefined, index: number): string | undefined {
  return segs?.[index]?.style;
}

describe("MobileRendererRegistry", () => {
  it("has built-in renderers for all standard tools", () => {
    const reg = new MobileRendererRegistry();
    for (const tool of [
      "ask",
      "oppi",
      "bash",
      "read",
      "edit",
      "write",
      "grep",
      "find",
      "ls",
      "todo",
    ]) {
      expect(reg.has(tool), `missing renderer for ${tool}`).toBe(true);
    }
  });

  it("returns undefined for unknown tools", () => {
    const reg = new MobileRendererRegistry();
    expect(reg.renderCall("unknown_tool", {})).toBeUndefined();
    expect(reg.renderResult("unknown_tool", {}, false)).toBeUndefined();
  });

  it("catches renderer errors and returns undefined", () => {
    const reg = new MobileRendererRegistry();
    reg.register("broken", {
      renderCall() {
        throw new Error("boom");
      },
      renderResult() {
        throw new Error("boom");
      },
    });
    expect(reg.renderCall("broken", {})).toBeUndefined();
    expect(reg.renderResult("broken", {}, false)).toBeUndefined();
  });

  it("registerAll merges renderers", () => {
    const reg = new MobileRendererRegistry();
    reg.registerAll({
      custom_tool: {
        renderCall(args) {
          return [{ text: `custom ${args.x}` }];
        },
        renderResult(_d, isError) {
          return [{ text: isError ? "fail" : "ok" }];
        },
      },
    });
    expect(reg.has("custom_tool")).toBe(true);
    expect(textOf(reg.renderCall("custom_tool", { x: "hi" }))).toBe("custom hi");
  });

  it("registerAll skips invalid entries", () => {
    const reg = new MobileRendererRegistry();
    const before = reg.size;
    reg.registerAll({
      bad1: { renderCall: "not a function" } as any,
      bad2: null as any,
    });
    expect(reg.size).toBe(before);
  });
});

describe("oppi renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renders the resource, action, and safe search terms instead of an opaque args count", () => {
    const segs = reg.renderCall("oppi", {
      args: ["session", "search", "workspace", "search", "--workspace", "oppi"],
    });

    expect(textOf(segs)).toBe("oppi session search · workspace search");
    expect(styleOf(segs, 0)).toBe("bold");
    expect(styleOf(segs, 1)).toBe("accent");
    expect(styleOf(segs, 2)).toBe("muted");
  });

  it("normalizes the optional leading oppi accepted by the command classifier", () => {
    const segs = reg.renderCall("oppi", {
      args: ["oppi", "session", "search", "workspace"],
    });

    expect(textOf(segs)).toBe("oppi session search · workspace");
  });

  it("does not expose malformed flag-first arguments before classification rejects them", () => {
    const segs = reg.renderCall("oppi", {
      args: ["--text", "private message"],
    });

    expect(textOf(segs)).toBe("oppi command");
    expect(textOf(segs)).not.toContain("private message");
  });

  it("does not expose inline write bodies in collapsed chrome", () => {
    const segs = reg.renderCall("oppi", {
      args: ["session", "send", "sess-1", "--text", "private message"],
    });

    expect(textOf(segs)).toBe("oppi session send");
    expect(textOf(segs)).not.toContain("private message");
  });

  it("shows a concise result count for session search", () => {
    const segs = reg.renderResult(
      "oppi",
      {
        args: ["session", "search", "workspace"],
        data: { total_results: 3, results: [{}, {}, {}] },
      },
      false,
    );

    expect(textOf(segs)).toBe("3 results");
    expect(styleOf(segs, 0)).toBe("success");
  });
});

describe("ask renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows ask prefix and question count", () => {
    const segs = reg.renderCall("ask", {
      questions: [
        { id: "install", question: "Where should I install it?" },
        { id: "scope", question: "Which scope?" },
      ],
    });
    expect(textOf(segs)).toBe("ask 2 questions");
    expect(styleOf(segs, 0)).toBe("bold");
    expect(styleOf(segs, 1)).toBe("muted");
  });

  it("renderResult uses question text and joins multi-select answer labels", () => {
    const segs = reg.renderResult(
      "ask",
      {
        questions: [
          {
            id: "targets",
            question: "Which targets?",
            options: [
              { value: "ios", label: "iOS app" },
              { value: "mac", label: "Mac app" },
            ],
          },
        ],
        answers: { targets: ["ios", "mac"] },
        allIgnored: false,
      },
      false,
    );
    expect(textOf(segs)).toBe("✓ Which targets?: iOS app, Mac app");
    expect(styleOf(segs, 0)).toBe("success");
  });

  it("renderResult falls back to id when question text is missing", () => {
    const segs = reg.renderResult(
      "ask",
      {
        questions: [{ id: "targets" }],
        answers: { targets: "ios" },
        allIgnored: false,
      },
      false,
    );
    expect(textOf(segs)).toBe("✓ targets: ios");
  });
});

describe("bash renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows first line of command", () => {
    const segs = reg.renderCall("bash", { command: "npm test\necho done" });
    expect(textOf(segs)).toBe("$ npm test");
    expect(styleOf(segs, 0)).toBe("bold");
    expect(styleOf(segs, 1)).toBe("accent");
  });

  it("renderCall keeps enough command text for wide tablet rows", () => {
    const command =
      "cd /Users/testuser/workspace/oppi && bun scripts/duplication-scan.ts && git diff -- clients/apple/Oppi/Features/Chat";
    const segs = reg.renderCall("bash", { command });
    expect(textOf(segs)).toBe(`$ ${command}`);
  });

  it("renderCall caps very long commands", () => {
    const command = "x".repeat(240);
    const segs = reg.renderCall("bash", { command });
    expect(textOf(segs)).toBe(`$ ${"x".repeat(199)}…`);
  });

  it("renderCall handles missing command", () => {
    const segs = reg.renderCall("bash", {});
    expect(textOf(segs)).toBe("$ ");
  });

  it("renderResult shows exit code on error", () => {
    const segs = reg.renderResult("bash", { exitCode: 127 }, true);
    expect(textOf(segs)).toBe("exit 127");
    expect(styleOf(segs, 0)).toBe("error");
  });

  it("renderResult empty on success", () => {
    const segs = reg.renderResult("bash", { exitCode: 0 }, false);
    expect(segs).toBeUndefined(); // empty segments → undefined (no badge needed)
  });

  it("renderResult shows non-zero exit code even without isError", () => {
    const segs = reg.renderResult("bash", { exitCode: 1 }, false);
    expect(textOf(segs)).toBe("exit 1");
    expect(styleOf(segs, 0)).toBe("error");
  });
});

describe("read renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows path", () => {
    const segs = reg.renderCall("read", { path: "src/main.ts" });
    expect(textOf(segs)).toBe("read src/main.ts");
  });

  it("renderCall shows offset:limit range", () => {
    const segs = reg.renderCall("read", { path: "foo.ts", offset: 10, limit: 20 });
    expect(textOf(segs)).toContain(":10-29");
  });

  it("renderCall shortens home paths", () => {
    const home = process.env.HOME || "";
    const segs = reg.renderCall("read", { path: `${home}/workspace/foo.ts` });
    expect(textOf(segs)).toContain("~/workspace/foo.ts");
  });

  it("renderResult shows truncation", () => {
    const segs = reg.renderResult(
      "read",
      { truncation: { truncated: true, outputLines: 50, totalLines: 200 } },
      false,
    );
    expect(textOf(segs)).toBe("50/200 lines");
    expect(styleOf(segs, 0)).toBe("warning");
  });

  it("renderResult empty when not truncated", () => {
    const segs = reg.renderResult("read", {}, false);
    expect(segs).toBeUndefined(); // empty segments → undefined (no badge needed)
  });
});

describe("edit renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows path", () => {
    const segs = reg.renderCall("edit", { path: "src/main.ts" });
    expect(textOf(segs)).toBe("edit src/main.ts");
  });

  it("renderResult shows applied with line number", () => {
    const segs = reg.renderResult("edit", { firstChangedLine: 42 }, false);
    expect(textOf(segs)).toBe("applied :42");
    expect(styleOf(segs, 0)).toBe("success");
  });

  it("renderResult error returns empty (icon is sufficient)", () => {
    const segs = reg.renderResult("edit", null, true);
    expect(segs).toBeUndefined();
  });
});

describe("write renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows path", () => {
    const segs = reg.renderCall("write", { path: "new-file.ts" });
    expect(textOf(segs)).toBe("write new-file.ts");
  });

  it("renderResult success", () => {
    const segs = reg.renderResult("write", {}, false);
    expect(textOf(segs)).toBe("✓");
    expect(styleOf(segs, 0)).toBe("success");
  });
});

describe("grep renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows pattern and path", () => {
    const segs = reg.renderCall("grep", { pattern: "TODO", path: "src/" });
    expect(textOf(segs)).toContain("/TODO/");
    expect(textOf(segs)).toContain("src/");
  });

  it("renderCall includes glob", () => {
    const segs = reg.renderCall("grep", { pattern: "x", path: ".", glob: "*.ts" });
    expect(textOf(segs)).toContain("(*.ts)");
  });

  it("renderResult shows truncation warning", () => {
    const segs = reg.renderResult("grep", { matchLimitReached: 100 }, false);
    expect(textOf(segs)).toContain("100 match limit");
  });
});

describe("find renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows pattern and path", () => {
    const segs = reg.renderCall("find", { pattern: "*.ts", path: "src/" });
    expect(textOf(segs)).toContain("*.ts");
    expect(textOf(segs)).toContain("src/");
  });
});

describe("ls renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall defaults to .", () => {
    const segs = reg.renderCall("ls", {});
    expect(textOf(segs)).toBe("ls .");
  });

  it("renderResult shows entry limit", () => {
    const segs = reg.renderResult("ls", { entryLimitReached: 500 }, false);
    expect(textOf(segs)).toContain("500 entry limit");
  });
});

describe("todo renderer", () => {
  const reg = new MobileRendererRegistry();

  it("renderCall shows action and title", () => {
    const segs = reg.renderCall("todo", { action: "create", title: "Fix the bug" });
    expect(textOf(segs)).toContain("todo ");
    expect(textOf(segs)).toContain("create");
    expect(textOf(segs)).toContain("Fix the bug");
  });

  it("renderCall shows action and id", () => {
    const segs = reg.renderCall("todo", { action: "get", id: "TODO-abc123" });
    expect(textOf(segs)).toContain("TODO-abc123");
  });

  it("renderResult list shows count", () => {
    const segs = reg.renderResult("todo", { action: "list", todos: [{}, {}, {}] }, false);
    expect(textOf(segs)).toBe("3 todo(s)");
  });

  it("renderResult error returns empty (icon is sufficient)", () => {
    const segs = reg.renderResult("todo", { error: "not found" }, true);
    expect(segs).toBeUndefined();
  });
});

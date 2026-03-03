/**
 * Render no-op invariant tests — RQ-TL-002.
 */

import { describe, expect, it } from "vitest";
import { MobileRendererRegistry, type StyledSegment } from "../src/mobile-renderer.js";

function segmentsEqual(a: StyledSegment[] | undefined, b: StyledSegment[] | undefined): boolean {
  if (!a || !b) return a === b;
  if (a.length !== b.length) return false;
  return a.every((segment, index) => {
    const next = b[index];
    return segment.text === next.text && segment.style === next.style;
  });
}

function expectIdempotent(
  render: () => StyledSegment[] | undefined,
  message: string,
): void {
  const first = render();
  const second = render();

  if (first === undefined) {
    expect(second, message).toBeUndefined();
    return;
  }

  expect(segmentsEqual(first, second), message).toBe(true);
}

const callCases = [
  ["bash", { command: "npm test" }],
  ["read", { path: "src/main.ts", offset: 10, limit: 50 }],
  ["edit", { path: "src/main.ts", oldText: "foo", newText: "bar" }],
  ["write", { path: "src/new-file.ts", content: "export const x = 1;" }],
  ["grep", { pattern: "TODO", path: "src/", include: "*.ts" }],
  ["find", { path: "src/", pattern: "*.ts" }],
  ["ls", { path: "src/" }],
  ["todo", { action: "list" }],
  [
    "plot",
    {
      spec: JSON.stringify({
        dataset: { rows: [{ x: 1, y: 2 }] },
        marks: [{ type: "line", x: "x", y: "y" }],
      }),
    },
  ],
] as const;

const resultCases = [
  ["bash", { exitCode: 0 }, false],
  ["bash", { exitCode: 1 }, true],
  ["read", { lineCount: 42, truncated: false }, false],
  ["edit", { replacements: 1 }, false],
  ["write", { bytesWritten: 256 }, false],
] as const;

describe("RQ-TL-002: renderCall idempotency", () => {
  const reg = new MobileRendererRegistry();

  for (const [tool, args] of callCases) {
    it(`${tool}: same args produce identical segments`, () => {
      expectIdempotent(() => reg.renderCall(tool, args), `${tool} renderCall should be idempotent`);
    });
  }

  it("unknown tool: consistently returns undefined", () => {
    expectIdempotent(
      () => reg.renderCall("nonexistent_tool", { x: 1 }),
      "unknown renderCall should stay undefined",
    );
  });
});

describe("RQ-TL-002: renderResult idempotency", () => {
  const reg = new MobileRendererRegistry();

  for (const [tool, details, isError] of resultCases) {
    it(`${tool} (${isError ? "error" : "success"}): identical details are stable`, () => {
      expectIdempotent(
        () => reg.renderResult(tool, details, isError),
        `${tool} renderResult should be idempotent`,
      );
    });
  }

  it("unknown tool result: consistently returns undefined", () => {
    expectIdempotent(
      () => reg.renderResult("nonexistent", {}, false),
      "unknown renderResult should stay undefined",
    );
  });
});

describe("RQ-TL-002: no-op detection (same input = same output)", () => {
  const reg = new MobileRendererRegistry();

  it("all built-in tools: renderCall is pure", () => {
    for (const [tool, args] of callCases) {
      expectIdempotent(() => reg.renderCall(tool, args), `${tool} renderCall should be pure`);
    }
  });

  it("all built-in tools: renderResult is pure", () => {
    for (const [tool] of callCases) {
      expectIdempotent(
        () => reg.renderResult(tool, {}, false),
        `${tool} renderResult should be pure`,
      );
    }
  });

  it("renderCall output is deterministic for equivalent args objects", () => {
    const argsA = JSON.parse('{"command":"npm test","timeout":30}');
    const argsB = JSON.parse('{"command":"npm test","timeout":30}');

    expect(segmentsEqual(reg.renderCall("bash", argsA), reg.renderCall("bash", argsB))).toBe(true);
  });
});

describe("RQ-TL-002: segment structural invariants", () => {
  const reg = new MobileRendererRegistry();

  it("segments always expose string text", () => {
    const segments = reg.renderCall("bash", { command: "echo hi" });
    expect(segments).toBeDefined();

    for (const segment of segments ?? []) {
      expect(segment.text).toBeTypeOf("string");
    }
  });

  it("segment styles are from the allowed set", () => {
    const allowedStyles = new Set([
      undefined,
      "bold",
      "muted",
      "dim",
      "accent",
      "success",
      "warning",
      "error",
    ]);

    for (const [tool, args] of callCases.filter(([tool]) =>
      ["bash", "read", "edit", "write"].includes(tool),
    )) {
      const callSegs = reg.renderCall(tool, args);
      const resultSegs = reg.renderResult(tool, {}, false);

      for (const seg of callSegs ?? []) {
        expect(allowedStyles.has(seg.style), `${tool} renderCall has unexpected style`).toBe(true);
      }

      for (const seg of resultSegs ?? []) {
        expect(allowedStyles.has(seg.style), `${tool} renderResult has unexpected style`).toBe(true);
      }
    }
  });
});

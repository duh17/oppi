/**
 * Render no-op invariant tests — RQ-TL-002.
 */

import { describe, expect, it } from "vitest";
import { MobileRendererRegistry, type StyledSegment } from "../src/mobile-renderer.js";

function expectIdempotent(
  render: () => StyledSegment[] | undefined,
  message: string,
): void {
  const first = render();
  const second = render();
  expect(second, message).toEqual(first);
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

describe("RQ-TL-002: renderer idempotency and purity", () => {
  const registry = new MobileRendererRegistry();

  for (const [tool, args] of callCases) {
    it(`renderCall(${tool}) is deterministic`, () => {
      expectIdempotent(() => registry.renderCall(tool, args), `${tool} renderCall should be stable`);
    });
  }

  for (const [tool, details, isError] of resultCases) {
    it(`renderResult(${tool}, ${isError ? "error" : "success"}) is deterministic`, () => {
      expectIdempotent(
        () => registry.renderResult(tool, details, isError),
        `${tool} renderResult should be stable`,
      );
    });
  }

  it("unknown tool renderers consistently return undefined", () => {
    expectIdempotent(
      () => registry.renderCall("nonexistent_tool", { x: 1 }),
      "unknown renderCall should stay undefined",
    );
    expectIdempotent(
      () => registry.renderResult("nonexistent", {}, false),
      "unknown renderResult should stay undefined",
    );
  });

  it("equivalent args objects produce identical render output", () => {
    const argsA = JSON.parse('{"command":"npm test","timeout":30}');
    const argsB = JSON.parse('{"command":"npm test","timeout":30}');

    expect(registry.renderCall("bash", argsA)).toEqual(registry.renderCall("bash", argsB));
  });
});

describe("RQ-TL-002: segment structural invariants", () => {
  const registry = new MobileRendererRegistry();

  it("segments always expose string text", () => {
    const segments = registry.renderCall("bash", { command: "echo hi" });
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
      const callSegments = registry.renderCall(tool, args) ?? [];
      const resultSegments = registry.renderResult(tool, {}, false) ?? [];

      for (const segment of [...callSegments, ...resultSegments]) {
        expect(allowedStyles.has(segment.style), `${tool} has unexpected style`).toBe(true);
      }
    }
  });
});

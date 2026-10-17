import { describe, expect, it } from "vitest";

import type { WorkspaceReviewDiffHunk, WorkspaceReviewDiffLine } from "../src/types.js";
import { applyWordSpansToNumberedHunks } from "../src/workspace-review-diff.js";

function line(
  kind: WorkspaceReviewDiffLine["kind"],
  text: string,
  oldLine: number | null,
  newLine: number | null,
): WorkspaceReviewDiffLine {
  return { kind, text, oldLine, newLine };
}

function snapshotLineNumbers(hunks: WorkspaceReviewDiffHunk[]) {
  return hunks.map((hunk) =>
    hunk.lines.map((entry) => ({
      kind: entry.kind,
      oldLine: entry.oldLine,
      newLine: entry.newLine,
    })),
  );
}

describe("applyWordSpansToNumberedHunks", () => {
  it("adds UTF-16 spans to paired changed lines without renumbering", () => {
    const oldText = "keep 👋 old";
    const newText = "keep 👋 new";
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 20,
        oldCount: 2,
        newStart: 20,
        newCount: 2,
        lines: [
          line("context", "unchanged", 20, 20),
          line("removed", oldText, 21, null),
          line("added", newText, null, 21),
        ],
      },
    ];
    const numbersBefore = snapshotLineNumbers(hunks);

    applyWordSpansToNumberedHunks(hunks);

    expect(snapshotLineNumbers(hunks)).toEqual(numbersBefore);
    const removed = hunks[0]?.lines.find((entry) => entry.kind === "removed");
    const added = hunks[0]?.lines.find((entry) => entry.kind === "added");
    const oldStart = oldText.indexOf("old");
    const newStart = newText.indexOf("new");
    expect(removed?.spans).toEqual([{ start: oldStart, end: oldStart + 3, kind: "changed" }]);
    expect(added?.spans).toEqual([{ start: newStart, end: newStart + 3, kind: "changed" }]);
    expect(oldText.slice(oldStart, oldStart + 3)).toBe("old");
    expect("👋".length).toBe(2);
  });

  it("pairs an edited line with its counterpart and leaves unrelated rewrites line-level", () => {
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 1,
        oldCount: 2,
        newStart: 1,
        newCount: 3,
        lines: [
          line("removed", "- **Server:** Durable sessions no longer load extensions.", 1, null),
          line("removed", "const timeout = 30;", 2, null),
          line("added", "App Lock locks a server, workspace, or session behind Face ID.", null, 1),
          line("added", "// Longer wait for cold starts.", null, 2),
          line("added", "const timeout = 45;", null, 3),
        ],
      },
    ];

    applyWordSpansToNumberedHunks(hunks);

    const [unrelatedOld, editedOld, unrelatedNew, insertedNew, editedNew] = hunks[0]!.lines;
    // Index pairing would have word-diffed these unrelated paragraphs.
    expect(unrelatedOld?.spans).toBeUndefined();
    expect(unrelatedNew?.spans).toBeUndefined();
    expect(insertedNew?.spans).toBeUndefined();
    expect(editedOld?.spans).toEqual([{ start: 16, end: 18, kind: "changed" }]);
    expect(editedNew?.spans).toEqual([{ start: 16, end: 18, kind: "changed" }]);
  });

  it("keeps word highlights on short edits that share little text", () => {
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 1,
        oldCount: 2,
        newStart: 1,
        newCount: 2,
        lines: [
          line("removed", "let a = b", 1, null),
          line("removed", "foo()", 2, null),
          line("added", "var a = c", null, 1),
          line("added", "bar()", null, 2),
        ],
      },
    ];

    applyWordSpansToNumberedHunks(hunks);

    const [oldLet, oldCall, newVar, newCall] = hunks[0]!.lines;
    expect(oldLet?.spans).toEqual([
      { start: 0, end: 3, kind: "changed" },
      { start: 8, end: 9, kind: "changed" },
    ]);
    expect(newVar?.spans).toEqual([
      { start: 0, end: 3, kind: "changed" },
      { start: 8, end: 9, kind: "changed" },
    ]);
    expect(oldCall?.spans).toEqual([{ start: 0, end: 3, kind: "changed" }]);
    expect(newCall?.spans).toEqual([{ start: 0, end: 3, kind: "changed" }]);
  });

  it("marks only the changed word on very long lines", () => {
    const words = Array.from({ length: 300 }, (_, index) => `word${index}`);
    const oldText = words.join(" ");
    const newText = words.map((word) => (word === "word150" ? "edited" : word)).join(" ");
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 1,
        oldCount: 1,
        newStart: 1,
        newCount: 1,
        lines: [line("removed", oldText, 1, null), line("added", newText, null, 1)],
      },
    ];

    applyWordSpansToNumberedHunks(hunks);

    const oldStart = oldText.indexOf("word150");
    const newStart = newText.indexOf("edited");
    expect(hunks[0]?.lines[0]?.spans).toEqual([
      { start: oldStart, end: oldStart + "word150".length, kind: "changed" },
    ]);
    expect(hunks[0]?.lines[1]?.spans).toEqual([
      { start: newStart, end: newStart + "edited".length, kind: "changed" },
    ]);
  });

  it("keeps added-only groups line-level", () => {
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 1,
        oldCount: 1,
        newStart: 1,
        newCount: 2,
        lines: [line("context", "keep", 1, 1), line("added", "only added", null, 2)],
      },
    ];

    applyWordSpansToNumberedHunks(hunks);

    expect(hunks[0]?.lines.every((entry) => entry.spans === undefined)).toBe(true);
  });

  it("keeps removed-only groups line-level", () => {
    const hunks: WorkspaceReviewDiffHunk[] = [
      {
        oldStart: 8,
        oldCount: 2,
        newStart: 8,
        newCount: 1,
        lines: [line("context", "keep", 8, 8), line("removed", "only removed", 9, null)],
      },
    ];

    applyWordSpansToNumberedHunks(hunks);

    expect(hunks[0]?.lines.every((entry) => entry.spans === undefined)).toBe(true);
  });
});

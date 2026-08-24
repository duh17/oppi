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

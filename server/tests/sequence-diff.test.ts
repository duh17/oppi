import { describe, expect, it } from "vitest";

import { computeDiffLines } from "../src/diff-core.js";
import { matchSequences } from "../src/sequence-diff.js";

/** Deterministic LCG so failures reproduce. */
function seededRandom(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  };
}

function randomSequence(random: () => number, maxLength: number, alphabet: number): number[] {
  const length = Math.floor(random() * (maxLength + 1));
  return Array.from({ length }, () => Math.floor(random() * alphabet));
}

/** O(nm) dynamic-programming LCS length: the minimality oracle. */
function lcsLength(a: number[], b: number[]): number {
  const row = new Array<number>(b.length + 1).fill(0);
  for (const value of a) {
    let diagonal = 0;
    for (let j = 1; j <= b.length; j += 1) {
      const above = row[j]!;
      row[j] = value === b[j - 1] ? diagonal + 1 : Math.max(row[j]!, row[j - 1]!);
      diagonal = above;
    }
  }
  return row[b.length]!;
}

/** Matched elements, paired in order, must be equal: the edit script is valid. */
function expectValidMatching(
  a: number[],
  b: number[],
  oldMatched: Uint8Array,
  newMatched: Uint8Array,
) {
  const oldValues = a.filter((_, index) => oldMatched[index] === 1);
  const newValues = b.filter((_, index) => newMatched[index] === 1);
  expect(oldValues).toEqual(newValues);
}

function rebuild(lines: ReturnType<typeof computeDiffLines>, drop: "added" | "removed"): string {
  return lines
    .filter((line) => line.kind !== drop)
    .map((line) => line.text)
    .join("\n");
}

function withoutFinalNewline(text: string): string {
  return text.endsWith("\n") ? text.slice(0, -1) : text;
}

describe("matchSequences", () => {
  it("finds a longest common subsequence for random inputs", () => {
    const random = seededRandom(17);
    for (let iteration = 0; iteration < 2_000; iteration += 1) {
      const a = randomSequence(random, 40, 1 + Math.floor(random() * 6));
      const b = randomSequence(random, 40, 1 + Math.floor(random() * 6));

      const match = matchSequences(a, b);

      expect(match.exact).toBe(true);
      expect(match.matched).toBe(lcsLength(a, b));
      expectValidMatching(a, b, match.oldMatched, match.newMatched);
    }
  });

  it("stays a valid edit script when the cost cap cuts matching short", () => {
    const random = seededRandom(29);
    const a = randomSequence(random, 400, 3);
    const b = randomSequence(random, 400, 3);

    const capped = matchSequences(a, b, 50);

    expect(capped.exact).toBe(false);
    expect(capped.matched).toBeLessThanOrEqual(lcsLength(a, b));
    expectValidMatching(a, b, capped.oldMatched, capped.newMatched);
  });
});

describe("computeDiffLines", () => {
  it("rebuilds both texts and removes the minimum number of lines", () => {
    const random = seededRandom(5);
    const vocabulary = ["", "x", "y", "## Heading", "- item", "}", "  return value"];
    for (let iteration = 0; iteration < 1_000; iteration += 1) {
      const oldLines = randomSequence(random, 12, vocabulary.length).map((i) => vocabulary[i]!);
      const newLines = randomSequence(random, 12, vocabulary.length).map((i) => vocabulary[i]!);
      const oldText = oldLines.join("\n") + (random() < 0.8 ? "\n" : "");
      const newText = newLines.join("\n") + (random() < 0.8 ? "\n" : "");

      const diff = computeDiffLines(oldText, newText);

      expect(rebuild(diff, "added")).toBe(withoutFinalNewline(oldText));
      expect(rebuild(diff, "removed")).toBe(withoutFinalNewline(newText));
      if (oldText.endsWith("\n") && newText.endsWith("\n")) {
        const ids = new Map<string, number>();
        const toIds = (text: string) =>
          (text === "" ? [] : withoutFinalNewline(text).split("\n")).map((line) => {
            if (!ids.has(line)) ids.set(line, ids.size);
            return ids.get(line)!;
          });
        const oldIds = toIds(oldText);
        const removed = diff.filter((line) => line.kind === "removed").length;
        expect(removed).toBe(oldIds.length - lcsLength(oldIds, toIds(newText)));
      }
    }
  });

  it("never invents a context line that one side does not have", () => {
    // diff-match-patch's semantic cleanup reported a blank context line here,
    // shifting every later new-side line number by one.
    expect(computeDiffLines("\n", "y\n")).toEqual([
      { kind: "removed", text: "" },
      { kind: "added", text: "y" },
    ]);
  });

  it("shows a changed final newline as a changed line", () => {
    expect(computeDiffLines("a\nb", "a\nb\n")).toEqual([
      { kind: "context", text: "a" },
      { kind: "removed", text: "b" },
      { kind: "added", text: "b" },
    ]);
  });
});

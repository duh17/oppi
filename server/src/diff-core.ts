import { matchSequences } from "./sequence-diff.js";
import type { TraceEvent } from "./trace.js";
import { extractToolMutations } from "./tool-mutations.js";

export type FileMutation =
  | { id: string; kind: "edit"; oldText: string; newText: string }
  | { id: string; kind: "write"; content: string };

export type DiffLine = {
  kind: "context" | "added" | "removed";
  text: string;
};

export function collectFileMutations(trace: TraceEvent[], reqPath: string): FileMutation[] {
  const mutations: FileMutation[] = [];

  for (const event of trace) {
    if (event.type !== "toolCall") continue;

    for (const mutation of extractToolMutations(event.tool, event.args ?? {})) {
      if (mutation.path !== reqPath) continue;

      if (mutation.kind === "edit") {
        mutations.push({
          id: event.id,
          kind: "edit",
          oldText: mutation.oldText,
          newText: mutation.newText,
        });
      } else {
        mutations.push({ id: event.id, kind: "write", content: mutation.content });
      }
    }
  }

  return mutations;
}

export function reconstructBaselineFromCurrent(
  currentText: string,
  mutations: FileMutation[],
): string {
  let baseline = currentText;

  for (let i = mutations.length - 1; i >= 0; i -= 1) {
    const mutation = mutations[i];
    if (mutation.kind === "write") {
      baseline = "";
      continue;
    }

    if (!mutation.newText) continue;

    const idx = baseline.indexOf(mutation.newText);
    if (idx < 0) continue;
    baseline =
      baseline.slice(0, idx) + mutation.oldText + baseline.slice(idx + mutation.newText.length);
  }

  return baseline;
}

/**
 * Minimal line diff (see `sequence-diff.ts`). Every output line is a real
 * line of one side, context + removed rebuilds the old text, and context +
 * added rebuilds the new text. Within each change block, removed lines come
 * before added lines, like git.
 */
export function computeDiffLines(oldText: string, newText: string): DiffLine[] {
  const oldLines = splitLines(oldText);
  const newLines = splitLines(newText);
  const oldKeys = lineKeys(oldLines, oldText);
  const newKeys = lineKeys(newLines, newText);

  // Intern line keys to integers. A line that appears on only one side can never
  // be matched, so dropping it before matching keeps the result minimal while
  // shrinking rewrites of unique lines to almost nothing.
  const ids = new Map<string, number>();
  const oldIds = oldKeys.map((key) => {
    const known = ids.get(key);
    if (known !== undefined) return known;
    ids.set(key, ids.size);
    return ids.size - 1;
  });
  const newIds = newKeys.map((key) => ids.get(key) ?? -1);
  const inNew = new Uint8Array(ids.size);
  for (const id of newIds) if (id >= 0) inNew[id] = 1;

  const oldCandidates: number[] = [];
  oldIds.forEach((id, index) => {
    if (inNew[id] === 1) oldCandidates.push(index);
  });
  const newCandidates: number[] = [];
  newIds.forEach((id, index) => {
    if (id >= 0) newCandidates.push(index);
  });
  const match = matchSequences(
    oldCandidates.map((index) => oldIds[index] ?? -1),
    newCandidates.map((index) => newIds[index] ?? -1),
  );
  const oldMatched = new Uint8Array(oldLines.length);
  oldCandidates.forEach((lineIndex, k) => {
    if (match.oldMatched[k]) oldMatched[lineIndex] = 1;
  });
  const newMatched = new Uint8Array(newLines.length);
  newCandidates.forEach((lineIndex, k) => {
    if (match.newMatched[k]) newMatched[lineIndex] = 1;
  });

  // Matches pair up in order, so walking both sides and emitting unmatched old
  // lines, then unmatched new lines, lands on each matched pair together.
  const out: DiffLine[] = [];
  let oldIndex = 0;
  let newIndex = 0;
  for (;;) {
    const oldLine = oldLines[oldIndex];
    const newLine = newLines[newIndex];
    if (oldLine !== undefined && !oldMatched[oldIndex]) {
      out.push({ kind: "removed", text: oldLine });
      oldIndex += 1;
    } else if (newLine !== undefined && !newMatched[newIndex]) {
      out.push({ kind: "added", text: newLine });
      newIndex += 1;
    } else if (newLine !== undefined) {
      out.push({ kind: "context", text: newLine });
      oldIndex += 1;
      newIndex += 1;
    } else {
      return out;
    }
  }
}

/**
 * Matching keys per line. A final line without a trailing newline differs from
 * the same text with one, so adding or removing the last newline shows as a
 * changed line (git reports it the same way).
 */
function lineKeys(lines: string[], text: string): string[] {
  if (lines.length === 0 || text.endsWith("\n")) return lines;
  return lines.map((line, index) => (index === lines.length - 1 ? `${line}\u0000no-eol` : line));
}

export function computeLineDiffStatsFromLines(lines: DiffLine[]): {
  added: number;
  removed: number;
} {
  let added = 0;
  let removed = 0;
  for (const line of lines) {
    if (line.kind === "added") added += 1;
    if (line.kind === "removed") removed += 1;
  }
  return { added, removed };
}

function splitLines(text: string): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  return lines;
}

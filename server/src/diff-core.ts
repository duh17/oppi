import diff_match_patch from "diff-match-patch";
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

export function computeDiffLines(oldText: string, newText: string): DiffLine[] {
  const dmp = new diff_match_patch();
  const { chars1, chars2, lineArray } = dmp.diff_linesToChars_(oldText, newText);

  const diffs = dmp.diff_main(chars1, chars2, false);
  dmp.diff_charsToLines_(diffs, lineArray);
  dmp.diff_cleanupSemantic(diffs);

  const out: DiffLine[] = [];

  for (const [op, chunk] of diffs) {
    const lines = splitLines(chunk);
    for (const text of lines) {
      if (op === diff_match_patch.DIFF_EQUAL) {
        out.push({ kind: "context", text });
      } else if (op === diff_match_patch.DIFF_INSERT) {
        out.push({ kind: "added", text });
      } else {
        out.push({ kind: "removed", text });
      }
    }
  }

  return out;
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

export type ParsedToolMutation =
  | { kind: "write"; path: string | null; content: string }
  | { kind: "edit"; path: string | null; oldText: string; newText: string; isNewFile?: boolean };

/** Normalize tool names (`functions.edit` -> `edit`) for mutation tracking. */
export function normalizeMutationToolName(rawToolName: unknown): string {
  if (typeof rawToolName !== "string") return "";
  const normalized = rawToolName.trim().toLowerCase();
  if (!normalized) return "";
  const parts = normalized.split(".");
  return parts[parts.length - 1] ?? normalized;
}

export function extractToolMutations(rawToolName: unknown, rawArgs: unknown): ParsedToolMutation[] {
  const toolName = normalizeMutationToolName(rawToolName);
  if (toolName !== "edit" && toolName !== "write") return [];
  if (!rawArgs || typeof rawArgs !== "object") return [];

  const args = rawArgs as Record<string, unknown>;
  if (toolName === "write") {
    return [
      {
        kind: "write",
        path: extractPath(args.path),
        content: typeof args.content === "string" ? args.content : "",
      },
    ];
  }

  const patch = typeof args.patch === "string" ? args.patch : "";
  if (patch.length > 0) {
    const patchMutations = parseCodexPatchMutations(patch);
    if (patchMutations.length > 0) return patchMutations;
  }

  const topLevelPath = extractPath(args.path);

  if (Array.isArray(args.multi)) {
    const mutations = args.multi.flatMap((entry) => {
      if (!entry || typeof entry !== "object") return [];
      const edit = entry as Record<string, unknown>;
      const path = extractPath(edit.path) ?? topLevelPath;
      return mutationFromOldNew(path, edit);
    });
    if (mutations.length > 0) return mutations;
  }

  if (Array.isArray(args.edits)) {
    const mutations = args.edits.flatMap((entry) => mutationFromOldNew(topLevelPath, entry));
    if (mutations.length > 0) return mutations;
  }

  const legacy = mutationFromOldNew(topLevelPath, args);
  return legacy;
}

export function extractPath(candidate: unknown): string | null {
  if (typeof candidate !== "string") return null;
  const normalized = candidate.trim();
  return normalized.length > 0 ? normalized : null;
}

export function countTextLines(text: string): number {
  if (text.length === 0) return 0;
  return text.split("\n").length;
}

function mutationFromOldNew(
  path: string | null,
  rawEdit: unknown,
): Extract<ParsedToolMutation, { kind: "edit" }>[] {
  if (!rawEdit || typeof rawEdit !== "object") return [];
  const edit = rawEdit as Record<string, unknown>;
  const oldText = typeof edit.oldText === "string" ? edit.oldText : "";
  const newText = typeof edit.newText === "string" ? edit.newText : "";
  if (oldText.length === 0 && newText.length === 0) return [];
  return [{ kind: "edit", path, oldText, newText }];
}

function parseCodexPatchMutations(patch: string): Extract<ParsedToolMutation, { kind: "edit" }>[] {
  const mutations: Extract<ParsedToolMutation, { kind: "edit" }>[] = [];
  let current: PatchFileState | null = null;
  let hunk: PatchHunkState | null = null;

  const flushHunk = (): void => {
    if (!current || !hunk) return;
    if (hunk.addedLines === 0 && hunk.removedLines === 0) {
      hunk = null;
      return;
    }
    mutations.push({
      kind: "edit",
      path: current.path,
      oldText: hunk.oldLines.join("\n"),
      newText: hunk.newLines.join("\n"),
      isNewFile: current.action === "add",
    });
    hunk = null;
  };

  const flushFile = (): void => {
    flushHunk();
    current = null;
  };

  for (const line of patch.split("\n")) {
    const marker = /^\*\*\* (Add|Update|Delete) File: (.+)$/.exec(line);
    if (marker) {
      flushFile();
      current = {
        action: marker[1] === "Add" ? "add" : marker[1] === "Delete" ? "delete" : "update",
        path: extractPath(marker[2]) ?? "",
      };
      hunk = null;
      continue;
    }

    if (!current) continue;

    if (line.startsWith("***")) {
      flushFile();
      continue;
    }

    if (line.startsWith("@@")) {
      flushHunk();
      hunk = emptyPatchHunk();
      continue;
    }

    hunk ??= emptyPatchHunk();
    appendCodexPatchLine(hunk, line);
  }

  flushFile();
  return mutations.filter((mutation) => mutation.path !== "");
}

type PatchAction = "add" | "update" | "delete";

interface PatchFileState {
  action: PatchAction;
  path: string;
}

interface PatchHunkState {
  oldLines: string[];
  newLines: string[];
  addedLines: number;
  removedLines: number;
}

function emptyPatchHunk(): PatchHunkState {
  return { oldLines: [], newLines: [], addedLines: 0, removedLines: 0 };
}

function appendCodexPatchLine(hunk: PatchHunkState, line: string): void {
  if (line.startsWith("+") && !line.startsWith("+++")) {
    hunk.newLines.push(line.slice(1));
    hunk.addedLines += 1;
    return;
  }
  if (line.startsWith("-") && !line.startsWith("---")) {
    hunk.oldLines.push(line.slice(1));
    hunk.removedLines += 1;
    return;
  }

  hunk.oldLines.push(line);
  hunk.newLines.push(line);
}

import { basename } from "node:path";

import { normalizePath } from "./git-utils.js";
import { getGitStatus } from "./git-status.js";
import { buildWorkspaceReviewDiff, WorkspaceReviewDiffError } from "./workspace-review-diff.js";
import { buildWorkspaceReviewFilesResponse } from "./workspace-review.js";
import type {
  Session,
  Workspace,
  WorkspaceReviewDiffResponse,
  WorkspaceReviewFile,
  WorkspaceReviewSessionAction,
} from "./types.js";

const MAX_DETAILED_FILES = 8;
const MAX_HUNKS_PER_FILE = 8;
const MAX_LINES_PER_HUNK = 80;
const MAX_DIFF_SECTION_CHARS = 48_000;

export class WorkspaceReviewSessionError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "WorkspaceReviewSessionError";
  }
}

type ReviewActionConfig = {
  sessionTitle: string;
  visiblePrompt: string;
  instructions: string[];
};

type ReviewSessionSelection = {
  files: WorkspaceReviewFile[];
  omittedDiffPaths: string[];
  unavailableDiffs: Array<{ path: string; reason: string }>;
  preamble: string;
  visiblePrompt: string;
  sessionName: string;
};

type DetailedSelectionFile = {
  file: WorkspaceReviewFile;
  diff?: WorkspaceReviewDiffResponse;
  diffUnavailableReason?: string;
};

function actionConfig(action: WorkspaceReviewSessionAction): ReviewActionConfig {
  switch (action) {
    case "review":
      return {
        sessionTitle: "Review",
        visiblePrompt: "Review these selected changes.",
        instructions: [
          "Analyze the selected git-backed changes for bugs, regressions, risky assumptions, and missing tests.",
          "For each finding, cite the file path, line number, and severity (error for bugs, warn for risky patterns, info for suggestions).",
          "Be concise — the reviewer reads these on a phone screen.",
          "After listing all findings, provide a brief summary.",
          "Do not edit code unless the user explicitly asks for changes.",
        ],
      };
    case "reflect":
      return {
        sessionTitle: "Reflect",
        visiblePrompt: "Reflect on these selected changes and recommend next steps.",
        instructions: [
          "Summarize what changed and infer the likely intent from the selected diffs.",
          "Identify missing follow-ups, cleanup work, validation gaps, and next steps.",
          "For actionable items tied to specific lines, cite the file path and line number.",
          "Prioritize recommendations so the user knows what to do next.",
          "Do not edit code unless the user explicitly asks for changes.",
        ],
      };
    case "prepare_commit":
      return {
        sessionTitle: "Prepare commit",
        visiblePrompt: "Prepare a commit for these selected changes.",
        instructions: [
          "Summarize the selected git-backed changes for shipping.",
          "Suggest a conventional commit title and supporting body bullets when useful.",
          "Call out when the selection looks too broad or mixes unrelated concerns.",
          "Do not run git commit, stage, or mutate git state unless the user explicitly asks.",
        ],
      };
  }
}

function formatFileSummary(file: WorkspaceReviewFile): string {
  const status = file.status.trim() || "?";
  const stats: string[] = [];
  if (typeof file.addedLines === "number" && file.addedLines > 0) {
    stats.push(`+${file.addedLines}`);
  }
  if (typeof file.removedLines === "number" && file.removedLines > 0) {
    stats.push(`-${file.removedLines}`);
  }

  const flags: string[] = [];
  if (file.isStaged) flags.push("staged");
  if (file.isUnstaged) flags.push("unstaged");
  if (file.isUntracked) flags.push("untracked");
  if (file.selectedSessionTouched) flags.push("selected-session");

  const suffixParts: string[] = [];
  if (stats.length > 0) {
    suffixParts.push(stats.join(" "));
  }
  if (flags.length > 0) {
    suffixParts.push(flags.join(", "));
  }

  const suffix = suffixParts.length > 0 ? ` (${suffixParts.join("; ")})` : "";
  return `- [${status}] ${file.path}${suffix}`;
}

function formatHunk(diff: WorkspaceReviewDiffResponse): string {
  return diff.hunks
    .slice(0, MAX_HUNKS_PER_FILE)
    .map((hunk) => {
      const lines = hunk.lines
        .slice(0, MAX_LINES_PER_HUNK)
        .map(
          (line) =>
            `${line.kind === "context" ? " " : line.kind === "added" ? "+" : "-"}${line.text}`,
        )
        .join("\n");
      return `${`@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@`}\n${lines}`;
    })
    .join("\n\n");
}

async function gatherDetailedSelection(args: {
  workspaceId: string;
  workspaceRoot: string;
  requestedFiles: WorkspaceReviewFile[];
}): Promise<DetailedSelectionFile[]> {
  const { workspaceId, workspaceRoot, requestedFiles } = args;

  return Promise.all(
    requestedFiles.map(async (file) => {
      try {
        const diff = await buildWorkspaceReviewDiff({
          workspaceId,
          workspaceRoot,
          path: file.path,
        });
        return { file, diff } satisfies DetailedSelectionFile;
      } catch (error) {
        if (error instanceof WorkspaceReviewDiffError) {
          return {
            file,
            diffUnavailableReason: error.message,
          } satisfies DetailedSelectionFile;
        }
        throw error;
      }
    }),
  );
}

function buildReviewPreamble(args: {
  workspace: Workspace;
  action: WorkspaceReviewSessionAction;
  selectedSession?: Session;
  files: DetailedSelectionFile[];
}): string {
  const { workspace, action, selectedSession, files } = args;
  const config = actionConfig(action);
  const selectedCount = files.length;

  let diffChars = 0;
  const omittedDiffPaths: string[] = [];
  const unavailableDiffs: Array<{ path: string; reason: string }> = [];
  const detailSections: string[] = [];

  for (const entry of files.slice(0, MAX_DETAILED_FILES)) {
    if (!entry.diff) {
      unavailableDiffs.push({
        path: entry.file.path,
        reason: entry.diffUnavailableReason ?? "Diff unavailable for this file.",
      });
      continue;
    }

    const diffText = formatHunk(entry.diff);
    if (!diffText.trim()) {
      unavailableDiffs.push({
        path: entry.file.path,
        reason: "No textual hunks available.",
      });
      continue;
    }

    const section = [`File: ${entry.file.path}`, diffText].join("\n");
    if (diffChars + section.length > MAX_DIFF_SECTION_CHARS) {
      omittedDiffPaths.push(entry.file.path);
      continue;
    }

    detailSections.push(section);
    diffChars += section.length;
  }

  for (const entry of files.slice(MAX_DETAILED_FILES)) {
    omittedDiffPaths.push(entry.file.path);
  }

  const summaryLines = files.map((entry) => formatFileSummary(entry.file));
  const selectedSessionLabel = selectedSession
    ? `${selectedSession.name?.trim() || selectedSession.id} (${selectedSession.id})`
    : undefined;

  const sections = [
    "Continue from Oppi Workspace Review.",
    "Treat the git-backed review bundle below as the current source of truth for these files.",
    "",
    "Instructions:",
    ...config.instructions.map((line) => `- ${line}`),
    "",
    "Review scope:",
    `- Workspace: ${workspace.name} (${workspace.id})`,
    `- Selected files: ${selectedCount}`,
    selectedSessionLabel ? `- Originating session scope: ${selectedSessionLabel}` : undefined,
    "",
    "Selected file summaries:",
    ...summaryLines,
    unavailableDiffs.length > 0 ? "" : undefined,
    unavailableDiffs.length > 0 ? "Files without inline diff context:" : undefined,
    ...unavailableDiffs.map((item) => `- ${item.path}: ${item.reason}`),
    omittedDiffPaths.length > 0 ? "" : undefined,
    omittedDiffPaths.length > 0
      ? `Additional selected files omitted from inline diff context due to size limits: ${omittedDiffPaths.join(", ")}`
      : undefined,
    detailSections.length > 0 ? "" : undefined,
    detailSections.length > 0 ? "Selected diff hunks:" : undefined,
    detailSections.length > 0 ? detailSections.join("\n\n") : undefined,
  ];

  return sections.filter((value): value is string => typeof value === "string").join("\n");
}

export async function prepareWorkspaceReviewSession(args: {
  workspaceId: string;
  workspace: Workspace;
  action: WorkspaceReviewSessionAction;
  paths: string[];
  selectedSession?: Session;
}): Promise<ReviewSessionSelection> {
  const { workspaceId, workspace, action, paths, selectedSession } = args;

  if (!workspace.hostMount) {
    throw new WorkspaceReviewSessionError(404, "Workspace review unavailable");
  }

  const gitStatus = await getGitStatus(workspace.hostMount);
  if (!gitStatus.isGitRepo) {
    throw new WorkspaceReviewSessionError(409, "Workspace is not a git repository");
  }

  const review = buildWorkspaceReviewFilesResponse({
    workspaceId,
    gitStatus,
    selectedSession,
    workspaceRoot: workspace.hostMount,
  });

  const uniquePaths = Array.from(
    new Set(paths.map((p) => normalizePath(p)).filter((value) => value.length > 0)),
  );

  if (uniquePaths.length === 0) {
    throw new WorkspaceReviewSessionError(400, "paths array required");
  }

  const reviewFilesByPath = new Map(
    review.files.map((file) => [normalizePath(file.path), file] as const),
  );
  const requestedFiles: WorkspaceReviewFile[] = [];
  const missingPaths: string[] = [];

  for (const path of uniquePaths) {
    const file = reviewFilesByPath.get(path);
    if (!file) {
      missingPaths.push(path);
      continue;
    }
    requestedFiles.push(file);
  }

  if (missingPaths.length > 0) {
    throw new WorkspaceReviewSessionError(
      400,
      `Selected files are no longer available in the current review: ${missingPaths.join(", ")}`,
    );
  }

  const detailedFiles = await gatherDetailedSelection({
    workspaceId,
    workspaceRoot: workspace.hostMount,
    requestedFiles,
  });
  const preamble = buildReviewPreamble({
    workspace,
    action,
    selectedSession,
    files: detailedFiles,
  });
  const config = actionConfig(action);
  const onlyRequestedFile = requestedFiles.length === 1 ? requestedFiles[0] : undefined;
  const sessionName = (
    onlyRequestedFile
      ? `${config.sessionTitle}: ${basename(onlyRequestedFile.path)}`
      : `${config.sessionTitle}: ${requestedFiles.length} files`
  ).slice(0, 160);

  const unavailableDiffs = detailedFiles
    .filter((entry) => typeof entry.diffUnavailableReason === "string")
    .map((entry) => ({
      path: entry.file.path,
      reason: entry.diffUnavailableReason ?? "Diff unavailable for this file.",
    }));

  const omittedDiffPaths = detailedFiles.slice(MAX_DETAILED_FILES).map((entry) => entry.file.path);

  return {
    files: requestedFiles,
    omittedDiffPaths,
    unavailableDiffs,
    preamble,
    visiblePrompt: config.visiblePrompt,
    sessionName,
  };
}

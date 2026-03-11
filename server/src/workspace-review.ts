import { normalizePath } from "./git-utils.js";
import type {
  GitFileStatus,
  GitStatus,
  Session,
  WorkspaceReviewFile,
  WorkspaceReviewFilesResponse,
} from "./types.js";

function fileFlags(statusCode: string): {
  isStaged: boolean;
  isUnstaged: boolean;
  isUntracked: boolean;
} {
  const indexChar = statusCode[0] ?? " ";
  const workChar = statusCode[1] ?? " ";
  const isUntracked = statusCode === "??";

  return {
    isStaged: !isUntracked && indexChar !== " ",
    isUnstaged: !isUntracked && workChar !== " ",
    isUntracked,
  };
}

export function buildWorkspaceReviewFilesResponse(args: {
  workspaceId: string;
  gitStatus: GitStatus;
  selectedSession?: Session;
  workspaceRoot?: string;
}): WorkspaceReviewFilesResponse {
  const { workspaceId, gitStatus, selectedSession, workspaceRoot } = args;

  const touchedPaths = new Set(
    (selectedSession?.changeStats?.changedFiles ?? [])
      .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
      .map((value) => normalizePath(value, workspaceRoot))
      .filter((value) => value.length > 0),
  );

  const files: WorkspaceReviewFile[] = gitStatus.files.map((file) =>
    buildReviewFile(file, touchedPaths),
  );

  let stagedFileCount = 0;
  let unstagedFileCount = 0;
  let untrackedFileCount = 0;
  let selectedSessionTouchedCount = 0;

  for (const file of files) {
    if (file.isStaged) stagedFileCount += 1;
    if (file.isUnstaged) unstagedFileCount += 1;
    if (file.isUntracked) untrackedFileCount += 1;
    if (file.selectedSessionTouched) selectedSessionTouchedCount += 1;
  }

  return {
    workspaceId,
    isGitRepo: gitStatus.isGitRepo,
    branch: gitStatus.branch,
    headSha: gitStatus.headSha,
    ahead: gitStatus.ahead,
    behind: gitStatus.behind,
    changedFileCount: files.length,
    stagedFileCount,
    unstagedFileCount,
    untrackedFileCount,
    addedLines: gitStatus.addedLines,
    removedLines: gitStatus.removedLines,
    selectedSessionId: selectedSession?.id,
    selectedSessionTouchedCount,
    files,
  };
}

function buildReviewFile(file: GitFileStatus, touchedPaths: Set<string>): WorkspaceReviewFile {
  const normalizedPath = file.path.replace(/\\/g, "/");
  const flags = fileFlags(file.status);

  return {
    path: file.path,
    status: file.status,
    addedLines: file.addedLines,
    removedLines: file.removedLines,
    isStaged: flags.isStaged,
    isUnstaged: flags.isUnstaged,
    isUntracked: flags.isUntracked,
    selectedSessionTouched: touchedPaths.has(normalizedPath),
  };
}

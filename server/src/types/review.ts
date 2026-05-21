import type { GitFileChange } from "./git.js";
import type { Session } from "./session.js";

export interface WorkspaceReviewFile extends GitFileChange {
  /** Two-char status code derived from `git status --porcelain`. */
  status: string;
  /** File has staged changes in the index. */
  isStaged: boolean;
  /** File has unstaged changes in the working tree. */
  isUnstaged: boolean;
  /** File is untracked. */
  isUntracked: boolean;
  /** File path was touched by the selected session. */
  selectedSessionTouched: boolean;
}

export interface WorkspaceReviewFilesResponse {
  workspaceId: string;
  isGitRepo: boolean;
  branch: string | null;
  headSha: string | null;
  ahead: number | null;
  behind: number | null;
  changedFileCount: number;
  stagedFileCount: number;
  unstagedFileCount: number;
  untrackedFileCount: number;
  addedLines: number;
  removedLines: number;
  selectedSessionId?: string;
  selectedSessionTouchedCount: number;
  files: WorkspaceReviewFile[];
}

export interface WorkspaceReviewDiffSpan {
  start: number;
  end: number;
  kind: "changed";
}

export interface WorkspaceReviewDiffLine {
  kind: "context" | "added" | "removed";
  text: string;
  oldLine: number | null;
  newLine: number | null;
  spans?: WorkspaceReviewDiffSpan[];
}

export interface WorkspaceReviewDiffHunk {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: WorkspaceReviewDiffLine[];
}

export interface WorkspaceReviewDiffResponse {
  workspaceId: string;
  path: string;
  baselineText: string;
  currentText: string;
  addedLines: number;
  removedLines: number;
  hunks: WorkspaceReviewDiffHunk[];
  /** Number of trace mutations (session diff only). */
  revisionCount?: number;
  /** Cache key for client-side caching (session diff only). */
  cacheKey?: string;
}

export type WorkspaceQuickActionOptionSource = "prompt";
export type WorkspaceQuickActionOptionScope = "user" | "project" | "temporary";

export interface WorkspaceQuickActionOption {
  id: string;
  title: string;
  commandName: string;
  description?: string;
  argumentHint?: string;
  source: WorkspaceQuickActionOptionSource;
  sourceScope?: WorkspaceQuickActionOptionScope;
  promptTemplateName: string;
}

export interface WorkspaceQuickActionsResponse {
  actions: WorkspaceQuickActionOption[];
}

export interface CreateWorkspaceQuickActionSessionRequest {
  paths: string[];
  selectedSessionId?: string;
  promptTemplateName: string;
}

export interface WorkspaceQuickActionSelectionResponse {
  promptTemplateName: string;
  selectedPathCount: number;
  visiblePrompt: string;
  filePaths: string[];
}

export interface WorkspaceQuickActionSessionResponse extends WorkspaceQuickActionSelectionResponse {
  session: Session;
}

export type ReviewCommentAuthor = "human" | "agent";
export type ReviewCommentStatus = "staged" | "sent" | "open" | "resolved" | "dismissed";
export type ReviewCommentSeverity = "error" | "warning" | "info";
export type ReviewCommentReferenceSource =
  | "git_diff"
  | "file"
  | "timeline_text"
  | "tool_output"
  | "terminal_output"
  | "image"
  | "unknown";

export interface ReviewCommentReference {
  source: ReviewCommentReferenceSource;
  label?: string;
  path?: string;
  side?: "old" | "new" | "file";
  startLine?: number;
  endLine?: number;
  selectedText?: string;
  languageHint?: string;
  toolCallId?: string;
  timelineItemId?: string;
  url?: string;
}

export interface ReviewCommentAttachment {
  id: string;
  kind: "image";
  mimeType: string;
  width?: number;
  height?: number;
  storageKey: string;
}

export interface ReviewComment {
  id: string;
  workspaceId: string;
  sessionId?: string;
  turnId?: string;
  author: ReviewCommentAuthor;
  status: ReviewCommentStatus;
  severity?: ReviewCommentSeverity;
  body: string;
  attachments?: ReviewCommentAttachment[];
  reference: ReviewCommentReference;
  createdAt: number;
  updatedAt: number;
  sentAt?: number;
}

export interface CreateReviewCommentRequest {
  sessionId?: string;
  author?: ReviewCommentAuthor;
  status?: ReviewCommentStatus;
  severity?: ReviewCommentSeverity;
  body: string;
  attachments?: ReviewCommentAttachment[];
  reference: ReviewCommentReference;
}

export interface UpdateReviewCommentRequest {
  status?: ReviewCommentStatus;
  severity?: ReviewCommentSeverity | null;
  body?: string;
}

export interface MarkReviewCommentsSentRequest {
  ids: string[];
  sessionId?: string;
  turnId?: string;
}

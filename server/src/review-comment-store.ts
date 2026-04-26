import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type {
  AttachReviewCommentsToTurnRequest,
  CreateReviewCommentRequest,
  ReviewComment,
  ReviewCommentAuthor,
  ReviewCommentReference,
  ReviewCommentReferenceSource,
  ReviewCommentSeverity,
  ReviewCommentStatus,
  UpdateReviewCommentRequest,
} from "./types.js";

export class ReviewCommentStoreError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ReviewCommentStoreError";
  }
}

const VALID_AUTHORS = new Set<ReviewCommentAuthor>(["human", "agent"]);
const VALID_STATUSES = new Set<ReviewCommentStatus>([
  "staged",
  "sent",
  "open",
  "resolved",
  "dismissed",
]);
const VALID_SEVERITIES = new Set<ReviewCommentSeverity>(["error", "warning", "info"]);
const VALID_SOURCES = new Set<ReviewCommentReferenceSource>([
  "git_diff",
  "file",
  "timeline_text",
  "tool_output",
  "terminal_output",
  "image",
  "unknown",
]);

interface StoredReviewComments {
  version: 1;
  comments: ReviewComment[];
}

export class ReviewCommentStore {
  private static readonly queues = new Map<string, Promise<void>>();

  constructor(
    private readonly dataDir: string,
    private readonly workspaceId: string,
  ) {}

  async list(
    filters: { sessionId?: string; status?: string; path?: string } = {},
  ): Promise<ReviewComment[]> {
    return this.withLock(async () => {
      const data = await this.read();
      return data.comments.filter((comment) => {
        if (filters.sessionId && comment.sessionId !== filters.sessionId) return false;
        if (filters.status && comment.status !== filters.status) return false;
        if (filters.path && comment.reference.path !== filters.path) return false;
        return true;
      });
    });
  }

  async create(input: CreateReviewCommentRequest): Promise<ReviewComment> {
    return this.withLock(async () => {
      const body = normalizeBody(input.body);
      const reference = normalizeReference(input.reference);
      const author = normalizeAuthor(input.author ?? "human");
      const status = normalizeStatus(input.status ?? "staged");
      const severity = input.severity === undefined ? undefined : normalizeSeverity(input.severity);
      const now = Date.now();
      const comment: ReviewComment = {
        id: randomUUID(),
        workspaceId: this.workspaceId,
        sessionId: normalizeOptionalString(input.sessionId),
        author,
        status,
        severity,
        body,
        attachments: normalizeAttachments(input.attachments),
        reference,
        createdAt: now,
        updatedAt: now,
      };

      const data = await this.read();
      data.comments.push(comment);
      await this.write(data);
      return comment;
    });
  }

  async update(id: string, patch: UpdateReviewCommentRequest): Promise<ReviewComment> {
    return this.withLock(async () => {
      const data = await this.read();
      const index = data.comments.findIndex((comment) => comment.id === id);
      if (index < 0) {
        throw new ReviewCommentStoreError(404, "Review comment not found");
      }

      const current = data.comments[index];
      if (!current) {
        throw new ReviewCommentStoreError(404, "Review comment not found");
      }

      const updated: ReviewComment = {
        ...current,
        status: patch.status === undefined ? current.status : normalizeStatus(patch.status),
        severity:
          patch.severity === undefined
            ? current.severity
            : patch.severity === null
              ? undefined
              : normalizeSeverity(patch.severity),
        body: patch.body === undefined ? current.body : normalizeBody(patch.body),
        updatedAt: Date.now(),
      };

      data.comments[index] = updated;
      await this.write(data);
      return updated;
    });
  }

  async delete(id: string): Promise<void> {
    await this.withLock(async () => {
      const data = await this.read();
      const next = data.comments.filter((comment) => comment.id !== id);
      if (next.length === data.comments.length) {
        throw new ReviewCommentStoreError(404, "Review comment not found");
      }
      await this.write({ ...data, comments: next });
    });
  }

  async attachToTurn(input: AttachReviewCommentsToTurnRequest): Promise<ReviewComment[]> {
    return this.withLock(async () => {
      if (!Array.isArray(input.ids) || input.ids.length === 0) {
        throw new ReviewCommentStoreError(400, "ids array required");
      }

      const ids = new Set(input.ids);
      const data = await this.read();
      const now = Date.now();
      const updated: ReviewComment[] = [];

      data.comments = data.comments.map((comment) => {
        if (!ids.has(comment.id)) return comment;
        const next: ReviewComment = {
          ...comment,
          status: "sent",
          sessionId: normalizeOptionalString(input.sessionId) ?? comment.sessionId,
          turnId: normalizeOptionalString(input.turnId) ?? comment.turnId,
          sentAt: now,
          updatedAt: now,
        };
        updated.push(next);
        return next;
      });

      if (updated.length !== ids.size) {
        throw new ReviewCommentStoreError(404, "One or more review comments were not found");
      }

      await this.write(data);
      return updated;
    });
  }

  private async withLock<T>(operation: () => Promise<T>): Promise<T> {
    const key = this.filePath;
    const previous = ReviewCommentStore.queues.get(key) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => {
      release = resolve;
    });
    ReviewCommentStore.queues.set(key, current);

    await previous;
    try {
      return await operation();
    } finally {
      release();
      if (ReviewCommentStore.queues.get(key) === current) {
        ReviewCommentStore.queues.delete(key);
      }
    }
  }

  private get filePath(): string {
    return join(this.dataDir, "review-comments", `${this.workspaceId}.json`);
  }

  private async read(): Promise<StoredReviewComments> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
      }

      if (!isStoredReviewComments(parsed)) {
        throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
      }

      return { version: 1, comments: parsed.comments };
    } catch (error) {
      if (isNodeError(error) && error.code === "ENOENT") {
        return { version: 1, comments: [] };
      }
      throw error;
    }
  }

  private async write(data: StoredReviewComments): Promise<void> {
    await mkdir(join(this.dataDir, "review-comments"), { recursive: true, mode: 0o700 });
    await writeFile(
      this.filePath,
      JSON.stringify({ version: 1, comments: data.comments }, null, 2),
      {
        mode: 0o600,
      },
    );
  }
}

function normalizeBody(value: unknown): string {
  if (typeof value !== "string") {
    throw new ReviewCommentStoreError(400, "body must be a string");
  }
  const normalized = value.trim();
  if (!normalized) {
    throw new ReviewCommentStoreError(400, "body required");
  }
  return normalized;
}

function normalizeAttachments(value: unknown): ReviewComment["attachments"] {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new ReviewCommentStoreError(400, "attachments must be an array");
  }
  if (value.length === 0) return undefined;
  if (value.length > 8) {
    throw new ReviewCommentStoreError(400, "attachments cannot exceed 8 items");
  }

  return value.map((attachment, index) => {
    if (!attachment || typeof attachment !== "object" || Array.isArray(attachment)) {
      throw new ReviewCommentStoreError(400, `attachments[${index}] must be an object`);
    }
    const record = attachment as Record<string, unknown>;
    const id = normalizeRequiredString(record.id, `attachments[${index}].id`);
    const mimeType = normalizeRequiredString(record.mimeType, `attachments[${index}].mimeType`);
    if ((record.kind as string) !== "image") {
      throw new ReviewCommentStoreError(400, `attachments[${index}].kind must be image`);
    }
    if (!mimeType.startsWith("image/")) {
      throw new ReviewCommentStoreError(
        400,
        `attachments[${index}].mimeType must be an image MIME type`,
      );
    }
    return {
      id,
      kind: "image",
      mimeType,
      width: normalizeOptionalPositiveInt(record.width, `attachments[${index}].width`),
      height: normalizeOptionalPositiveInt(record.height, `attachments[${index}].height`),
      storageKey: normalizeRequiredString(record.storageKey, `attachments[${index}].storageKey`),
    };
  });
}

function normalizeReference(value: unknown): ReviewCommentReference {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ReviewCommentStoreError(400, "reference object required");
  }
  const record = value as ReviewCommentReference;
  if (!VALID_SOURCES.has(record.source)) {
    throw new ReviewCommentStoreError(400, "reference.source is invalid");
  }
  return {
    source: record.source,
    label: normalizeOptionalString(record.label),
    path: normalizeOptionalString(record.path),
    side: normalizeSide(record.side),
    startLine: normalizeOptionalPositiveInt(record.startLine, "reference.startLine"),
    endLine: normalizeOptionalPositiveInt(record.endLine, "reference.endLine"),
    selectedText: normalizeOptionalString(record.selectedText),
    languageHint: normalizeOptionalString(record.languageHint),
    toolCallId: normalizeOptionalString(record.toolCallId),
    timelineItemId: normalizeOptionalString(record.timelineItemId),
    url: normalizeOptionalString(record.url),
  };
}

function normalizeAuthor(value: unknown): ReviewCommentAuthor {
  if (!VALID_AUTHORS.has(value as ReviewCommentAuthor)) {
    throw new ReviewCommentStoreError(400, "author is invalid");
  }
  return value as ReviewCommentAuthor;
}

function normalizeStatus(value: unknown): ReviewCommentStatus {
  if (!VALID_STATUSES.has(value as ReviewCommentStatus)) {
    throw new ReviewCommentStoreError(400, "status is invalid");
  }
  return value as ReviewCommentStatus;
}

function normalizeSeverity(value: unknown): ReviewCommentSeverity {
  if (!VALID_SEVERITIES.has(value as ReviewCommentSeverity)) {
    throw new ReviewCommentStoreError(400, "severity is invalid");
  }
  return value as ReviewCommentSeverity;
}

function normalizeSide(value: unknown): "old" | "new" | "file" | undefined {
  if (value === undefined) return undefined;
  if (value === "old" || value === "new" || value === "file") return value;
  throw new ReviewCommentStoreError(400, "reference.side is invalid");
}

function normalizeOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : undefined;
}

function normalizeRequiredString(value: unknown, field: string): string {
  const normalized = normalizeOptionalString(value);
  if (!normalized) {
    throw new ReviewCommentStoreError(400, `${field} required`);
  }
  return normalized;
}

function normalizeOptionalPositiveInt(value: unknown, field: string): number | undefined {
  if (value === undefined) return undefined;
  if (!Number.isInteger(value) || (value as number) < 1) {
    throw new ReviewCommentStoreError(400, `${field} must be a positive integer`);
  }
  return value as number;
}

function isStoredReviewComments(value: unknown): value is StoredReviewComments {
  return (
    typeof value === "object" &&
    value !== null &&
    "comments" in value &&
    Array.isArray((value as { comments?: unknown }).comments)
  );
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}

import { ReviewCommentSqliteStore } from "./storage/review-comment-sqlite-store.js";
import {
  ReviewCommentStoreError,
  type ReviewCommentListFilters,
} from "./storage/review-comment-dao.js";
import type {
  MarkReviewCommentsSentRequest,
  CreateReviewCommentRequest,
  ReviewComment,
  UpdateReviewCommentRequest,
} from "./types.js";

export { ReviewCommentStoreError };

/**
 * Compatibility wrapper for older direct imports.
 *
 * Route code should prefer Storage's review-comment DAO methods so review
 * comments share the session-state SQLite backend.
 */
export class ReviewCommentStore {
  private readonly store: ReviewCommentSqliteStore;

  constructor(
    dataDir: string,
    private readonly workspaceId: string,
  ) {
    this.store = new ReviewCommentSqliteStore(dataDir);
  }

  async list(filters: ReviewCommentListFilters = {}): Promise<ReviewComment[]> {
    return this.store.list(this.workspaceId, filters);
  }

  async create(input: CreateReviewCommentRequest): Promise<ReviewComment> {
    return this.store.create(this.workspaceId, input);
  }

  async update(id: string, patch: UpdateReviewCommentRequest): Promise<ReviewComment> {
    return this.store.update(this.workspaceId, id, patch);
  }

  async markSent(input: MarkReviewCommentsSentRequest): Promise<ReviewComment[]> {
    return this.store.markSent(this.workspaceId, input);
  }

  close(): void {
    this.store.close();
  }
}

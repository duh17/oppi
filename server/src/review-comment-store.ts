import { ReviewCommentSqliteStore } from "./storage/review-comment-sqlite-store.js";
import {
  ReviewCommentStoreError,
  type ReviewCommentListFilters,
} from "./storage/review-comment-dao.js";
import type {
  AttachReviewCommentsToTurnRequest,
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

  async delete(id: string): Promise<void> {
    this.store.delete(this.workspaceId, id);
  }

  async attachToTurn(input: AttachReviewCommentsToTurnRequest): Promise<ReviewComment[]> {
    return this.store.attachToTurn(this.workspaceId, input);
  }

  close(): void {
    this.store.close();
  }
}

import type {
  AttachReviewCommentsToTurnRequest,
  CreateReviewCommentRequest,
  ReviewComment,
  UpdateReviewCommentRequest,
} from "../types.js";

export class ReviewCommentStoreError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ReviewCommentStoreError";
  }
}

export interface ReviewCommentListFilters {
  sessionId?: string;
  status?: string;
  path?: string;
}

export interface ReviewCommentDao {
  list(workspaceId: string, filters?: ReviewCommentListFilters): ReviewComment[];
  create(workspaceId: string, input: CreateReviewCommentRequest): ReviewComment;
  update(workspaceId: string, id: string, patch: UpdateReviewCommentRequest): ReviewComment;
  delete(workspaceId: string, id: string): void;
  attachToTurn(workspaceId: string, input: AttachReviewCommentsToTurnRequest): ReviewComment[];
}

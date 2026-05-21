// ─── Workspace File Browser ───

export interface FileEntry {
  name: string;
  type: "file" | "directory";
  size: number;
  /** Milliseconds since epoch. */
  modifiedAt: number;
  /** Workspace-relative path when the caller needs full context. */
  path?: string;
}

/** Directory listing response shape (GET /workspaces/:id/contents/<dir>). */
export interface DirectoryListingResponse {
  path: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** Flat file index for client-side fuzzy search (GET /workspaces/:id/paths). */
export interface FileIndexResponse {
  /** Workspace-relative file paths (no directories, no ignored/sensitive paths). */
  paths: string[];
  truncated: boolean;
}

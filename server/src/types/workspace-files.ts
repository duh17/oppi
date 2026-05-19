// ─── Workspace File Browser ───

export interface FileEntry {
  name: string;
  type: "file" | "directory";
  size: number;
  /** Milliseconds since epoch. */
  modifiedAt: number;
  /** Workspace-relative path (present in search results). */
  path?: string;
}

/** Directory listing response shape (GET /workspaces/:id/files/<dir>/). */
export interface DirectoryListingResponse {
  path: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** File search response shape (GET /workspaces/:id/files?search=<q>). */
export interface FileSearchResponse {
  query: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** Flat file index for client-side fuzzy search (GET /workspaces/:id/file-index). */
export interface FileIndexResponse {
  /** Workspace-relative file paths (no directories, no ignored/sensitive paths). */
  paths: string[];
  truncated: boolean;
}

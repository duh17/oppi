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

/** Directory listing response shape (GET /workspaces/:id/contents/<dir> and GET /host/contents/<dir>). */
export interface DirectoryListingResponse {
  path: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** Flat file index for client-side fuzzy search (GET /workspaces/:id/paths). */
export interface FileIndexResponse {
  /** Workspace-relative file paths for fuzzy search; bulky generated paths may be omitted. */
  paths: string[];
  truncated: boolean;
}

/** Advertised on GET /server/info. Missing capability means the client stays read-only. */
export interface WorkspaceFileEditingCapability {
  version: 1;
  maxBytes: number;
}

/** JSON body for PUT /files/current?origin=workspace. */
export interface WorkspaceFileEditWriteResponse {
  etag: string;
  size: number;
  mtimeMs: number;
}

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

/**
 * Audio format read from container headers: MP3 first frame, MP4 `stsd`/`esds`,
 * FLAC STREAMINFO, WAV `fmt `. Every field is optional: a container whose
 * numbers fall outside the audio ranges reports only the codec.
 */
export interface MediaInfoFormat {
  /** Codec family: `mp3`, `aac`, `flac`, `pcm`, `alac`, `opus`, ... */
  codec: string;
  /** Samples per second, 8 kHz to 768 kHz. */
  sampleRate?: number;
  channels?: number;
  /** Bits per second, 1 kbit/s to 10 Mbit/s. */
  bitrate?: number;
}

/** Tags read from the container; a malformed tag section reports none. */
export interface MediaInfoTags {
  title?: string;
  artist?: string;
  album?: string;
}

/**
 * Header-derived audio metadata (GET /files/current/media-info). Every field is
 * optional and absent means unknown, so an older client ignores what it does
 * not read and a newer client treats a missing key as unknown.
 */
export interface MediaInfo {
  durationSeconds?: number;
  format?: MediaInfoFormat;
  tags?: MediaInfoTags;
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

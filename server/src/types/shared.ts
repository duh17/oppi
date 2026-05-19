// ─── API Types ───

export interface ApiError {
  error: string;
  code?: string;
}

// ─── Shared UI payload types ───

export interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

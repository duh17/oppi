export interface SessionTimeRange {
  sinceMs?: number;
  /** Inclusive upper bound, matching session search semantics. */
  untilMs?: number;
}

export type SessionTimeRangeParseResult = SessionTimeRange & { error?: string };

/** Parse the epoch, ISO, and local-calendar bounds shared by session search and list. */
export function parseSessionTimeRange(
  sinceRaw: string | undefined,
  untilRaw: string | undefined,
  subject: "session search" | "session list",
): SessionTimeRangeParseResult {
  const since = parseSessionTimeBound(sinceRaw, false, subject);
  if (since.error) return { error: since.error };
  const until = parseSessionTimeBound(untilRaw, true, subject);
  if (until.error) return { error: until.error };
  if (since.value !== undefined && until.value !== undefined && since.value > until.value) {
    return {
      error:
        subject === "session search"
          ? "since must be before or equal to until"
          : "session list since must be before or equal to until",
    };
  }
  return {
    ...(since.value !== undefined ? { sinceMs: since.value } : {}),
    ...(until.value !== undefined ? { untilMs: until.value } : {}),
  };
}

function parseSessionTimeBound(
  raw: string | undefined,
  isEnd: boolean,
  subject: "session search" | "session list",
): { value?: number; error?: string } {
  const trimmed = raw?.trim();
  if (!trimmed) return {};

  const numeric = Number.parseInt(trimmed, 10);
  if (/^\d+$/.test(trimmed) && Number.isFinite(numeric)) {
    return { value: numeric };
  }

  const dateOnly = trimmed.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (dateOnly) {
    const year = Number.parseInt(dateOnly[1] ?? "", 10);
    const monthIndex = Number.parseInt(dateOnly[2] ?? "", 10) - 1;
    const day = Number.parseInt(dateOnly[3] ?? "", 10);
    const date = new Date(year, monthIndex, day, 0, 0, 0, 0);
    if (
      Number.isNaN(date.getTime()) ||
      date.getFullYear() !== year ||
      date.getMonth() !== monthIndex ||
      date.getDate() !== day
    ) {
      return { error: `invalid ${subject} date: ${trimmed}` };
    }
    if (!isEnd) return { value: date.getTime() };
    date.setDate(date.getDate() + 1);
    return { value: date.getTime() - 1 };
  }

  const ms = Date.parse(trimmed);
  if (Number.isNaN(ms)) {
    return { error: `invalid ${subject} timestamp: ${trimmed}` };
  }
  return { value: ms };
}

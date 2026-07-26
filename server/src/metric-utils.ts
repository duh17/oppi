/**
 * Shared helpers for metric files (server-resource-sampler, server-metric-writer,
 * server-stats). Extracted to eliminate copy-paste across metric modules.
 */

import { appendFileSync, existsSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";

/** Format epoch-ms as "YYYY-MM-DD" in UTC. */
export function dateString(ts: number): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** Round to two decimal places. */
export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Read a retention-days value from an env var, with a positive-integer fallback. */
export function retentionDaysFromEnv(envVarName: string, defaultDays: number): number {
  const raw = process.env[envVarName]?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return defaultDays;
}

/**
 * Read a per-file byte budget from an environment variable.
 *
 * No default budget is applied here: silent telemetry dropping should be an
 * explicit operator choice, not a hidden constant. A value of 0 disables the
 * cap explicitly for local debugging.
 */
export function jsonlMaxBytesFromEnv(envVarName: string): number | null {
  const raw = process.env[envVarName]?.trim() ?? "";
  if (raw === "" || raw === "0") return null;

  const parsed = Number(raw);
  if (Number.isInteger(parsed) && parsed > 0) return parsed;
  return null;
}

/**
 * Append a JSONL record only if doing so keeps the file under a byte budget.
 *
 * Returns false when the record is dropped. The caller decides whether to log a
 * warning; this helper stays silent so a full telemetry file cannot cause a
 * warning loop that writes another unbounded log.
 */
export function appendJsonlLineWithByteLimit(
  filePath: string,
  line: string,
  maxBytes: number | null,
): boolean {
  if (maxBytes === null) {
    appendFileSync(filePath, line, { encoding: "utf8", mode: 0o600 });
    return true;
  }

  const lineBytes = Buffer.byteLength(line, "utf8");
  if (lineBytes > maxBytes) return false;

  let currentBytes: number;
  try {
    currentBytes = statSync(filePath).size;
  } catch {
    currentBytes = 0;
  }

  if (currentBytes + lineBytes > maxBytes) return false;
  appendFileSync(filePath, line, { encoding: "utf8", mode: 0o600 });
  return true;
}

/**
 * Remove daily JSONL files older than `retentionDays`.
 *
 * Matches files of the form `${prefix}YYYY-MM-DD${suffix}` in `dir`.
 * Best-effort — silently ignores read/unlink errors.
 */
export function pruneOldJsonlFiles(
  dir: string,
  prefix: string,
  suffix: string,
  retentionDays: number,
): void {
  const retentionMs = retentionDays * 24 * 60 * 60 * 1000;
  const cutoffMs = Date.now() - retentionMs;

  if (!existsSync(dir)) return;

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.startsWith(prefix) || !entry.endsWith(suffix)) continue;
    const datePart = entry.slice(prefix.length, -suffix.length);
    const fileDate = Date.parse(`${datePart}T00:00:00.000Z`);
    if (Number.isNaN(fileDate) || fileDate >= cutoffMs) continue;
    try {
      unlinkSync(join(dir, entry));
    } catch {
      // Best effort
    }
  }
}

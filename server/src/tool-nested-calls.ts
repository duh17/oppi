import type { NestedToolCallRecord, NestedToolCalls, ToolDisplay } from "./types.js";
import { resolveToolDisplay } from "./mobile-renderer.js";

// Mirror Pi's recorder limits. The boundary also handles imported, untrusted JSONL.
export function validatedNestedCalls(
  value: unknown,
  displayFor: (name: string) => ToolDisplay | undefined = resolveToolDisplay,
): NestedToolCalls | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (!Array.isArray(record.calls) || typeof record.complete !== "boolean") return undefined;
  let complete = record.complete && record.calls.length <= 256;
  let totalBytes = 0;
  const calls: NestedToolCallRecord[] = [];
  for (const raw of record.calls.slice(0, 256)) {
    if (!raw || typeof raw !== "object") {
      complete = false;
      continue;
    }
    const c = raw as Record<string, unknown>;
    if (
      typeof c.id !== "string" ||
      typeof c.name !== "string" ||
      !["ok", "error", "unfinished"].includes(String(c.status))
    ) {
      complete = false;
      continue;
    }
    const call: NestedToolCallRecord = {
      id: c.id,
      name: c.name,
      status: c.status as NestedToolCallRecord["status"],
    };
    const display = displayFor(call.name);
    if (display) call.display = display;
    if (c.arguments && typeof c.arguments === "object" && !Array.isArray(c.arguments)) {
      try {
        const json = JSON.stringify(c.arguments);
        const bytes = Buffer.byteLength(json);
        if (bytes <= 8 * 1024 && totalBytes + bytes <= 32 * 1024) {
          call.arguments = JSON.parse(json) as NonNullable<NestedToolCallRecord["arguments"]>;
          totalBytes += bytes;
        } else {
          call.argumentsBytes = bytes;
          complete = false;
        }
      } catch {
        complete = false;
      }
    } else if (
      typeof c.argumentsBytes === "number" &&
      Number.isSafeInteger(c.argumentsBytes) &&
      c.argumentsBytes >= 0
    ) {
      call.argumentsBytes = c.argumentsBytes;
    }
    if (typeof c.durationMs === "number" && Number.isFinite(c.durationMs) && c.durationMs >= 0)
      call.durationMs = c.durationMs;
    if (typeof c.error === "string") call.error = c.error.slice(0, 500);
    calls.push(call);
  }
  return { calls, complete };
}

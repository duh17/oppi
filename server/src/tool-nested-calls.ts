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
    if (typeof c.id !== "string" || typeof c.name !== "string" || typeof c.status !== "string") {
      complete = false;
      continue;
    }
    const call: NestedToolCallRecord = {
      id: c.id,
      name: c.name,
      status: c.status,
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
        }
      } catch {
        // Argument elision keeps the call; only dropping calls changes completeness.
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

/**
 * The nested calls a durable tool result lists in its details, as the protocol shows them.
 * pi-durable's code mode writes `details.calls` once with its result (`CodemodeToolDetails`):
 * `{ id: number; name; args: string; status; durationMs?; error? }` per call, where `id` is the
 * script's call number, the nested call's ID is `<callId>/c<id>` (the same ID its live slot in
 * `pi.live.nestedTools` had), and `args` is compact JSON cut for display. Recognized by that
 * shape, never by tool name: details whose `calls` do not all match it list no nested calls.
 */
export function durableNestedCalls(
  callId: string,
  details: unknown,
  displayFor?: (name: string) => ToolDisplay | undefined,
): NestedToolCalls | undefined {
  const listed = (details as { calls?: unknown } | null | undefined)?.calls;
  if (!Array.isArray(listed) || listed.length === 0) return undefined;
  const calls: Array<Record<string, unknown>> = [];
  for (const raw of listed) {
    const c = raw as Record<string, unknown> | null;
    if (
      !c ||
      typeof c !== "object" ||
      !Number.isSafeInteger(c.id) ||
      typeof c.name !== "string" ||
      typeof c.args !== "string" ||
      typeof c.status !== "string"
    )
      return undefined;
    calls.push({
      id: `${callId}/c${c.id as number}`,
      name: c.name,
      // A call still running when its script ended; Pi's word for it.
      status: c.status === "running" ? "unfinished" : c.status,
      ...durableArguments(c.args),
      durationMs: c.durationMs,
      error: c.error,
    });
  }
  return validatedNestedCalls({ calls, complete: true }, displayFor);
}

/** A JSON object stays arguments; text cut for display (no longer JSON) or another value is its size. */
function durableArguments(args: string): { arguments?: unknown; argumentsBytes?: number } {
  if (!args) return {};
  try {
    const parsed: unknown = JSON.parse(args);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
      return { arguments: parsed };
  } catch {
    // Cut for display.
  }
  return { argumentsBytes: Buffer.byteLength(args) };
}

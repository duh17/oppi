import type { ToolOutputAvailability } from "./types.js";
import { asRecord } from "./json-shape.js";
export function outputAvailability(details: unknown): ToolOutputAvailability {
  const payload = asRecord(details);
  const truncation = asRecord(payload?.truncation);
  const totalBytes = truncation?.totalBytes;
  const sidecar =
    typeof payload?.fullOutputPath === "string" && payload.fullOutputPath.trim().length > 0;
  return {
    complete: truncation?.truncated !== true,
    ...(typeof totalBytes === "number" && Number.isSafeInteger(totalBytes) && totalBytes >= 0
      ? { totalBytes }
      : {}),
    ...(sidecar ? { source: "sidecar" as const } : {}),
  };
}

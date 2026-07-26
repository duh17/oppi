import { readFileSync } from "node:fs";

export const MAX_INLINE_DEFINITION_BYTES = 64 * 1024;

export function readDefinitionInput(
  flags: Record<string, string>,
  options: { required?: boolean; update?: boolean } = {},
): Record<string, unknown> {
  const hasFile = Object.hasOwn(flags, "definition");
  const hasInline = Object.hasOwn(flags, "definition-json");
  if (hasFile && hasInline) {
    throw new Error("exactly one of --definition or --definition-json is required");
  }
  if (!hasFile && !hasInline) {
    if (options.required) {
      throw new Error("exactly one of --definition or --definition-json is required");
    }
    return {};
  }

  let parsed: unknown;
  if (hasInline) {
    const inline = flags["definition-json"] ?? "";
    assertInlineDefinitionSize(inline);
    try {
      parsed = JSON.parse(inline) as unknown;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`--definition-json must be valid JSON: ${message}`, { cause: error });
    }
  } else {
    const path = flags.definition?.trim();
    if (!path) throw new Error("--definition must be a non-empty file path");
    parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("definition must be a JSON object");
  }
  if (options.update && Object.keys(parsed).length === 0) {
    throw new Error("definition update must not be empty");
  }
  return parsed as Record<string, unknown>;
}

export function assertInlineDefinitionSize(value: string | undefined): void {
  if (value === undefined) return;
  if (Buffer.byteLength(value, "utf8") > MAX_INLINE_DEFINITION_BYTES) {
    throw new Error(
      `--definition-json exceeds maximum size of ${MAX_INLINE_DEFINITION_BYTES} bytes`,
    );
  }
}

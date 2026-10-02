// Pure transcript metadata: safe to import without loading the Durable runtime.
export type TranscriptCard = {
  title: string;
  subtitle?: string;
  status?: string;
  body?: string;
  fields?: Array<{ label: string; value: string }>;
  accent?: "info" | "success" | "warning" | "error";
  at: number;
};

/** Display-only evidence; never add these fields to model messages. */
export function sanitizeTranscriptCard(
  value: unknown,
): (TranscriptCard & { kind: "custom" }) | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return undefined;
  const data = value as Record<string, unknown>;
  if (
    typeof data.title !== "string" ||
    !data.title.trim() ||
    typeof data.at !== "number" ||
    !Number.isFinite(data.at) ||
    !Number.isFinite(new Date(data.at).getTime())
  )
    return undefined;
  const fieldText = (text: string): string =>
    text.length <= 500 ? text : `${text.slice(0, 497)}…`;
  const card: TranscriptCard & { kind: "custom" } = {
    kind: "custom",
    title: fieldText(data.title.trim()),
    at: data.at,
  };
  for (const key of ["subtitle", "status"] as const)
    if (typeof data[key] === "string") card[key] = fieldText(data[key]);
  if (typeof data.body === "string") {
    // Keep the full reason in entry.data; bound only its display projection.
    const bytes = Buffer.from(data.body, "utf8");
    card.body =
      bytes.length <= 4096
        ? data.body
        : `${new TextDecoder().decode(bytes.subarray(0, 4093), { stream: true })}…`;
  }
  if (Array.isArray(data.fields)) {
    card.fields = data.fields.slice(0, 8).flatMap((field) => {
      if (!field || typeof field !== "object" || Array.isArray(field))
        return [];
      const item = field as Record<string, unknown>;
      return typeof item.label === "string" && typeof item.value === "string"
        ? [{ label: fieldText(item.label), value: fieldText(item.value) }]
        : [];
    });
  }
  if (
    typeof data.accent === "string" &&
    ["info", "success", "warning", "error"].includes(data.accent)
  )
    card.accent = data.accent as TranscriptCard["accent"];
  return card;
}

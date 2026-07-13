function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
}

function audioPresentationText(root: Record<string, unknown>): string | undefined {
  const candidates = [root.text, root.message, root.transcript];
  for (const candidate of candidates) {
    if (typeof candidate !== "string") continue;
    const text = candidate.trim();
    if (text) return text;
  }
  return undefined;
}

export function normalizeAudioPresentationDetails(details: unknown): unknown {
  const root = asRecord(details);
  if (!root || Array.isArray(root)) return details;
  if (root.kind === "audio_presentation") return details;

  const audio = asRecord(root.audio);
  if (!audio || Array.isArray(audio) || audio.kind !== "audio") return details;

  const text = audioPresentationText(root);
  return {
    ...root,
    kind: "audio_presentation",
    ...(text ? { text } : {}),
  };
}

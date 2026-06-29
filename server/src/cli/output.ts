export type CliJsonEnvelope =
  | { ok: true; data: Record<string, unknown> }
  | { ok: false; error: { message: string; status?: number } };

export function writeJsonEnvelope(envelope: CliJsonEnvelope): void {
  process.stdout.write(JSON.stringify(envelope, null, 2) + "\n");
}

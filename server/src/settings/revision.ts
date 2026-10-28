/** A saved revision, or a `baseRevision` naming one: a non-negative safe integer. */
export function isRevision(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

import { migrateIconChoice } from "../icon-choice.js";

export function iconChoiceFromFlag(value: string): Record<string, string> {
  const trimmed = value.trim();
  if (trimmed.toLowerCase() === "default") return { kind: "default" };
  const icon = migrateIconChoice(trimmed);
  if (icon.kind === "default") {
    throw new Error("--icon must be default, one Unicode emoji, or an SF Symbol name");
  }
  return icon;
}

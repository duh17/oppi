import { randomBytes } from "node:crypto";
import { posix } from "node:path";

import type { Workspace } from "./types.js";

export function sandboxWorkspaceSlug(workspace: Workspace): string {
  return (
    (workspace.name || workspace.id)
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || workspace.id
  );
}

export function resolveSandboxGuestCwd(workspace: Workspace): string {
  return posix.join("/workspace", sandboxWorkspaceSlug(workspace));
}

export function sandboxSkillGuestRoot(guestCwd: string, skillName: string): string {
  return posix.join(guestCwd, ".pi", "skills", safeGuestSegment(skillName));
}

/** Random capability that binds journal evidence to a Skill without encoding its path. */
export function createSandboxSkillBindingToken(): string {
  return `sandbox-binding-v1_${randomBytes(32).toString("hex")}`;
}

export function isSandboxSkillBindingToken(value: unknown): value is string {
  return typeof value === "string" && /^sandbox-binding-v1_[a-f0-9]{64}$/.test(value);
}

function safeGuestSegment(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "resource"
  );
}

/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { createLocalApiCommandContext } from "../command-support.js";
import {
  codeValue,
  printDetails,
  printList,
  setCapturedCliExitCode,
  writeJsonEnvelope,
} from "../output.js";
import { apiStatus } from "../resources.js";

type SkillSummary = {
  id?: string;
  name?: string;
  description?: string;
  state?: string;
  editable?: boolean;
  provenance?: { label?: string };
};

type SkillDetail = {
  summary?: SkillSummary;
  skillMarkdown?: string;
  files?: string[];
};

/** Restricted server Skill catalog/file commands used by Oppi control sessions. */
export async function cmdSkill(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";
  const { call, output } = createLocalApiCommandContext(storage, jsonOutput);

  try {
    if (mode === "list") {
      const result = await call<{ skills?: SkillSummary[] }>("/server/resources/skills");
      output(result, () => {
        const skills = Array.isArray(result.skills) ? result.skills : [];
        printList(
          `Skills (${skills.length})`,
          skills.map((skill) => ({
            id: skill.id ?? "?",
            status: skill.state ?? "?",
            title: skill.name ?? "(unnamed)",
            meta: [skill.editable ? "editable" : "read-only", skill.provenance?.label ?? ""].filter(
              Boolean,
            ),
          })),
          { empty: "No server Skills configured." },
        );
      });
      return;
    }

    const id = positional[0]?.trim();
    if (!id) throw new Error("skill id is required");
    const encodedId = encodeURIComponent(id);

    if (mode === "get") {
      const result = await call<SkillDetail>(`/server/resources/skills/${encodedId}`);
      output(result, () => {
        printDetails("Skill", [
          ["ID", codeValue(result.summary?.id ?? id)],
          ["Name", result.summary?.name ?? "(unnamed)"],
          ["State", result.summary?.state ?? "unknown"],
          ["Editing", result.summary?.editable ? "Editable" : "Read-only"],
          ["Files", String(result.files?.length ?? 0)],
        ]);
      });
      return;
    }

    const path = flags.path?.trim();
    if (!path) throw new Error("--path is required");
    const fileRoute = `/server/resources/skills/${encodedId}/file?path=${encodeURIComponent(path)}`;

    if (mode === "file") {
      const result = await call<{ content?: string; revision?: string }>(fileRoute);
      output(result, () => {
        printDetails("Skill file", [
          ["Skill", codeValue(id)],
          ["Path", codeValue(path)],
          ["Bytes", String(Buffer.byteLength(result.content ?? "", "utf8"))],
          ["Revision", codeValue(result.revision ?? "unknown")],
        ]);
      });
      return;
    }

    if (mode === "update-file") {
      const baseRevision = flags["base-revision"]?.trim();
      if (!baseRevision) throw new Error("--base-revision is required");
      const contentJson = flags["content-json"];
      if (contentJson === undefined) throw new Error("--content-json is required");
      let content: unknown;
      try {
        content = JSON.parse(contentJson) as unknown;
      } catch {
        throw new Error("--content-json must be a valid JSON string");
      }
      if (typeof content !== "string") throw new Error("--content-json must be a JSON string");
      const result = await call<{ content?: string; revision?: string }>(fileRoute, {
        method: "PUT",
        body: { content, baseRevision },
      });
      output(result, () => {
        printDetails("✓ Skill file updated", [
          ["Skill", codeValue(id)],
          ["Path", codeValue(path)],
          ["Bytes", String(Buffer.byteLength(result.content ?? content, "utf8"))],
          ["Revision", codeValue(result.revision ?? "unknown")],
        ]);
      });
      return;
    }

    throw new Error("Usage: oppi skill list|get|file|update-file");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    const status = apiStatus(error);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      setCapturedCliExitCode(1);
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

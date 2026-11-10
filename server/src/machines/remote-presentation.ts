import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { relative, resolve } from "node:path";
import type { Skill } from "@earendil-works/pi-coding-agent";
import type { InternalTarget } from "../internal-urls.js";
import { isPathWithinRoot } from "../path-utils.js";

/** The prompt section of a conversation whose tools run on a machine. */
export function remotePromptSection(machine: string, root: string): string {
  return `Your tools run on ${machine} in ${root}. Paths, programs and localhost refer to that machine. The \`oppi\` command is not available there; use the subagent tool to start work.`;
}

/** The most a `skill://` read returns: a Skill's own files, never a large asset. */
const SKILL_FILE_MAX_BYTES = 1024 * 1024;

/** Each session's Skills by name, for the sessions whose tools run on a machine. */
const skillDirs = new Map<string, Map<string, string>>();

/**
 * The Skills a remote session presents. Their files are on this host, not on the machine its
 * `read` tool reads from, so each location becomes `skill://<name>/<file>`, which `read` serves
 * from this host's disk, inside that Skill's directory only.
 */
export function presentRemoteSkills(sessionId: string, skills: readonly Skill[]): Skill[] {
  skillDirs.set(sessionId, new Map(skills.map((skill) => [skill.name, skill.baseDir])));
  return skills.map((skill) => ({
    ...skill,
    filePath: `skill://${skill.name}/${relative(skill.baseDir, skill.filePath)}`,
  }));
}

/** `read skill://<name>[/<path>]` for session `sessionId`: a file's text, or a directory's listing. */
export async function readSkillUrl(sessionId: string, target: InternalTarget): Promise<string> {
  const dirs = skillDirs.get(sessionId);
  if (!dirs)
    throw new Error("skill:// is for sessions whose tools run on another machine; read the file.");
  const base = dirs.get(target.id);
  if (!base)
    throw new Error(
      `skill://${target.id} is not one of this session's skills. They are: ${[...dirs.keys()].join(", ") || "none"}.`,
    );
  const path = await realpath(resolve(base, `.${target.path || "/SKILL.md"}`)).catch(() => {
    throw new Error(`skill://${target.id}${target.path} does not exist.`);
  });
  // The real paths: a link inside a Skill that leaves it yields nothing.
  if (!isPathWithinRoot(path, await realpath(base)))
    throw new Error(`skill://${target.id}${target.path} is outside the skill's directory.`);
  const info = await stat(path);
  if (info.isDirectory())
    return (await readdir(path, { withFileTypes: true }))
      .map((entry) => (entry.isDirectory() ? `${entry.name}/` : entry.name))
      .join("\n");
  if (info.size > SKILL_FILE_MAX_BYTES)
    throw new Error(`skill://${target.id}${target.path} is larger than 1 MiB.`);
  return readFile(path, "utf8");
}

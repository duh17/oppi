import { readFileSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import {
  DefaultResourceLoader,
  SettingsManager,
  formatSkillsForPrompt,
  stripFrontmatter,
  type Skill,
} from "@earendil-works/pi-coding-agent";
import { AgentConfigurationError } from "./agent-launch-errors.js";
import type { DurableAgentResources } from "./durable-agent.js";
import type { ReadonlyMount } from "./gondolin-manager.js";
import {
  assertSelectedAgentResourcesAvailable,
  assertSelectedAgentSkillsLoaded,
  assertSelectedAgentSkillsOutsideUntrustedProject,
  hostWorkspacePathToGuest,
  normalizeSelectedAgentSkillPaths,
  redactHostEnvironment,
  sandboxGuestSkills,
} from "./sdk-backend.js";

type ContextFile = { path: string; content: string };

/** The AGENTS files and Skills a durable session presents, as an SDK session loads them. */
export interface DurableProjectResources {
  /** As presented to the model: guest paths in a sandbox. */
  readonly contextFiles: readonly ContextFile[];
  /** As presented to the model: guest paths in a sandbox. */
  readonly skills: readonly Skill[];
  /** Host `SKILL.md` per Skill name, for `/skill:` expansion on the server. */
  readonly hostSkillFiles: ReadonlyMap<string, string>;
  /** Read-only VM mounts for the presented sandbox Skill directories. */
  readonly readonlyMounts: readonly ReadonlyMount[];
}

/**
 * Pi's resource discovery without classic extensions, prompt templates, or themes:
 * durable sessions cannot run classic extension factories.
 */
export async function loadDurableProjectResources(options: {
  hostCwd: string;
  agentDir: string;
  /** Present for sandbox sessions; paths are rewritten into the guest. */
  sandboxGuestCwd?: string;
  /** Host sessions: the project trust decision. Sandbox sessions are always trusted. */
  projectTrusted: boolean;
  /** The saved Agent's selection, from the session's `oppi.agent` document. */
  resources?: DurableAgentResources;
  /** False when the Agent's instructions replace the prompt: no context files at all. */
  projectContext?: boolean;
}): Promise<DurableProjectResources> {
  const { hostCwd, agentDir, sandboxGuestCwd, resources } = options;
  const selectedSkillPaths = normalizeSelectedAgentSkillPaths(resources?.skillPaths, hostCwd);
  const projectTrusted = sandboxGuestCwd !== undefined || options.projectTrusted;
  if (!projectTrusted)
    assertSelectedAgentSkillsOutsideUntrustedProject(selectedSkillPaths, hostCwd);
  // A sandbox sees only its workspace. Skill directories are mounted into the guest and
  // `/skill:` reads the host file, so every Skill must really live in the workspace.
  const workspaceRoot = sandboxGuestCwd === undefined ? undefined : realPath(hostCwd);
  const inWorkspace = (path: string): boolean =>
    workspaceRoot === undefined || isWithin(workspaceRoot, realPath(path));
  const escapedSkillPaths = (selectedSkillPaths ?? []).filter((path) => !inWorkspace(path));
  if (escapedSkillPaths.length > 0) throw skillsOutsideWorkspace(escapedSkillPaths);
  assertSelectedAgentResourcesAvailable(selectedSkillPaths, undefined);
  /** Sandbox AGENTS files: only those inside the workspace, at guest paths, redacted. */
  const inGuest = (files: readonly ContextFile[], guestCwd: string): ContextFile[] =>
    files.flatMap((file) => {
      const path = inWorkspace(file.path)
        ? hostWorkspacePathToGuest(hostCwd, guestCwd, file.path)
        : null;
      return path
        ? [{ path, content: redactHostEnvironment(file.content, hostCwd, guestCwd) }]
        : [];
    });
  // Saved files are virtual paths relative to the workspace.
  const savedAgentFiles =
    sandboxGuestCwd === undefined
      ? (resources?.agentsFiles ?? [])
      : inGuest(
          (resources?.agentsFiles ?? []).map((file) => ({
            path: resolve(hostCwd, file.path),
            content: file.content,
          })),
          sandboxGuestCwd,
        );
  const mounts = new Map<string, ReadonlyMount>();
  const hostSkillFiles = new Map<string, string>();
  const loader = new DefaultResourceLoader({
    cwd: hostCwd,
    agentDir,
    settingsManager: SettingsManager.create(hostCwd, agentDir, { projectTrusted }),
    noExtensions: true,
    noPromptTemplates: true,
    noThemes: true,
    systemPrompt: "",
    appendSystemPrompt: [],
    ...(selectedSkillPaths !== undefined
      ? { noSkills: true, additionalSkillPaths: selectedSkillPaths }
      : {}),
    ...(resources?.noContextFiles ? { noContextFiles: true } : {}),
    skillsOverride: (base) => {
      // Validate the saved Agent selection against host paths, before the sandbox rewrite.
      assertSelectedAgentSkillsLoaded(selectedSkillPaths, base);
      if (sandboxGuestCwd === undefined) {
        for (const skill of base.skills) hostSkillFiles.set(skill.name, skill.filePath);
        return base;
      }
      // A selected path inside the workspace can still reach outside through a symlink:
      // refuse the selection. Discovered Skills outside it are dropped, as AGENTS files are.
      const escaped = base.skills.filter(
        (skill) => !inWorkspace(skill.baseDir) || !inWorkspace(skill.filePath),
      );
      if (selectedSkillPaths !== undefined && escaped.length > 0)
        throw skillsOutsideWorkspace(escaped.map((skill) => skill.name));
      const skills = base.skills.filter((skill) => !escaped.includes(skill));
      for (const skill of skills) hostSkillFiles.set(skill.name, skill.filePath);
      return { ...base, skills: sandboxGuestSkills(skills, sandboxGuestCwd, mounts) };
    },
    agentsFilesOverride: (base) => ({
      agentsFiles: [
        ...(sandboxGuestCwd === undefined
          ? base.agentsFiles
          : inGuest(base.agentsFiles, sandboxGuestCwd)),
        ...savedAgentFiles,
      ],
    }),
  });
  await loader.reload();
  return {
    contextFiles: options.projectContext === false ? [] : loader.getAgentsFiles().agentsFiles,
    skills: loader.getSkills().skills,
    hostSkillFiles,
    readonlyMounts: [...mounts.values()],
  };
}

function skillsOutsideWorkspace(unavailableSkills: string[]): AgentConfigurationError {
  return new AgentConfigurationError(
    "agent_skills_unavailable",
    { unavailableSkills },
    `Selected Agent Skill is outside the sandbox workspace: ${unavailableSkills.join(", ")}`,
  );
}

/** The path with every symlink in its longest existing prefix followed. */
function realPath(path: string): string {
  const resolved = resolve(path);
  try {
    return realpathSync(resolved);
  } catch {
    const parent = dirname(resolved);
    return parent === resolved ? resolved : join(realPath(parent), basename(resolved));
  }
}

function isWithin(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

/** Pi's `project_context` section body. */
export function renderProjectContext(contextFiles: readonly ContextFile[]): string | undefined {
  if (contextFiles.length === 0) return undefined;
  return [
    "Project-specific instructions and guidelines:",
    ...contextFiles.map(
      ({ path, content }) =>
        `<project_instructions path="${path}">\n${content}\n</project_instructions>`,
    ),
  ].join("\n\n");
}

/** Pi's `skills` section body: Skills load through `read`, else `bash`, else not at all. */
export function renderSkills(
  skills: readonly Skill[],
  toolNames: readonly string[],
): string | undefined {
  const fileReadTool = (["read", "bash"] as const).find((tool) => toolNames.includes(tool));
  if (!fileReadTool) return undefined;
  return formatSkillsForPrompt([...skills], fileReadTool).trim() || undefined;
}

/**
 * Pi's `/skill:name args` expansion. Unknown Skills pass through unchanged, as in Pi;
 * an unreadable Skill file fails the prompt instead of sending the raw command.
 */
export function expandSkillCommand(text: string, resources: DurableProjectResources): string {
  if (!text.startsWith("/skill:")) return text;
  const space = text.indexOf(" ");
  const name = space === -1 ? text.slice(7) : text.slice(7, space);
  const args = space === -1 ? "" : text.slice(space + 1).trim();
  const skill = resources.skills.find((candidate) => candidate.name === name);
  const hostFile = resources.hostSkillFiles.get(name);
  if (!skill || !hostFile) return text;
  const body = stripFrontmatter(readFileSync(hostFile, "utf-8")).trim();
  const block = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body}\n</skill>`;
  return args ? `${block}\n\n${args}` : block;
}

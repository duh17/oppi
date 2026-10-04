import { readFileSync } from "node:fs";
import {
  DefaultResourceLoader,
  SettingsManager,
  formatSkillsForPrompt,
  stripFrontmatter,
  type Skill,
} from "@earendil-works/pi-coding-agent";
import type { AgentDefinition } from "./agent-launch-service.js";
import type { ReadonlyMount } from "./gondolin-manager.js";
import {
  assertSelectedAgentResourcesAvailable,
  assertSelectedAgentSkillsLoaded,
  assertSelectedAgentSkillsOutsideUntrustedProject,
  hostWorkspacePathToGuest,
  normalizeAgentContextFiles,
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
  agentDefinition?: AgentDefinition;
}): Promise<DurableProjectResources> {
  const { hostCwd, agentDir, sandboxGuestCwd, agentDefinition } = options;
  const selectedSkillPaths = normalizeSelectedAgentSkillPaths(
    agentDefinition?.resources?.skillPaths,
    hostCwd,
  );
  const projectTrusted = sandboxGuestCwd !== undefined || options.projectTrusted;
  if (!projectTrusted)
    assertSelectedAgentSkillsOutsideUntrustedProject(selectedSkillPaths, hostCwd);
  assertSelectedAgentResourcesAvailable(selectedSkillPaths, undefined);
  const savedAgentFiles = normalizeAgentContextFiles(agentDefinition, sandboxGuestCwd);
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
    ...(agentDefinition?.resources?.noContextFiles ? { noContextFiles: true } : {}),
    skillsOverride: (base) => {
      // Validate the saved Agent selection against host paths, before the sandbox rewrite.
      assertSelectedAgentSkillsLoaded(selectedSkillPaths, base);
      for (const skill of base.skills) hostSkillFiles.set(skill.name, skill.filePath);
      return sandboxGuestCwd === undefined
        ? base
        : { ...base, skills: sandboxGuestSkills(base.skills, sandboxGuestCwd, mounts) };
    },
    agentsFilesOverride: (base) => ({
      agentsFiles: [
        ...(sandboxGuestCwd === undefined
          ? base.agentsFiles
          : base.agentsFiles.flatMap((file) => {
              const path = hostWorkspacePathToGuest(hostCwd, sandboxGuestCwd, file.path);
              return path
                ? [{ path, content: redactHostEnvironment(file.content, hostCwd, sandboxGuestCwd) }]
                : [];
            })),
        ...savedAgentFiles,
      ],
    }),
  });
  await loader.reload();
  return {
    contextFiles: loader.getAgentsFiles().agentsFiles,
    skills: loader.getSkills().skills,
    hostSkillFiles,
    readonlyMounts: [...mounts.values()],
  };
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

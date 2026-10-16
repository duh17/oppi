import { realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, posix, relative, resolve, sep } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  DefaultResourceLoader,
  SettingsManager,
  createSyntheticSourceInfo,
  formatSkillsForPrompt,
  parseFrontmatter,
  stripFrontmatter,
  type Skill,
} from "@earendil-works/pi-coding-agent";
import type { FileInfo } from "@earendil-works/pi-durable/env";
import { AgentConfigurationError } from "./agent-launch-errors.js";
import type { DurableAgentResources } from "./durable-agent.js";
import type { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { SANDBOX_RESOURCE_MAX_BYTES } from "./gondolin-ops.js";
import { createLogger } from "./logger.js";
import {
  assertSelectedAgentResourcesAvailable,
  assertSelectedAgentSkillsLoaded,
  assertSelectedAgentSkillsOutsideUntrustedProject,
  hostWorkspacePathToGuest,
  normalizeSelectedAgentSkillPaths,
  redactHostEnvironment,
} from "./sdk-backend.js";

type ContextFile = { path: string; content: string };

const log = createLogger({ base: { component: "durable_project_resources" } });

/** Pi's `loadContextFileFromDir` names, in its order: the first readable one is used. */
const CONTEXT_FILE_NAMES = [
  "AGENTS.override.md",
  "AGENTS.md",
  "AGENTS.MD",
  "CLAUDE.md",
  "CLAUDE.MD",
];

/** The AGENTS files and Skills a durable session presents, as an SDK session loads them. */
export interface DurableProjectResources {
  /** As presented to the model: guest paths in a sandbox, with the text the VM returned. */
  readonly contextFiles: readonly ContextFile[];
  /**
   * As presented to the model: guest paths in a sandbox. `/skill:` reads `filePath` through
   * the session's own view (`expandSkillCommand`), never through a second host path.
   */
  readonly skills: readonly Skill[];
}

/**
 * Pi's resource discovery without classic extensions, prompt templates, or themes:
 * durable sessions cannot run classic extension factories.
 *
 * A host session uses Pi's `DefaultResourceLoader`. A sandbox session discovers and reads only
 * through its workspace VM (`sandbox`): the Skill directories that VM mounts, the workspace's
 * `.agents/skills`, and the context file at the guest root. Every byte comes through the VM's
 * provider stack (shadow, mount jail), bounded by `SANDBOX_RESOURCE_MAX_BYTES`; the host
 * filesystem is never walked, because the guest can rewrite the workspace under it.
 */
export async function loadDurableProjectResources(options: {
  hostCwd: string;
  agentDir: string;
  /** Sandbox sessions: the session's workspace VM; paths are guest paths. */
  sandbox?: GondolinExecutionEnv;
  /** Host sessions: the project trust decision. Sandbox sessions are always trusted. */
  projectTrusted: boolean;
  /** The saved Agent's selection, from the session's `oppi.agent` document. */
  resources?: DurableAgentResources;
  /** False when the Agent's instructions replace the prompt: no context files at all. */
  projectContext?: boolean;
}): Promise<DurableProjectResources> {
  if (options.sandbox) return loadSandboxProjectResources({ ...options, env: options.sandbox });
  const { hostCwd, agentDir, resources, projectTrusted } = options;
  const selectedSkillPaths = normalizeSelectedAgentSkillPaths(resources?.skillPaths, hostCwd);
  if (!projectTrusted)
    assertSelectedAgentSkillsOutsideUntrustedProject(selectedSkillPaths, hostCwd);
  assertSelectedAgentResourcesAvailable(selectedSkillPaths, undefined);
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
      assertSelectedAgentSkillsLoaded(selectedSkillPaths, base);
      return base;
    },
    // Saved files are virtual paths relative to the workspace.
    agentsFilesOverride: (base) => ({
      agentsFiles: [...base.agentsFiles, ...(resources?.agentsFiles ?? [])],
    }),
  });
  await loader.reload();
  return {
    contextFiles: options.projectContext === false ? [] : loader.getAgentsFiles().agentsFiles,
    skills: loader.getSkills().skills,
  };
}

async function loadSandboxProjectResources(options: {
  hostCwd: string;
  env: GondolinExecutionEnv;
  resources?: DurableAgentResources;
  projectContext?: boolean;
}): Promise<DurableProjectResources> {
  const { hostCwd, env, resources } = options;
  const guestCwd = env.workspaceRoot;
  const discovered = await discoverSandboxSkills(env);
  // A saved Agent's selection maps lexically into the guest and must name a Skill this VM
  // presents; anything else (outside the workspace, or not a mounted or `.agents/skills`
  // Skill) fails the launch rather than presenting a Skill the VM cannot read.
  const selection = normalizeSelectedAgentSkillPaths(resources?.skillPaths, hostCwd)?.map(
    (hostPath) => ({ hostPath, guestPath: hostWorkspacePathToGuest(hostCwd, guestCwd, hostPath) }),
  );
  const unavailable = (selection ?? []).filter(
    ({ guestPath }) => guestPath === null || !discovered.some((skill) => selects(guestPath, skill)),
  );
  if (unavailable.length > 0)
    throw new AgentConfigurationError(
      "agent_skills_unavailable",
      { unavailableSkills: unavailable.map(({ hostPath }) => hostPath) },
      `Selected Agent Skill is not available in the sandbox workspace: ${unavailable.map(({ hostPath }) => hostPath).join(", ")}`,
    );
  const skills =
    selection === undefined
      ? discovered
      : discovered.filter((skill) =>
          selection.some(({ guestPath }) => guestPath !== null && selects(guestPath, skill)),
        );
  if (options.projectContext === false) return { contextFiles: [], skills };
  // Saved files are virtual paths relative to the workspace: kept only inside it, at guest
  // paths, redacted. Their text is the definition's, not a file's.
  const workspaceRoot = realPath(hostCwd);
  const savedAgentFiles = (resources?.agentsFiles ?? []).flatMap((file) => {
    const hostPath = resolve(hostCwd, file.path);
    const path = isWithin(workspaceRoot, realPath(hostPath))
      ? hostWorkspacePathToGuest(hostCwd, guestCwd, hostPath)
      : null;
    return path ? [{ path, content: redactHostEnvironment(file.content, hostCwd, guestCwd) }] : [];
  });
  const discoveredFiles = resources?.noContextFiles ? [] : await readGuestContextFile(env, hostCwd);
  return { contextFiles: [...discoveredFiles, ...savedAgentFiles], skills };
}

/** `assertSelectedAgentSkillsLoaded`'s match: the path is the Skill, holds it, or is in it. */
function selects(selectedPath: string, skill: Skill): boolean {
  return (
    isWithinGuest(selectedPath, skill.filePath) ||
    isWithinGuest(selectedPath, skill.baseDir) ||
    isWithinGuest(skill.baseDir, selectedPath)
  );
}

/**
 * The Skills a sandbox VM presents, by Pi's rules (`collectSkillEntries`, `loadSkillFromFile`):
 * each `.pi/skills` entry the VM mounted, then the workspace's `.agents/skills`. The first
 * Skill with a name wins. `.pi/settings.json` Skill filters and ignore files are not applied.
 */
async function discoverSandboxSkills(env: GondolinExecutionEnv): Promise<Skill[]> {
  const files: string[] = [];
  const walked = new Set<string>();
  for (const mount of env.vm.skillMounts ?? [])
    await collectSkillFiles(env, mount.guestPath, "mount", false, walked, files);
  await collectSkillFiles(
    env,
    posix.join(env.workspaceRoot, ".agents", "skills"),
    "agents",
    true,
    walked,
    files,
  );
  const skills: Skill[] = [];
  for (const file of files) {
    const skill = await readSandboxSkill(env, file);
    if (skill && !skills.some((existing) => existing.name === skill.name)) skills.push(skill);
  }
  return skills;
}

/**
 * A directory with a `SKILL.md` is one Skill; otherwise recurse, skipping dot entries and
 * `node_modules`. Loose `.md` files count only below the root of `.agents/skills`, as in Pi
 * (a mounted entry is below `.pi/skills`, whose loose files are not mounted). The guest owns
 * `.agents/skills`, so a directory already walked (by device and inode, from the provider)
 * is not walked again: a `a -> .` link cannot make the walk unbounded.
 */
async function collectSkillFiles(
  env: GondolinExecutionEnv,
  dir: string,
  mode: "mount" | "agents",
  atRoot: boolean,
  walked: Set<string>,
  files: string[],
): Promise<void> {
  const identity = await env.vm.fs.stat?.(dir).catch(() => undefined);
  if (!identity?.isDirectory()) return;
  const key = identity.ino === undefined ? dir : `${identity.dev}:${identity.ino}`;
  if (walked.has(key)) return;
  walked.add(key);
  const entries = await listGuestDir(env, dir);
  const skillFile = entries.find((entry) => entry.name === "SKILL.md" && entry.kind === "file");
  if (skillFile) {
    files.push(skillFile.path);
    return;
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    if (entry.kind === "directory")
      await collectSkillFiles(env, entry.path, mode, false, walked, files);
    else if (entry.kind === "file" && entry.name.endsWith(".md") && mode === "agents" && !atRoot)
      files.push(entry.path);
  }
}

/**
 * A guest directory's entries with their followed kinds. An entry the VM refuses (a symlink
 * out of its mount, a link to a shadowed file) is left out, whatever error the VM gives,
 * so one planted link cannot hide its siblings; an unreadable directory lists nothing.
 */
async function listGuestDir(env: GondolinExecutionEnv, dir: string): Promise<FileInfo[]> {
  const names = await env.vm.fs.listDir?.(dir).catch(() => undefined);
  const entries: FileInfo[] = [];
  for (const name of names ?? []) {
    const info = await env.fileInfo(posix.join(dir, name), BACKGROUND_CONTEXT);
    if (info.ok) entries.push(info.value);
  }
  return entries;
}

/** Pi's `loadSkillFromFile` over the VM's text: no description, no Skill. */
async function readSandboxSkill(
  env: GondolinExecutionEnv,
  filePath: string,
): Promise<Skill | undefined> {
  const text = await readGuestResource(env, filePath);
  if (text === undefined) return undefined;
  let frontmatter: Record<string, unknown>;
  try {
    ({ frontmatter } = parseFrontmatter(text));
  } catch (error) {
    log.warn("durable_resources.skill_unparsable", { path: filePath, error: String(error) });
    return undefined;
  }
  const { description } = frontmatter;
  if (typeof description !== "string" || description.trim() === "") return undefined;
  const baseDir = posix.dirname(filePath);
  return {
    name: (typeof frontmatter.name === "string" && frontmatter.name) || posix.basename(baseDir),
    description,
    filePath,
    baseDir,
    sourceInfo: createSyntheticSourceInfo(filePath, {
      source: "local",
      scope: "project",
      baseDir,
    }),
    disableModelInvocation: frontmatter["disable-model-invocation"] === true,
  };
}

/** The guest root's context file, as the VM reads it, redacted like the host loader's text. */
async function readGuestContextFile(
  env: GondolinExecutionEnv,
  hostCwd: string,
): Promise<ContextFile[]> {
  for (const name of CONTEXT_FILE_NAMES) {
    const path = posix.join(env.workspaceRoot, name);
    const text = await readGuestResource(env, path);
    if (text !== undefined)
      return [{ path, content: redactHostEnvironment(text, hostCwd, env.workspaceRoot) }];
  }
  return [];
}

/**
 * A resource file's text through the VM, or undefined when the VM refuses it (missing,
 * shadowed, a symlink out of its mount, not a regular file) or it is over the byte cap.
 */
async function readGuestResource(
  env: GondolinExecutionEnv,
  path: string,
): Promise<string | undefined> {
  const read = await env.readTextFileWithin(path, SANDBOX_RESOURCE_MAX_BYTES, BACKGROUND_CONTEXT);
  if (!read.ok) return undefined;
  if ("tooLarge" in read.value) {
    log.warn("durable_resources.file_too_large", {
      path,
      maxBytes: SANDBOX_RESOURCE_MAX_BYTES,
    });
    return undefined;
  }
  return read.value.text;
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

function isWithinGuest(root: string, path: string): boolean {
  const rel = posix.relative(root, path);
  return rel === "" || (rel !== ".." && !rel.startsWith("../") && !posix.isAbsolute(rel));
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
 *
 * `readFile` reads the presented `filePath` through the session's own view: the host for a
 * host session, the VM for a sandbox. A sandbox Skill is never read from the host, because
 * the guest can rewrite workspace files (a `SKILL.md` swapped for a symlink to a host
 * secret); through the VM, the mount's real-path jail refuses that read.
 */
export async function expandSkillCommand(
  text: string,
  resources: DurableProjectResources,
  readFile: (path: string) => Promise<string>,
): Promise<string> {
  if (!text.startsWith("/skill:")) return text;
  const space = text.indexOf(" ");
  const name = space === -1 ? text.slice(7) : text.slice(7, space);
  const args = space === -1 ? "" : text.slice(space + 1).trim();
  const skill = resources.skills.find((candidate) => candidate.name === name);
  if (!skill) return text;
  const body = stripFrontmatter(await readFile(skill.filePath)).trim();
  const block = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body}\n</skill>`;
  return args ? `${block}\n\n${args}` : block;
}

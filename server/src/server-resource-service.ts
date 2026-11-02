import { lstatSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  DefaultPackageManager,
  DefaultResourceLoader,
  SettingsManager,
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  loadSkills,
  type Extension,
  type PackageSource,
  type ResolvedResource,
  type ResourceDiagnostic,
  type Skill,
} from "@earendil-works/pi-coding-agent";

import {
  availableMcpBuiltinNames,
  BUILTIN_EXTENSION_PATH_PREFIX,
  createMcpBuiltinExtensions,
} from "./host-mcp-extensions.js";
import {
  canonicalServerResourcePath as canonicalPath,
  serverResourceId as resourceId,
} from "./server-resource-id.js";
import type { PluginListing } from "./plugin-host.js";
import {
  PiGlobalConfigError,
  readPiDefaultTools,
  readPiSystemPrompt,
  writePiDefaultTools,
  type PiDefaultToolsSnapshot,
  type PiSystemPromptSnapshot,
} from "./pi-global-config.js";
import {
  listSkillFiles,
  readSkillFile as readContainedSkillFile,
  readSkillFileSnapshot as readContainedSkillFileSnapshot,
} from "./skill-files.js";

const MAX_MESSAGE_LENGTH = 2048;
const MAX_WARNINGS = 8;
/** Pi built-in extensions a managed host session loads; `-builtin:<name>` still disables one. */
const HOST_BUILTIN_EXTENSION_NAMES = availableMcpBuiltinNames({ managed: true, sandbox: false });

export type ResourceProvenanceKind =
  "builtIn" | "piAgent" | "agents" | "userSettings" | "package" | "unknown";

export interface ResourceProvenance {
  kind: ResourceProvenanceKind;
  label: string;
}

export interface ServerSkillSummary {
  id: string;
  name: string;
  description: string;
  provenance: ResourceProvenance;
  path?: string;
  packageName?: string;
  state: "enabled" | "disabled" | "error";
  loadError?: string;
  warnings: string[];
  /** Server-authoritative capability; clients must not infer this from paths. */
  editable: boolean;
}

export interface ServerSkillDetail {
  summary: ServerSkillSummary;
  skillMarkdown: string;
  files: string[];
}

export interface ServerToolSummary {
  name: string;
  description?: string;
  defaultEnabled?: boolean;
}

/**
 * One row of the extension list: a classic Pi extension, a plugin (durable sessions), or a Pi
 * package's classic extension and its plugin together under the classic ID.
 */
export interface ServerExtensionSummary {
  id: string;
  name: string;
  description?: string;
  kind: "builtIn" | "file" | "directory" | "package";
  provenance: ResourceProvenance;
  path?: string;
  packageName?: string;
  /** `error` when the classic extension or the plugin failed to load (`loadError`). */
  state: "on" | "off" | "error";
  loadError?: string;
  warnings: string[];
  isRemovable: false;
  /** What the row is: a plugin, a classic Pi extension, or both. */
  kinds: ServerExtensionRowKind[];
  /** The layer it loads from: shipped with the server, the owner's, or a project's. */
  source: "built-in" | "owner" | "project";
  /** Its plugin, when it is one: from the plugin host's table and its loaded extension. */
  plugin?: ServerPluginSummary;
  /** A classic extension's tools; a plugin's are in `plugin.tools`. */
  contributedTools?: string[];
  contributedToolDetails?: ServerToolSummary[];
  contributedCommands?: string[];
}

export type ServerExtensionRowKind = "plugin" | "pi-extension";

export interface ServerPluginSummary {
  /** Its installed extension's name; absent when it never loaded. */
  extension?: string;
  /** A built-in the server cannot run without: it cannot be disabled. */
  required: boolean;
  /** Whether workspace sessions select it; false when it has no code installed. */
  enabled: boolean;
  runtimes: string[];
  tools: string[];
  hooks: { task: string; handlers: string[] }[];
  sections: string[];
  wraps: ({ tool: string } | { section: string })[];
  tasks: string[];
  /** Why its last load or reload failed. */
  loadError?: string;
  /** A failed reload left its previous code running. */
  kept: boolean;
}

/** The plugin host's side of the extension list (`SessionManager`). */
export interface ServerPluginCatalog {
  listPlugins(): Promise<readonly PluginListing[]>;
  /** Turn the installed extension `name` on or off for workspace sessions. */
  setPluginEnabled(name: string, enabled: boolean): void;
}

export interface ServerExtensionDetail {
  summary: ServerExtensionSummary;
  contributedTools?: string[];
  contributedToolDetails?: ServerToolSummary[];
  contributedCommands?: string[];
}

export interface ServerResourceServiceOptions {
  dataDir: string;
  agentDir: string;
  /** Without it the list has the classic extensions only. */
  plugins?: ServerPluginCatalog;
}

interface ResolutionContext {
  cwd: string;
  agentDir: string;
  settingsManager: SettingsManager;
  skills: ResolvedResource[];
  extensions: ResolvedResource[];
  /** `builtin:<name>` paths Pi's `extensions` setting leaves enabled. */
  enabledBuiltinExtensionPaths: string[];
  configuredPackages: Array<{ source: string; canonicalRoot: string }>;
}

interface SkillCatalogEntry {
  resource: ResolvedResource;
  canonicalPath: string;
  summary: ServerSkillSummary;
  skill?: Skill;
  baseDir: string;
  markdownFileName: string;
}

interface ExtensionCatalogEntry {
  resource?: ResolvedResource;
  canonicalPath?: string;
  summary: ServerExtensionSummary;
}

/** Which row each plugin is on: a classic row of its Pi package, or its own. */
interface PluginRows {
  /** By classic extension ID. */
  attached: Map<string, PluginListing>;
  /** By the plugin's own row ID. */
  own: Map<string, PluginListing>;
}

interface ExtensionCatalog {
  entries: ExtensionCatalogEntry[];
  /** Tools loaded extensions register with `defaultActive: false`; `defaultTools` can turn them on. */
  optionalTools: ServerToolSummary[];
}

export class ServerResourceServiceError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(boundMessage(message), options);
    this.name = "ServerResourceServiceError";
  }
}

export class ServerResourceNotFoundError extends ServerResourceServiceError {
  constructor(resource: "skill" | "extension" | "skill file") {
    super(`${resource[0]?.toUpperCase()}${resource.slice(1)} not found`);
    this.name = "ServerResourceNotFoundError";
  }
}

/** A package or other non-top-level Skill: readable, never written by Oppi. */
export class ServerResourceReadOnlyError extends ServerResourceServiceError {
  constructor() {
    super("Skill is read-only");
    this.name = "ServerResourceReadOnlyError";
  }
}

export class ServerResourceValidationError extends ServerResourceServiceError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "ServerResourceValidationError";
  }
}

/** A change the resource's current state refuses, such as disabling a required built-in. */
export class ServerResourceConflictError extends ServerResourceServiceError {
  constructor(message: string) {
    super(message);
    this.name = "ServerResourceConflictError";
  }
}

export class ServerResourceService {
  private readonly dataDir: string;
  private readonly agentDir: string;
  private readonly catalogCwd: string;
  private readonly plugins?: ServerPluginCatalog;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(options: ServerResourceServiceOptions) {
    this.dataDir = resolve(options.dataDir);
    this.agentDir = resolve(options.agentDir);
    this.catalogCwd = join(this.dataDir, "resource-catalog-cwd");
    this.plugins = options.plugins;
  }

  async listSkills(): Promise<{ skills: ServerSkillSummary[] }> {
    const entries = await this.buildSkillCatalog(await this.resolveContext());
    return { skills: entries.map((entry) => copySkillSummary(entry.summary)) };
  }

  /**
   * The extension list. A row that is only a plugin is listed only with `plugins`: a client that
   * predates plugins (an Agent picker) would offer it for an Agent's classic selection, which
   * cannot select it. Detail and enable by ID reach it either way.
   */
  async listExtensions({ plugins: withPluginRows = false } = {}): Promise<{
    extensions: ServerExtensionSummary[];
    builtInTools: ServerToolSummary[];
    optionalTools: ServerToolSummary[];
  }> {
    const context = await this.resolveContext();
    const { entries, optionalTools } = await this.buildExtensionCatalog(context);
    const plugins = await this.pluginRows(context);
    const rows = [
      ...entries.map((entry) => withPlugin(entry.summary, plugins.attached.get(entry.summary.id))),
      ...(withPluginRows
        ? [...plugins.own].map(([id, plugin]) => pluginRow(id, plugin, this.agentDir))
        : []),
    ].sort(compareSummaries);
    return {
      extensions: rows.map(copyExtensionSummary),
      builtInTools: builtInToolSummaries(this.catalogCwd),
      optionalTools: optionalTools.map(copyToolSummary),
    };
  }

  async getSkillDetail(id: string): Promise<ServerSkillDetail> {
    const entry = (await this.buildSkillCatalog(await this.resolveContext())).find(
      (candidate) => candidate.summary.id === id,
    );
    if (!entry) throw new ServerResourceNotFoundError("skill");

    let skillMarkdown: string;
    try {
      skillMarkdown = readContainedSkillFile(entry.baseDir, entry.markdownFileName);
    } catch {
      throw new ServerResourceNotFoundError("skill file");
    }
    return {
      summary: copySkillSummary(entry.summary),
      skillMarkdown,
      files: listSkillFiles(entry.baseDir),
    };
  }

  async readSkillFile(id: string, path: string): Promise<string> {
    return (await this.readSkillFileSnapshot(id, path)).content;
  }

  async readSkillFileSnapshot(
    id: string,
    path: string,
  ): Promise<{ content: string; revision: string }> {
    const entry = (await this.buildSkillCatalog(await this.resolveContext())).find(
      (candidate) => candidate.summary.id === id,
    );
    if (!entry) throw new ServerResourceNotFoundError("skill");
    try {
      return readContainedSkillFileSnapshot(entry.baseDir, path);
    } catch {
      throw new ServerResourceNotFoundError("skill file");
    }
  }

  /**
   * The directory `/files/current?origin=skill` resolves `path` under: an
   * editable Skill's own directory. A Markdown Skill without its own directory
   * is that one file, so its neighbors are never reachable here. The editor
   * contract (`inspectFileForEdit`) still checks containment, type, size, and
   * symlinks on every read and write.
   */
  async skillEditRoot(id: string, path: string): Promise<string> {
    const entry = (await this.buildSkillCatalog(await this.resolveContext())).find(
      (candidate) => candidate.summary.id === id,
    );
    if (!entry) throw new ServerResourceNotFoundError("skill");
    if (!entry.summary.editable) throw new ServerResourceReadOnlyError();
    if (entry.markdownFileName !== "SKILL.md" && path !== entry.markdownFileName) {
      throw new ServerResourceNotFoundError("skill file");
    }
    return entry.baseDir;
  }

  async getExtensionDetail(id: string): Promise<ServerExtensionDetail> {
    return this.extensionDetail(id, false);
  }

  /** Inspect tools only after a user explicitly selects an Extension for an Agent. */
  async inspectAgentExtensionTools(id: string): Promise<ServerExtensionDetail> {
    return this.extensionDetail(id, true);
  }

  private async extensionDetail(id: string, inspectTools: boolean): Promise<ServerExtensionDetail> {
    const context = await this.resolveContext();
    const plugins = await this.pluginRows(context);
    const own = plugins.own.get(id);
    if (own) return { summary: pluginRow(id, own, this.agentDir) };
    this.findResourceById("extension", context.extensions, id);
    const inspectToolIds = inspectTools ? new Set([id]) : new Set<string>();
    const entry = (await this.buildExtensionCatalog(context, inspectToolIds)).entries.find(
      (candidate) => candidate.summary.id === id,
    );
    if (!entry) throw new ServerResourceNotFoundError("extension");
    const summary = copyExtensionSummary(withPlugin(entry.summary, plugins.attached.get(id)));
    return {
      summary,
      contributedTools: summary.contributedTools ? [...summary.contributedTools] : undefined,
      contributedToolDetails: summary.contributedToolDetails
        ? summary.contributedToolDetails.map(copyToolSummary)
        : undefined,
      contributedCommands: summary.contributedCommands
        ? [...summary.contributedCommands]
        : undefined,
    };
  }

  async setSkillEnabled(id: string, enabled: boolean): Promise<ServerSkillSummary> {
    return this.withMutationLock(async () => {
      const context = await this.resolveContext();
      const resource = this.findResourceById("skill", context.skills, id);
      this.writeResourceEnabled(context, resource, "skills", enabled);
      await this.finishSettingsWrite(context.settingsManager);
      const authoritative = await this.buildSkillCatalog(await this.resolveContext());
      const current = authoritative.find((entry) => entry.summary.id === id);
      if (!current) throw new ServerResourceNotFoundError("skill");
      return copySkillSummary(current.summary);
    });
  }

  async getPiSystemPrompt(): Promise<PiSystemPromptSnapshot> {
    try {
      return readPiSystemPrompt(this.agentDir);
    } catch (cause: unknown) {
      throw mapPiGlobalConfigError(cause);
    }
  }

  async getPiDefaultTools(): Promise<PiDefaultToolsSnapshot> {
    try {
      return readPiDefaultTools(this.agentDir);
    } catch (cause: unknown) {
      throw mapPiGlobalConfigError(cause);
    }
  }

  async setPiDefaultTools(defaultTools: string[] | null): Promise<PiDefaultToolsSnapshot> {
    return this.withMutationLock(async () => {
      const optionalToolNames =
        defaultTools === null
          ? []
          : (await this.buildExtensionCatalog(await this.resolveContext())).optionalTools.map(
              (tool) => tool.name,
            );
      try {
        return writePiDefaultTools(this.agentDir, defaultTools, optionalToolNames);
      } catch (cause: unknown) {
        throw mapPiGlobalConfigError(cause);
      }
    });
  }

  async setPiDefaultModel(provider: string, modelId: string): Promise<{ model: string }> {
    return this.withMutationLock(async () => {
      const settings = SettingsManager.create(this.catalogCwd, this.agentDir, {
        projectTrusted: false,
      });
      this.throwSettingsErrors(settings.drainErrors(), "load");
      settings.setDefaultModelAndProvider(provider, modelId);
      await this.finishSettingsWrite(settings);
      return { model: `${provider}/${modelId}` };
    });
  }

  /**
   * A classic row (a plugin of its package included) is turned on or off in Pi's settings, which
   * a durable session follows after a plugin reload. A plugin's own row is turned on or off in the
   * server config, which sessions follow without a reload.
   */
  async setExtensionEnabled(id: string, enabled: boolean): Promise<ServerExtensionSummary> {
    return this.withMutationLock(async () => {
      const context = await this.resolveContext();
      const plugin = (await this.pluginRows(context)).own.get(id);
      if (plugin) return this.setPluginEnabled(id, plugin, enabled);
      const resource = this.findResourceById("extension", context.extensions, id);
      this.writeResourceEnabled(context, resource, "extensions", enabled);
      await this.finishSettingsWrite(context.settingsManager);
      const latest = await this.resolveContext();
      const authoritative = await this.buildExtensionCatalog(latest);
      const current = authoritative.entries.find((entry) => entry.summary.id === id);
      if (!current) throw new ServerResourceNotFoundError("extension");
      const attached = (await this.pluginRows(latest)).attached.get(id);
      return copyExtensionSummary(withPlugin(current.summary, attached));
    });
  }

  private async setPluginEnabled(
    id: string,
    plugin: PluginListing,
    enabled: boolean,
  ): Promise<ServerExtensionSummary> {
    if (!this.plugins) throw new ServerResourceNotFoundError("extension");
    if (plugin.extension === undefined)
      throw new ServerResourceConflictError(
        `${plugin.name} has no code loaded to turn on or off: ${plugin.loadError ?? "not loaded"}`,
      );
    if (plugin.required && !enabled)
      throw new ServerResourceConflictError(
        `${plugin.name} is required by the server and cannot be disabled`,
      );
    this.plugins.setPluginEnabled(plugin.extension, enabled);
    const current = (await this.plugins.listPlugins()).find((p) => p.name === plugin.name);
    if (!current) throw new ServerResourceNotFoundError("extension");
    return pluginRow(id, current, this.agentDir);
  }

  /**
   * Whether the Pi package behind classic extension `id` holds a plugin, so toggling it changes
   * what durable sessions load. A classic-only extension does not, and a plugin's own row is no
   * Pi package.
   */
  async hasPlugin(id: string): Promise<boolean> {
    const context = await this.resolveContext();
    const resource = this.matchResourceById("extension", context.extensions, id);
    if (!resource) return false;
    const { packageHasPlugin } = await import("./plugin-discovery.js");
    return packageHasPlugin(resource.path, resource.metadata);
  }

  /**
   * Each plugin's row: the classic row of the first of its package's classic extensions that
   * has no plugin yet, else a row of its own, identified by its facet (or folder).
   */
  private async pluginRows(context: ResolutionContext): Promise<PluginRows> {
    const rows: PluginRows = { attached: new Map(), own: new Map() };
    if (!this.plugins) return rows;
    const classicIds = new Set(
      context.extensions.map((resource) => resourceId("extension", canonicalPath(resource.path))),
    );
    for (const plugin of await this.plugins.listPlugins()) {
      const id = plugin.extensionIds.find(
        (candidate) => classicIds.has(candidate) && !rows.attached.has(candidate),
      );
      if (id !== undefined) rows.attached.set(id, plugin);
      else rows.own.set(resourceId("extension", plugin.facet ?? plugin.dir), plugin);
    }
    return rows;
  }

  private async resolveContext(): Promise<ResolutionContext> {
    mkdirSync(this.catalogCwd, { recursive: true, mode: 0o700 });
    const settingsManager = SettingsManager.create(this.catalogCwd, this.agentDir, {
      projectTrusted: false,
    });
    this.throwSettingsErrors(settingsManager.drainErrors(), "load");
    const packageManager = new DefaultPackageManager({
      cwd: this.catalogCwd,
      agentDir: this.agentDir,
      settingsManager,
      builtinExtensions: [...HOST_BUILTIN_EXTENSION_NAMES],
    });
    let resolvedPaths;
    try {
      resolvedPaths = await packageManager.resolve(async () => "skip");
    } catch (error: unknown) {
      throw new ServerResourceServiceError(
        `Failed to resolve Pi resources: ${messageFrom(error)}`,
        { cause: error },
      );
    }
    this.throwSettingsErrors(settingsManager.drainErrors(), "resolve");
    const isBuiltin = (resource: ResolvedResource): boolean =>
      resource.path.startsWith(BUILTIN_EXTENSION_PATH_PREFIX);
    return {
      cwd: this.catalogCwd,
      agentDir: this.agentDir,
      settingsManager,
      skills: resolvedPaths.skills.filter((resource) => resource.metadata.scope === "user"),
      extensions: resolvedPaths.extensions.filter(
        (resource) => resource.metadata.scope === "user" && !isBuiltin(resource),
      ),
      enabledBuiltinExtensionPaths: resolvedPaths.extensions
        .filter((resource) => isBuiltin(resource) && resource.enabled)
        .map((resource) => resource.path),
      configuredPackages: packageManager.listConfiguredPackages().flatMap((configured) =>
        configured.scope === "user" && configured.installedPath
          ? [
              {
                source: configured.source,
                canonicalRoot: canonicalPath(configured.installedPath),
              },
            ]
          : [],
      ),
    };
  }

  private async buildSkillCatalog(context: ResolutionContext): Promise<SkillCatalogEntry[]> {
    const resourcesByCanonicalPath = new Map<
      string,
      { resource: ResolvedResource; canonicalPath: string }
    >();
    for (const resource of context.skills) {
      const path = canonicalPath(resource.path);
      const current = resourcesByCanonicalPath.get(path);
      // A package-backed candidate is authoritative for duplicate aliases so a
      // symlink added under a top-level Skill directory cannot grant writes.
      if (
        !current ||
        (current.resource.metadata.origin !== "package" && resource.metadata.origin === "package")
      ) {
        resourcesByCanonicalPath.set(path, { resource, canonicalPath: path });
      }
    }
    const resources = [...resourcesByCanonicalPath.values()];
    const loaded = loadSkills({
      cwd: context.cwd,
      agentDir: context.agentDir,
      skillPaths: resources.map((entry) => entry.resource.path),
      includeDefaults: false,
    });
    const skills = loaded.skills.map((skill) => ({
      ...skill,
      sourceInfo: { ...skill.sourceInfo },
    }));
    const diagnostics = loaded.diagnostics.map(copyDiagnostic);

    const entries = resources.map(({ resource, canonicalPath: path }) => {
      const skill = skills.find((candidate) => resourceContainsPath(resource, candidate.filePath));
      const resourceDiagnostics = diagnostics.filter((diagnostic) =>
        diagnosticMatchesResource(diagnostic, resource),
      );
      const warnings = boundedWarnings(resourceDiagnostics.map((diagnostic) => diagnostic.message));
      const missingSkillError = !skill ? (warnings[0] ?? "Skill could not be loaded") : undefined;
      const loadError = missingSkillError ? boundMessage(missingSkillError) : undefined;
      const fallbackName = skillNameFromPath(resource.path);
      const { baseDir, markdownFileName } = skillFileLocation(resource.path, skill);
      const configuredPackage = context.configuredPackages.find((candidate) =>
        pathContains(candidate.canonicalRoot, path),
      );
      const isPackageBacked =
        resource.metadata.origin === "package" || configuredPackage !== undefined;
      const provenance = configuredPackage
        ? { kind: "package" as const, label: boundMessage(configuredPackage.source) }
        : resourceProvenance(resource, context.agentDir);
      const packageName = configuredPackageName(
        configuredPackage?.source ?? resource.metadata.source,
      );
      const summary: ServerSkillSummary = {
        id: resourceId("skill", path),
        name: boundMessage(skill?.name ?? fallbackName),
        description: boundMessage(skill?.description ?? ""),
        provenance,
        path,
        ...(packageName ? { packageName } : {}),
        state: loadError ? "error" : resource.enabled ? "enabled" : "disabled",
        ...(loadError ? { loadError } : {}),
        warnings,
        editable: resource.metadata.origin === "top-level" && !isPackageBacked,
      };
      return { resource, canonicalPath: path, summary, skill, baseDir, markdownFileName };
    });

    return entries.sort((a, b) => compareSummaries(a.summary, b.summary));
  }

  private async buildExtensionCatalog(
    context: ResolutionContext,
    inspectToolIds: ReadonlySet<string> = new Set(),
  ): Promise<ExtensionCatalog> {
    const resourcesByCanonicalPath = new Map<
      string,
      { resource: ResolvedResource; canonicalPath: string }
    >();
    for (const resource of context.extensions) {
      const path = canonicalPath(resource.path);
      const current = resourcesByCanonicalPath.get(path);
      if (
        !current ||
        (current.resource.metadata.origin !== "package" && resource.metadata.origin === "package")
      ) {
        resourcesByCanonicalPath.set(path, { resource, canonicalPath: path });
      }
    }
    const resources = [...resourcesByCanonicalPath.values()];
    const enabledPaths = resources
      .filter(
        (entry) =>
          entry.resource.enabled ||
          inspectToolIds.has(resourceId("extension", entry.canonicalPath)),
      )
      .map((entry) => entry.resource.path);
    const loader = new DefaultResourceLoader({
      cwd: context.cwd,
      agentDir: context.agentDir,
      settingsManager: SettingsManager.inMemory({}, { projectTrusted: false }),
      // Built-ins load only to discover the tools they register off (codemode, tool_search).
      extensionFactories: createMcpBuiltinExtensions(HOST_BUILTIN_EXTENSION_NAMES),
      additionalExtensionPaths: [...enabledPaths, ...context.enabledBuiltinExtensionPaths],
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
    });
    try {
      await loader.reload();
    } catch (error: unknown) {
      throw new ServerResourceServiceError(
        `Failed to load enabled Pi extensions: ${messageFrom(error)}`,
        { cause: error },
      );
    }
    const live = loader.getExtensions();
    const extensions = live.extensions.map(copyLoadedExtension);
    const errors = live.errors.map((error) => ({
      path: error.path,
      error: boundMessage(error.error),
    }));

    const normal = resources.map(({ resource, canonicalPath: path }) => {
      const extension = extensions.find(
        (candidate) =>
          pathsMatch(candidate.resolvedPath, resource.path) ||
          pathsMatch(candidate.path, resource.path),
      );
      const extensionErrors = errors.filter(
        (error) =>
          resourceContainsPath(resource, error.path) || pathsMatch(error.path, resource.path),
      );
      const warnings = boundedWarnings(extensionErrors.slice(1).map((error) => error.error));
      const extensionId = resourceId("extension", path);
      const wasLoadedForCatalog = resource.enabled || inspectToolIds.has(extensionId);
      const loadError = wasLoadedForCatalog
        ? (extensionErrors[0]?.error ?? (!extension ? "Extension could not be loaded" : undefined))
        : undefined;
      const contributedToolDetails = extension
        ? [...extension.tools.entries()]
            .map(([name, tool]) => ({
              name,
              ...(tool.definition.description
                ? { description: boundMessage(tool.definition.description) }
                : {}),
            }))
            .sort((left, right) => left.name.localeCompare(right.name, "en-US"))
        : undefined;
      const contributedTools = contributedToolDetails?.map((tool) => tool.name);
      const contributedCommands = extension ? [...extension.commands.keys()].sort() : undefined;
      const packageName = configuredPackageName(resource.metadata.source);
      const summary: ServerExtensionSummary = {
        id: extensionId,
        name: boundMessage(extensionNameFromPath(resource.path)),
        kind: extensionKind(resource),
        provenance: resourceProvenance(resource, context.agentDir),
        path,
        ...(packageName ? { packageName } : {}),
        state: loadError ? "error" : resource.enabled ? "on" : "off",
        ...(loadError ? { loadError: boundMessage(loadError) } : {}),
        warnings,
        isRemovable: false,
        kinds: ["pi-extension"],
        source: "owner",
        ...(contributedTools ? { contributedTools } : {}),
        ...(contributedToolDetails ? { contributedToolDetails } : {}),
        ...(contributedCommands ? { contributedCommands } : {}),
      };
      return { resource, canonicalPath: path, summary };
    });
    normal.sort((a, b) => compareSummaries(a.summary, b.summary));
    return { entries: normal, optionalTools: optionalToolSummaries(extensions) };
  }

  private findResourceById(
    kind: "skill" | "extension",
    resources: ResolvedResource[],
    id: string,
  ): ResolvedResource {
    const resource = this.matchResourceById(kind, resources, id);
    if (!resource) throw new ServerResourceNotFoundError(kind);
    return resource;
  }

  private matchResourceById(
    kind: "skill" | "extension",
    resources: ResolvedResource[],
    id: string,
  ): ResolvedResource | undefined {
    const matches = resources.filter(
      (candidate) => resourceId(kind, canonicalPath(candidate.path)) === id,
    );
    const resource =
      matches.find((candidate) => candidate.metadata.origin === "package") ?? matches[0];
    return resource?.metadata.scope === "user" ? resource : undefined;
  }

  private writeResourceEnabled(
    context: ResolutionContext,
    resource: ResolvedResource,
    type: "skills" | "extensions",
    enabled: boolean,
  ): void {
    if (resource.metadata.origin === "package") {
      this.writePackageResourceEnabled(context, resource, type, enabled);
      return;
    }

    const settings = context.settingsManager.getGlobalSettings();
    const baseDir = resource.metadata.baseDir ?? context.agentDir;
    const pattern = toPosixPath(relative(baseDir, resource.path));
    const current = [...(settings[type] ?? [])];
    const updated = current.filter(
      (entry) => !settingsEntryMatchesResource(type, entry, resource, baseDir),
    );
    if (resource.metadata.source === "local") updated.push(pattern);
    updated.push(`${enabled ? "+" : "-"}${pattern}`);
    if (type === "skills") context.settingsManager.setSkillPaths(updated);
    else context.settingsManager.setExtensionPaths(updated);
  }

  private writePackageResourceEnabled(
    context: ResolutionContext,
    resource: ResolvedResource,
    type: "skills" | "extensions",
    enabled: boolean,
  ): void {
    const settings = context.settingsManager.getGlobalSettings();
    const packages: PackageSource[] = [...(settings.packages ?? [])];
    const packageIndex = packages.findIndex(
      (entry) => (typeof entry === "string" ? entry : entry.source) === resource.metadata.source,
    );
    if (packageIndex < 0) {
      throw new ServerResourceServiceError("Package source not found in Pi user settings");
    }
    const currentPackage = packages[packageIndex];
    const packageRecord =
      typeof currentPackage === "string" ? { source: currentPackage } : { ...currentPackage };
    const baseDir = resource.metadata.baseDir ?? dirname(resource.path);
    const pattern = toPosixPath(relative(baseDir, resource.path));
    const currentFilters = [...(packageRecord[type] ?? [])];
    packageRecord[type] = currentFilters
      .filter((entry) => stripPatternPrefix(entry) !== pattern)
      .concat(`${enabled ? "+" : "-"}${pattern}`);
    packages[packageIndex] = packageRecord;
    context.settingsManager.setPackages(packages);
  }

  private async finishSettingsWrite(settingsManager: SettingsManager): Promise<void> {
    await settingsManager.flush();
    this.throwSettingsErrors(settingsManager.drainErrors(), "write");
  }

  private throwSettingsErrors(
    errors: Array<{ scope: string; error: Error }>,
    operation: string,
  ): void {
    if (errors.length === 0) return;
    const message = errors
      .slice(0, MAX_WARNINGS)
      .map((entry) => `${entry.scope}: ${messageFrom(entry.error)}`)
      .join("; ");
    throw new ServerResourceServiceError(`Pi settings ${operation} failed: ${message}`);
  }

  private async withMutationLock<T>(operation: () => Promise<T>): Promise<T> {
    let release: (() => void) | undefined;
    const previous = this.mutationTail;
    this.mutationTail = new Promise<void>((resolvePromise) => {
      release = resolvePromise;
    });
    await previous;
    try {
      return await operation();
    } finally {
      release?.();
    }
  }
}

function messageFrom(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function boundMessage(value: string): string {
  const sanitized = Array.from(value, (character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f) ? " " : character;
  })
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return (sanitized || "Unknown error").slice(0, MAX_MESSAGE_LENGTH);
}

function boundedWarnings(values: string[]): string[] {
  return values.slice(0, MAX_WARNINGS).map(boundMessage);
}

function pathsMatch(left: string, right: string): boolean {
  return canonicalPath(left) === canonicalPath(right);
}

function pathContains(parent: string, child: string): boolean {
  const canonicalParent = canonicalPath(parent);
  const canonicalChild = canonicalPath(child);
  return (
    canonicalChild === canonicalParent || canonicalChild.startsWith(`${canonicalParent}${sep}`)
  );
}

function resourceContainsPath(resource: ResolvedResource, path: string): boolean {
  if (pathsMatch(resource.path, path) || pathContains(resource.path, path)) return true;
  const resourcePath = canonicalPath(resource.path);
  const candidatePath = canonicalPath(path);
  if (basename(resourcePath) === "SKILL.md") {
    return (
      candidatePath === dirname(resourcePath) || pathContains(dirname(resourcePath), candidatePath)
    );
  }
  return (
    (basename(resourcePath) === "index.ts" || basename(resourcePath) === "index.js") &&
    candidatePath === dirname(resourcePath)
  );
}

function diagnosticMatchesResource(
  diagnostic: ResourceDiagnostic,
  resource: ResolvedResource,
): boolean {
  if (diagnostic.path && resourceContainsPath(resource, diagnostic.path)) return true;
  const collision = diagnostic.collision;
  return Boolean(
    collision &&
    (resourceContainsPath(resource, collision.loserPath) ||
      resourceContainsPath(resource, collision.winnerPath)),
  );
}

function copyDiagnostic(diagnostic: ResourceDiagnostic): ResourceDiagnostic {
  return {
    type: diagnostic.type,
    message: diagnostic.message,
    path: diagnostic.path,
    collision: diagnostic.collision ? { ...diagnostic.collision } : undefined,
  };
}

function copyLoadedExtension(extension: Extension): Extension {
  return {
    ...extension,
    sourceInfo: { ...extension.sourceInfo },
    handlers: new Map(
      [...extension.handlers.entries()].map(([name, handlers]) => [name, [...handlers]]),
    ),
    tools: new Map(extension.tools),
    commands: new Map(extension.commands),
    flags: new Map(extension.flags),
    shortcuts: new Map(extension.shortcuts),
    messageRenderers: new Map(extension.messageRenderers),
    entryRenderers: extension.entryRenderers ? new Map(extension.entryRenderers) : undefined,
  };
}

function skillNameFromPath(path: string): string {
  return basename(path) === "SKILL.md" ? basename(dirname(path)) : basename(path);
}

function skillFileLocation(
  resourcePath: string,
  skill: Skill | undefined,
): { baseDir: string; markdownFileName: string } {
  if (skill) {
    return {
      baseDir: canonicalPath(skill.baseDir),
      markdownFileName: basename(skill.filePath),
    };
  }
  if (basename(resourcePath) === "SKILL.md" || resourcePath.endsWith(".md")) {
    return { baseDir: dirname(resourcePath), markdownFileName: basename(resourcePath) };
  }
  return { baseDir: resourcePath, markdownFileName: "SKILL.md" };
}

function extensionNameFromPath(path: string): string {
  const fileName = basename(path);
  const withoutExtension = fileName.replace(/\.(?:ts|js)$/, "");
  if (withoutExtension !== "index") return withoutExtension;
  return basename(dirname(path));
}

function extensionKind(resource: ResolvedResource): ServerExtensionSummary["kind"] {
  if (resource.metadata.origin === "package") return "package";
  try {
    return lstatSync(resource.path).isDirectory() ? "directory" : "file";
  } catch {
    return "file";
  }
}

function resourceProvenance(resource: ResolvedResource, agentDir: string): ResourceProvenance {
  if (resource.metadata.origin === "package") {
    return { kind: "package", label: boundMessage(resource.metadata.source) };
  }
  const path = canonicalPath(resource.path);
  if (pathContains(join(agentDir, "skills"), path)) {
    return { kind: "piAgent", label: "~/.pi/agent/skills" };
  }
  if (pathContains(join(agentDir, "extensions"), path)) {
    return { kind: "piAgent", label: "~/.pi/agent/extensions" };
  }
  const agentsSkills = join(homedir(), ".agents", "skills");
  if (pathContains(agentsSkills, path)) {
    return { kind: "agents", label: "~/.agents/skills" };
  }
  if (resource.metadata.scope === "user") {
    return { kind: "userSettings", label: "Pi user settings" };
  }
  return { kind: "unknown", label: "Unknown source" };
}

function configuredPackageName(source: string): string | undefined {
  if (!source.startsWith("npm:")) return undefined;
  const spec = source.slice("npm:".length).trim();
  if (!spec) return undefined;
  if (spec.startsWith("@")) {
    const slash = spec.indexOf("/");
    if (slash < 2) return undefined;
    const versionAt = spec.indexOf("@", slash);
    return boundMessage(versionAt < 0 ? spec : spec.slice(0, versionAt));
  }
  const versionAt = spec.lastIndexOf("@");
  return boundMessage(versionAt > 0 ? spec.slice(0, versionAt) : spec);
}

function compareSummaries(
  left: Pick<ServerSkillSummary, "name" | "id">,
  right: Pick<ServerSkillSummary, "name" | "id">,
): number {
  const leftName = left.name.toLocaleLowerCase("en-US");
  const rightName = right.name.toLocaleLowerCase("en-US");
  if (leftName < rightName) return -1;
  if (leftName > rightName) return 1;
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

function stripPatternPrefix(pattern: string): string {
  return pattern.startsWith("!") || pattern.startsWith("+") || pattern.startsWith("-")
    ? pattern.slice(1)
    : pattern;
}

function resolveSettingsEntryPath(entry: string, baseDir: string): string {
  const stripped = stripPatternPrefix(entry);
  const expanded =
    stripped === "~" || stripped.startsWith("~/")
      ? stripped.replace(/^~(?=\/|$)/, homedir())
      : stripped;
  return resolve(isAbsolute(expanded) ? expanded : join(baseDir, expanded));
}

function settingsEntryMatchesResource(
  type: "skills" | "extensions",
  entry: string,
  resource: ResolvedResource,
  baseDir: string,
): boolean {
  const entryPath = canonicalPath(resolveSettingsEntryPath(entry, baseDir));
  const resourcePath = canonicalPath(resource.path);
  if (entryPath === resourcePath) return true;
  if (type === "skills") {
    return basename(resourcePath) === "SKILL.md" && dirname(resourcePath) === entryPath;
  }
  return (
    (basename(resourcePath) === "index.ts" || basename(resourcePath) === "index.js") &&
    dirname(resourcePath) === entryPath
  );
}

function mapPiGlobalConfigError(cause: unknown): Error {
  if (cause instanceof PiGlobalConfigError) {
    if (cause.code === "validation") {
      return new ServerResourceValidationError(cause.message, { cause });
    }
    return new ServerResourceServiceError(cause.message, { cause });
  }
  return cause instanceof Error ? cause : new ServerResourceServiceError(String(cause));
}

function toPosixPath(path: string): string {
  return path.split(sep).join("/");
}

function copySkillSummary(summary: ServerSkillSummary): ServerSkillSummary {
  return { ...summary, provenance: { ...summary.provenance }, warnings: [...summary.warnings] };
}

function builtInToolSummaries(cwd: string): ServerToolSummary[] {
  const defaultToolNames = new Set(["read", "bash", "edit", "write"]);
  return [
    createReadToolDefinition(cwd),
    createBashToolDefinition(cwd),
    createEditToolDefinition(cwd),
    createWriteToolDefinition(cwd),
    createGrepToolDefinition(cwd),
    createFindToolDefinition(cwd),
    createLsToolDefinition(cwd),
  ].map((tool) => ({
    name: tool.name,
    ...(tool.description ? { description: boundMessage(tool.description) } : {}),
    defaultEnabled: defaultToolNames.has(tool.name),
  }));
}

function optionalToolSummaries(extensions: Extension[]): ServerToolSummary[] {
  const byName = new Map<string, ServerToolSummary>();
  for (const extension of extensions) {
    for (const [name, tool] of extension.tools) {
      if (tool.definition.defaultActive !== false || byName.has(name)) continue;
      byName.set(name, {
        name,
        ...(tool.definition.description
          ? { description: boundMessage(tool.definition.description) }
          : {}),
        defaultEnabled: false,
      });
    }
  }
  return [...byName.values()].sort((left, right) => left.name.localeCompare(right.name, "en-US"));
}

function copyToolSummary(summary: ServerToolSummary): ServerToolSummary {
  return { ...summary };
}

/**
 * Classic row `summary` with its package's plugin: both kinds, and the plugin's load error
 * (the classic one first, when both failed).
 */
function withPlugin(
  summary: ServerExtensionSummary,
  plugin: PluginListing | undefined,
): ServerExtensionSummary {
  if (!plugin) return summary;
  const loadError = plugin.loadError === undefined ? undefined : boundMessage(plugin.loadError);
  return {
    ...summary,
    kinds: ["plugin", "pi-extension"],
    plugin: pluginSummary(plugin),
    ...(loadError === undefined
      ? {}
      : summary.loadError === undefined
        ? { state: "error" as const, loadError }
        : { warnings: boundedWarnings([loadError, ...summary.warnings]) }),
  };
}

/** The row of a plugin with no classic extension to share one with. */
function pluginRow(id: string, plugin: PluginListing, agentDir: string): ServerExtensionSummary {
  const loadError = plugin.loadError === undefined ? undefined : boundMessage(plugin.loadError);
  const singleFile = plugin.facet !== undefined && !basename(plugin.facet).startsWith("server.");
  return {
    id,
    name: boundMessage(plugin.name),
    kind: plugin.source === "built-in" ? "builtIn" : singleFile ? "file" : "directory",
    provenance: pluginProvenance(plugin, agentDir),
    path: canonicalPath(plugin.facet ?? plugin.dir),
    state: loadError ? "error" : plugin.enabled ? "on" : "off",
    ...(loadError ? { loadError } : {}),
    warnings: [],
    isRemovable: false,
    kinds: ["plugin"],
    source: plugin.source,
    plugin: pluginSummary(plugin),
  };
}

function pluginSummary(plugin: PluginListing): ServerPluginSummary {
  return {
    ...(plugin.extension === undefined ? {} : { extension: plugin.extension }),
    required: plugin.required,
    enabled: plugin.enabled,
    runtimes: [...plugin.runtimes],
    tools: [...plugin.tools],
    hooks: plugin.hooks.map((hook) => ({ task: hook.task, handlers: [...hook.handlers] })),
    sections: [...plugin.sections],
    wraps: plugin.wraps.map((wrap) => ({ ...wrap })),
    tasks: [...plugin.tasks],
    ...(plugin.loadError === undefined ? {} : { loadError: boundMessage(plugin.loadError) }),
    kept: plugin.kept,
  };
}

function pluginProvenance(plugin: PluginListing, agentDir: string): ResourceProvenance {
  if (plugin.source === "built-in") return { kind: "builtIn", label: "Oppi" };
  if (pathContains(join(agentDir, "plugins"), plugin.dir))
    return { kind: "piAgent", label: "~/.pi/agent/plugins" };
  if (pathContains(join(agentDir, "extensions"), plugin.dir))
    return { kind: "piAgent", label: "~/.pi/agent/extensions" };
  return { kind: "userSettings", label: "Pi user settings" };
}

function copyExtensionSummary(summary: ServerExtensionSummary): ServerExtensionSummary {
  return {
    ...summary,
    provenance: { ...summary.provenance },
    warnings: [...summary.warnings],
    kinds: [...summary.kinds],
    plugin: summary.plugin
      ? {
          ...summary.plugin,
          runtimes: [...summary.plugin.runtimes],
          tools: [...summary.plugin.tools],
          hooks: summary.plugin.hooks.map((hook) => ({ ...hook, handlers: [...hook.handlers] })),
          sections: [...summary.plugin.sections],
          wraps: summary.plugin.wraps.map((wrap) => ({ ...wrap })),
          tasks: [...summary.plugin.tasks],
        }
      : undefined,
    contributedTools: summary.contributedTools ? [...summary.contributedTools] : undefined,
    contributedToolDetails: summary.contributedToolDetails
      ? summary.contributedToolDetails.map(copyToolSummary)
      : undefined,
    contributedCommands: summary.contributedCommands ? [...summary.contributedCommands] : undefined,
  };
}

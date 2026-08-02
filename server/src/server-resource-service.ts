import { lstatSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  DefaultPackageManager,
  DefaultResourceLoader,
  SettingsManager,
  loadSkills,
  type Extension,
  type PackageSource,
  type ResolvedResource,
  type ResourceDiagnostic,
  type Skill,
} from "@earendil-works/pi-coding-agent";

import {
  type OppiExtensionSettingsReader,
  type OppiExtensionSettingsSnapshot,
} from "./oppi-extension-settings.js";
import {
  canonicalServerResourcePath as canonicalPath,
  serverResourceId as resourceId,
} from "./server-resource-id.js";
import {
  listSkillFiles,
  readSkillFile as readContainedSkillFile,
  readSkillFileSnapshot as readContainedSkillFileSnapshot,
  SkillFileConflictError,
  SkillFileInvalidTextError,
  SkillFileNotFoundError,
  SkillFileTooLargeError,
  writeSkillFile as writeContainedSkillFile,
} from "./skill-files.js";

const MAX_MESSAGE_LENGTH = 2048;
const MAX_WARNINGS = 8;

export type ResourceProvenanceKind =
  | "builtIn"
  | "piAgent"
  | "agents"
  | "userSettings"
  | "package"
  | "unknown";

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

export interface ServerExtensionSummary {
  id: string;
  name: string;
  description?: string;
  kind: "builtIn" | "file" | "directory" | "package";
  provenance: ResourceProvenance;
  path?: string;
  packageName?: string;
  state: "on" | "off" | "error";
  loadError?: string;
  warnings: string[];
  isRemovable: false;
  contributedTools?: string[];
  contributedCommands?: string[];
}

export interface ServerExtensionDetail {
  summary: ServerExtensionSummary;
  contributedTools?: string[];
  contributedCommands?: string[];
}

export interface ServerResourceServiceOptions {
  dataDir: string;
  agentDir: string;
  oppiSettings: OppiExtensionSettingsReader;
}

interface ResolutionContext {
  cwd: string;
  agentDir: string;
  settingsManager: SettingsManager;
  skills: ResolvedResource[];
  extensions: ResolvedResource[];
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

export class ServerResourceConflictError extends ServerResourceServiceError {
  constructor(options?: ErrorOptions) {
    super("Skill file changed since it was read", options);
    this.name = "ServerResourceConflictError";
  }
}

export class ServerResourceService {
  private readonly dataDir: string;
  private readonly agentDir: string;
  private readonly catalogCwd: string;
  private readonly oppiSettings: OppiExtensionSettingsReader;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(options: ServerResourceServiceOptions) {
    this.dataDir = resolve(options.dataDir);
    this.agentDir = resolve(options.agentDir);
    this.catalogCwd = join(this.dataDir, "resource-catalog-cwd");
    this.oppiSettings = options.oppiSettings;
  }

  async listSkills(): Promise<{ skills: ServerSkillSummary[] }> {
    const entries = await this.buildSkillCatalog(await this.resolveContext());
    return { skills: entries.map((entry) => copySkillSummary(entry.summary)) };
  }

  async listExtensions(): Promise<{
    extensions: ServerExtensionSummary[];
    oppiConfiguration: OppiExtensionSettingsSnapshot;
  }> {
    const configuration = this.oppiSettings.get();
    const entries = await this.buildExtensionCatalog(await this.resolveContext(), configuration);
    return {
      extensions: entries.map((entry) => copyExtensionSummary(entry.summary)),
      oppiConfiguration: configuration,
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

  async updateSkillFile(
    id: string,
    path: string,
    content: string,
    baseRevision: string,
  ): Promise<{ content: string; revision: string }> {
    return this.withMutationLock(async () => {
      const entry = (await this.buildSkillCatalog(await this.resolveContext())).find(
        (candidate) => candidate.summary.id === id,
      );
      if (!entry) throw new ServerResourceNotFoundError("skill");
      if (!entry.summary.editable || entry.resource.metadata.origin !== "top-level") {
        throw new ServerResourceReadOnlyError();
      }
      try {
        return writeContainedSkillFile(entry.baseDir, path, content, baseRevision);
      } catch (error: unknown) {
        if (error instanceof SkillFileNotFoundError) {
          throw new ServerResourceNotFoundError("skill file");
        }
        if (error instanceof SkillFileConflictError) {
          throw new ServerResourceConflictError({ cause: error });
        }
        if (error instanceof SkillFileTooLargeError || error instanceof SkillFileInvalidTextError) {
          throw new ServerResourceValidationError(error.message, { cause: error });
        }
        throw new ServerResourceServiceError(`Skill file write failed: ${messageFrom(error)}`, {
          cause: error,
        });
      }
    });
  }

  async getExtensionDetail(id: string): Promise<ServerExtensionDetail> {
    const configuration = this.oppiSettings.get();
    const entry = (
      await this.buildExtensionCatalog(await this.resolveContext(), configuration)
    ).find((candidate) => candidate.summary.id === id);
    if (!entry) throw new ServerResourceNotFoundError("extension");
    const summary = copyExtensionSummary(entry.summary);
    return {
      summary,
      contributedTools: summary.contributedTools ? [...summary.contributedTools] : undefined,
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

  async setExtensionEnabled(id: string, enabled: boolean): Promise<ServerExtensionSummary> {
    if (id === "oppi") {
      throw new ServerResourceServiceError(
        "The built-in Oppi extension is configured through full-snapshot settings",
      );
    }
    return this.withMutationLock(async () => {
      const context = await this.resolveContext();
      const resource = this.findResourceById("extension", context.extensions, id);
      this.writeResourceEnabled(context, resource, "extensions", enabled);
      await this.finishSettingsWrite(context.settingsManager);
      const configuration = this.oppiSettings.get();
      const authoritative = await this.buildExtensionCatalog(
        await this.resolveContext(),
        configuration,
      );
      const current = authoritative.find((entry) => entry.summary.id === id);
      if (!current) throw new ServerResourceNotFoundError("extension");
      return copyExtensionSummary(current.summary);
    });
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
    return {
      cwd: this.catalogCwd,
      agentDir: this.agentDir,
      settingsManager,
      skills: resolvedPaths.skills.filter((resource) => resource.metadata.scope === "user"),
      extensions: resolvedPaths.extensions.filter((resource) => resource.metadata.scope === "user"),
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
    configuration: OppiExtensionSettingsSnapshot,
  ): Promise<ExtensionCatalogEntry[]> {
    const resources = context.extensions.map((resource) => ({
      resource,
      canonicalPath: canonicalPath(resource.path),
    }));
    const enabledPaths = resources
      .filter((entry) => entry.resource.enabled)
      .map((entry) => entry.resource.path);
    const loader = new DefaultResourceLoader({
      cwd: context.cwd,
      agentDir: context.agentDir,
      settingsManager: SettingsManager.inMemory({}, { projectTrusted: false }),
      additionalExtensionPaths: enabledPaths,
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
      const loadError = resource.enabled
        ? (extensionErrors[0]?.error ?? (!extension ? "Extension could not be loaded" : undefined))
        : undefined;
      const contributedTools = extension ? [...extension.tools.keys()].sort() : undefined;
      const contributedCommands = extension ? [...extension.commands.keys()].sort() : undefined;
      const packageName = configuredPackageName(resource.metadata.source);
      const summary: ServerExtensionSummary = {
        id: resourceId("extension", path),
        name: boundMessage(extensionNameFromPath(resource.path)),
        kind: extensionKind(resource),
        provenance: resourceProvenance(resource, context.agentDir),
        path,
        ...(packageName ? { packageName } : {}),
        state: loadError ? "error" : resource.enabled ? "on" : "off",
        ...(loadError ? { loadError: boundMessage(loadError) } : {}),
        warnings,
        isRemovable: false,
        ...(contributedTools ? { contributedTools } : {}),
        ...(contributedCommands ? { contributedCommands } : {}),
      };
      return { resource, canonicalPath: path, summary };
    });
    normal.sort((a, b) => compareSummaries(a.summary, b.summary));

    const oppiLoadError = this.oppiSettings.getLoadError();
    const oppi: ExtensionCatalogEntry = {
      summary: {
        id: "oppi",
        name: "Oppi",
        description: "Server-owned Oppi command extension",
        kind: "builtIn",
        provenance: { kind: "builtIn", label: "Built-in extension" },
        state: oppiLoadError ? "error" : configuration.enabled ? "on" : "off",
        ...(oppiLoadError ? { loadError: boundMessage(oppiLoadError) } : {}),
        warnings: [],
        isRemovable: false,
      },
    };
    return [oppi, ...normal];
  }

  private findResourceById(
    kind: "skill" | "extension",
    resources: ResolvedResource[],
    id: string,
  ): ResolvedResource {
    const matches = resources.filter(
      (candidate) => resourceId(kind, canonicalPath(candidate.path)) === id,
    );
    const resource =
      matches.find((candidate) => candidate.metadata.origin === "package") ?? matches[0];
    if (!resource || resource.metadata.scope !== "user") {
      throw new ServerResourceNotFoundError(kind);
    }
    return resource;
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

function toPosixPath(path: string): string {
  return path.split(sep).join("/");
}

function copySkillSummary(summary: ServerSkillSummary): ServerSkillSummary {
  return { ...summary, provenance: { ...summary.provenance }, warnings: [...summary.warnings] };
}

function copyExtensionSummary(summary: ServerExtensionSummary): ServerExtensionSummary {
  return {
    ...summary,
    provenance: { ...summary.provenance },
    warnings: [...summary.warnings],
    contributedTools: summary.contributedTools ? [...summary.contributedTools] : undefined,
    contributedCommands: summary.contributedCommands ? [...summary.contributedCommands] : undefined,
  };
}

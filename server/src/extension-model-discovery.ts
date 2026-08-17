/**
 * Extension provider discovery for the server-wide model catalog.
 *
 * Custom provider extensions (e.g. pi-provider-kiro, @raquezha/antigravity)
 * register models via `pi.registerProvider()` while their module loads. The
 * server-wide ModelRegistry that feeds `GET /models` is built only from
 * auth.json/models.json, so those models never reach the client picker even
 * though per-session runtimes (which load extensions) can use them.
 *
 * This module closes that gap by loading the user's global/pi-enabled
 * extensions with pi's own resource loader, harvesting the providers they
 * register, and applying them to a ModelRuntime — mirroring pi's
 * `createAgentSessionServices` registration flow. Project-local extensions are
 * excluded (project trust is forced off) so discovery only runs user/global
 * extensions, matching the "global scope" decision in the issue #19 design.
 */

import { existsSync, mkdtempSync, readdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DefaultPackageManager,
  SettingsManager,
  discoverAndLoadExtensions,
  type LoadExtensionsResult,
  type ModelRuntime,
} from "@earendil-works/pi-coding-agent";

import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "extension_model_discovery" } });

export interface ExtensionProviderDiagnostic {
  extensionPath: string;
  message: string;
}

export interface AppliedProviderRegistrations {
  /** Provider ids successfully registered (extension name or native provider id). */
  registeredProviderIds: string[];
  /** Per-extension registration failures; one bad extension never blocks the rest. */
  diagnostics: ExtensionProviderDiagnostic[];
}

/**
 * The subset of ModelRuntime needed to apply registrations. Kept narrow so the
 * helper is unit-testable with a fake target.
 */
export type ProviderRegistrationTarget = Pick<
  ModelRuntime,
  "registerProvider" | "registerNativeProvider"
>;

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Apply provider registrations queued during extension loading to a model
 * runtime, then clear the queues so a later runner bind does not re-apply them.
 *
 * This is the same shape as pi's `createAgentSessionServices` and the extension
 * runner's `bindCore` flush: each registration is isolated in try/catch so a
 * single broken extension only loses its own provider.
 */
export function applyPendingProviderRegistrations(
  target: ProviderRegistrationTarget,
  extensionsResult: LoadExtensionsResult,
): AppliedProviderRegistrations {
  const registeredProviderIds: string[] = [];
  const diagnostics: ExtensionProviderDiagnostic[] = [];
  const runtime = extensionsResult.runtime;

  for (const { name, config, extensionPath } of runtime.pendingProviderRegistrations) {
    try {
      target.registerProvider(name, config);
      registeredProviderIds.push(name);
    } catch (error) {
      diagnostics.push({ extensionPath, message: errorMessage(error) });
    }
  }
  runtime.pendingProviderRegistrations = [];

  for (const { provider, extensionPath } of runtime.pendingNativeProviderRegistrations) {
    try {
      target.registerNativeProvider(provider);
      registeredProviderIds.push(provider.id);
    } catch (error) {
      diagnostics.push({ extensionPath, message: errorMessage(error) });
    }
  }
  runtime.pendingNativeProviderRegistrations = [];

  return { registeredProviderIds, diagnostics };
}

export interface ExtensionProviderDiscoveryOptions {
  /** cwd used for pi settings resolution (typically the server process cwd). */
  cwd: string;
  /** pi agent dir (e.g. ~/.pi/agent) holding global extensions and packages. */
  agentDir: string;
}

export type ExtensionProviderDiscoveryResult = AppliedProviderRegistrations;

/**
 * Load global/user extensions and register the providers they declare onto the
 * given model runtime, then refresh availability. The refresh passes
 * `allowNetwork: false`; this is advisory (pi forwards it to a provider's
 * `refreshModels` but does not enforce it), matching pi's own session startup.
 *
 * Compatibility wrapper around `ExtensionProviderCatalog.sync()` so one-shot
 * callers and fixture tests use the same no-install reconcile path as the server.
 */
export async function discoverExtensionProviders(
  modelRuntime: ExtensionProviderCatalogRuntime,
  options: ExtensionProviderDiscoveryOptions,
): Promise<ExtensionProviderDiscoveryResult> {
  const result = await new ExtensionProviderCatalog(modelRuntime, options).sync({
    force: true,
  });
  return {
    registeredProviderIds: result.registeredProviderIds,
    diagnostics: result.diagnostics,
  };
}

function fileStamp(path: string): string {
  try {
    const stat = statSync(path);
    return `${stat.mtimeMs}:${stat.size}`;
  } catch {
    return "missing";
  }
}

/** Stamp a directory listing. depth=1 covers `extensions/foo/index.ts`. */
function directoryStamp(dir: string, depth: number): string {
  try {
    return readdirSync(dir)
      .filter((name) => !name.startsWith("."))
      .sort()
      .map((name) => {
        const path = join(dir, name);
        if (depth > 0) {
          try {
            if (statSync(path).isDirectory()) {
              return `${name}:{${directoryStamp(path, depth - 1)}}`;
            }
          } catch {
            // Fall through to the file stamp.
          }
        }
        return `${name}:${fileStamp(path)}`;
      })
      .join(",");
  } catch {
    return existsSync(dir) ? "unreadable" : "missing";
  }
}

/**
 * Cheap source stamp for global provider discovery. Covers settings enablement,
 * top-level and one-nested-level files under `extensions/`, and npm/git package
 * metadata. Deeper package trees are picked up when settings.json changes.
 */
export function extensionDiscoveryFingerprint(agentDir: string): string {
  const settings = fileStamp(join(agentDir, "settings.json"));
  const extensions = directoryStamp(join(agentDir, "extensions"), 1);
  const npmPkg = fileStamp(join(agentDir, "npm", "package.json"));
  const npmLock = fileStamp(join(agentDir, "npm", "package-lock.json"));
  const git = directoryStamp(join(agentDir, "git"), 1);
  return `settings=${settings};extensions=${extensions};npm=${npmPkg},${npmLock};git=${git}`;
}

export interface ExtensionProviderSyncOptions {
  /** Reload even when the source fingerprint is unchanged. */
  force?: boolean;
}

export interface ExtensionProviderSyncResult extends AppliedProviderRegistrations {
  skipped: boolean;
  unregisteredProviderIds: string[];
}

export type ExtensionProviderCatalogRuntime = ProviderRegistrationTarget &
  Pick<ModelRuntime, "refresh" | "unregisterProvider">;

/**
 * Server-wide provider catalog. Reconciles global/user extension providers onto
 * one ModelRuntime: register current ids, unregister ids this catalog applied
 * that are no longer declared. Project-local extensions stay excluded.
 */
export class ExtensionProviderCatalog {
  private lastFingerprint?: string;
  private readonly registeredIds = new Set<string>();
  private queue: Promise<void> = Promise.resolve();
  private readonly discoveryRoot = mkdtempSync(join(tmpdir(), "oppi-provider-catalog-"));

  constructor(
    private readonly modelRuntime: ExtensionProviderCatalogRuntime,
    private readonly options: ExtensionProviderDiscoveryOptions,
  ) {}

  async sync(options: ExtensionProviderSyncOptions = {}): Promise<ExtensionProviderSyncResult> {
    const run = this.queue.then(() => this.syncExclusive(options));
    this.queue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private async syncExclusive(
    options: ExtensionProviderSyncOptions,
  ): Promise<ExtensionProviderSyncResult> {
    let fingerprint: string;
    try {
      fingerprint = extensionDiscoveryFingerprint(this.options.agentDir);
    } catch (error) {
      const message = errorMessage(error);
      log.warn("extension_model_discovery.fingerprint_failed", { error: message });
      return {
        registeredProviderIds: [...this.registeredIds],
        diagnostics: [{ extensionPath: this.options.agentDir, message }],
        skipped: false,
        unregisteredProviderIds: [],
      };
    }
    if (!options.force && this.lastFingerprint === fingerprint) {
      return {
        registeredProviderIds: [...this.registeredIds],
        diagnostics: [],
        skipped: true,
        unregisteredProviderIds: [],
      };
    }

    try {
      const { applied, diagnostics, removedProviderIds } = await this.loadAndReplace();
      this.lastFingerprint = fingerprint;

      for (const diagnostic of diagnostics) {
        log.warn("extension_model_discovery.diagnostic", {
          extensionPath: diagnostic.extensionPath,
          message: diagnostic.message,
        });
      }
      if (applied.registeredProviderIds.length > 0 || removedProviderIds.length > 0) {
        log.info("extension_model_discovery.providers_reconciled", {
          providerCount: applied.registeredProviderIds.length,
          providers: applied.registeredProviderIds.join(","),
          unregisteredCount: removedProviderIds.length,
          unregistered: removedProviderIds.join(","),
        });
      }

      return {
        registeredProviderIds: [...this.registeredIds],
        diagnostics,
        skipped: false,
        unregisteredProviderIds: removedProviderIds,
      };
    } catch (error) {
      // Remember the stamp so a broken source is not reloaded on every GET /models.
      // force:true or a later fingerprint change still retries.
      this.lastFingerprint = fingerprint;
      const message = errorMessage(error);
      log.warn("extension_model_discovery.sync_failed", { error: message });
      return {
        registeredProviderIds: [...this.registeredIds],
        diagnostics: [{ extensionPath: this.options.agentDir, message }],
        skipped: false,
        unregisteredProviderIds: [],
      };
    }
  }

  private async loadAndReplace(): Promise<{
    applied: AppliedProviderRegistrations;
    diagnostics: ExtensionProviderDiagnostic[];
    removedProviderIds: string[];
  }> {
    const settingsManager = SettingsManager.create(this.options.cwd, this.options.agentDir, {
      projectTrusted: false,
    });
    await settingsManager.reload();
    const packageManager = new DefaultPackageManager({
      cwd: this.options.cwd,
      agentDir: this.options.agentDir,
      settingsManager,
    });
    // Never npm-install or git-clone on a request path. Missing packages stay
    // out of the catalog until the user installs them outside this reload.
    const skippedSources: string[] = [];
    const resolved = await packageManager.resolve(async (source) => {
      skippedSources.push(source);
      return "skip";
    });
    const enabledPaths = resolved.extensions
      .filter((resource) => resource.enabled)
      .map((resource) => resource.path);
    // Unique empty root so discoverAndLoadExtensions does not also scan the
    // real cwd/.pi/extensions or agentDir/extensions. Paths already come from
    // the skip-resolve. mkdtempSync (not a fixed $TMPDIR name) owns the dir.
    const extensionsResult = await discoverAndLoadExtensions(
      enabledPaths,
      this.discoveryRoot,
      this.discoveryRoot,
    );
    const diagnostics: ExtensionProviderDiagnostic[] = [
      ...skippedSources.map((source) => ({
        extensionPath: source,
        message: "Package is not installed; the model catalog will not install it",
      })),
      ...extensionsResult.errors.map((error) => ({
        extensionPath: error.path,
        message: error.error,
      })),
    ];

    // Unregister first so a re-registration replaces instead of merging leftover
    // fields (apiKey/headers/baseUrl) from the previous factory.
    const previousIds = [...this.registeredIds];
    for (const providerId of previousIds) {
      try {
        this.modelRuntime.unregisterProvider(providerId);
      } catch (error) {
        diagnostics.push({
          extensionPath: providerId,
          message: errorMessage(error),
        });
      }
    }
    this.registeredIds.clear();

    const applied = applyPendingProviderRegistrations(this.modelRuntime, extensionsResult);
    diagnostics.push(...applied.diagnostics);
    for (const providerId of applied.registeredProviderIds) {
      this.registeredIds.add(providerId);
    }
    await this.modelRuntime.refresh({ allowNetwork: false });
    const nextIds = new Set(applied.registeredProviderIds);
    return {
      applied,
      diagnostics,
      removedProviderIds: previousIds.filter((providerId) => !nextIds.has(providerId)),
    };
  }
}

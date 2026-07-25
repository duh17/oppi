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

import {
  DefaultResourceLoader,
  SettingsManager,
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
 * Registrations persist on the runtime across subsequent `refresh()` calls, so
 * this only needs to run once at startup; auth-gated availability then updates
 * dynamically on every catalog refresh (credential changes, `/models`).
 */
export async function discoverExtensionProviders(
  modelRuntime: ProviderRegistrationTarget & Pick<ModelRuntime, "refresh">,
  options: ExtensionProviderDiscoveryOptions,
): Promise<ExtensionProviderDiscoveryResult> {
  // Force project-untrusted so only user/global extensions load. This is pi's
  // bootstrap behavior and keeps arbitrary project-local extensions out of a
  // server-wide discovery pass.
  const settingsManager = SettingsManager.create(options.cwd, options.agentDir, {
    projectTrusted: false,
  });
  const loader = new DefaultResourceLoader({
    cwd: options.cwd,
    agentDir: options.agentDir,
    settingsManager,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
  });

  const extensionsResult = await loader.loadProjectTrustExtensions();
  const diagnostics: ExtensionProviderDiagnostic[] = extensionsResult.errors.map((error) => ({
    extensionPath: error.path,
    message: error.error,
  }));

  const applied = applyPendingProviderRegistrations(modelRuntime, extensionsResult);
  diagnostics.push(...applied.diagnostics);

  // allowNetwork is advisory, not a hard block (pi passes it through to provider
  // refreshModels). Static models registered at load time need no network either
  // way; this mirrors pi's createAgentSessionServices refresh.
  await modelRuntime.refresh({ allowNetwork: false });

  for (const diagnostic of diagnostics) {
    log.warn("extension_model_discovery.diagnostic", {
      extensionPath: diagnostic.extensionPath,
      message: diagnostic.message,
    });
  }
  if (applied.registeredProviderIds.length > 0) {
    log.info("extension_model_discovery.providers_registered", {
      providerCount: applied.registeredProviderIds.length,
      providers: applied.registeredProviderIds.join(","),
    });
  }

  return { registeredProviderIds: applied.registeredProviderIds, diagnostics };
}

import {
  DefaultPackageManager,
  DefaultResourceLoader,
  ProjectTrustStore,
  type ProjectTrustContext,
  type ProjectTrustEventResult,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { serverResourceId } from "./server-resource-id.js";

/** Bounds phone startup dialogs; unanswered decisions deliberately preserve default allow. */
export const PROJECT_TRUST_TIMEOUT_MS = 15_000;
export const PROJECT_TRUST_OPTIONS = [
  "Trust (remember)",
  "Trust this session",
  "Don't trust (remember)",
];

export async function resolveManagedProjectTrust(
  cwd: string,
  agentDir: string,
  settingsManager: SettingsManager,
  context: ProjectTrustContext,
  onError: (extensionPath: string, error: unknown) => void,
  selectedExtensionIds?: readonly string[],
): Promise<boolean> {
  // Resolve exact selections while untrusted: selected project extensions cannot
  // participate before trust, and excluded user factories must not execute.
  let selectedPaths: string[] | undefined;
  if (selectedExtensionIds !== undefined) {
    settingsManager.setProjectTrusted(false);
    await settingsManager.reload();
    const resolved = await new DefaultPackageManager({ cwd, agentDir, settingsManager }).resolve(
      async () => "skip",
    );
    const selected = new Set(selectedExtensionIds);
    selectedPaths = resolved.extensions
      .filter(
        (resource) =>
          resource.metadata.scope === "user" &&
          selected.has(serverResourceId("extension", resource.path)),
      )
      .map((resource) => resource.path);
  }
  const bootstrap = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    ...(selectedPaths !== undefined
      ? { noExtensions: true, additionalExtensionPaths: selectedPaths }
      : {}),
  });
  const extensions = await bootstrap.loadProjectTrustExtensions();
  const store = new ProjectTrustStore(agentDir);
  // Pi's emitter is not publicly exported. Use the public Extension handler map,
  // preserving Pi's ordering, snapshot semantics, undecided fallthrough and errors.
  const handlers = extensions.extensions.map((extension) => ({
    extension,
    handlers: extension.handlers.get("project_trust")?.slice() ?? [],
  }));
  for (const entry of handlers) {
    for (const handler of entry.handlers) {
      let result: ProjectTrustEventResult;
      try {
        result = (await handler(
          { type: "project_trust", cwd },
          context,
        )) as ProjectTrustEventResult;
        if (result.trusted === "undecided") continue;
      } catch (error) {
        onError(entry.extension.path, error);
        continue;
      }
      const trusted = result.trusted === "yes";
      // Like Pi, a failed remember is a startup error, not an undecided answer.
      if (result.remember === true) store.set(cwd, trusted);
      return trusted;
    }
  }
  const saved = store.get(cwd);
  if (saved !== null) return saved;
  switch (settingsManager.getDefaultProjectTrust()) {
    case "always":
      return true;
    case "never":
      return false;
  }
  if (!context.hasUI) return true;
  const selected = await context.ui.select(
    `Trust project folder?\n${cwd}\n\nTrust allows Pi to load project settings, MCP servers, extensions, skills, prompts, themes and system prompts, and install project packages. Project extensions and MCP servers can run host processes.\n\nNo answer within 15 seconds allows this session without remembering a decision.`,
    PROJECT_TRUST_OPTIONS,
    { timeout: PROJECT_TRUST_TIMEOUT_MS },
  );
  if (selected === PROJECT_TRUST_OPTIONS[0]) store.set(cwd, true);
  if (selected === PROJECT_TRUST_OPTIONS[2]) {
    store.set(cwd, false);
    return false;
  }
  return true;
}

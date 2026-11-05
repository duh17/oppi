import type { IncomingMessage, ServerResponse } from "node:http";

import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { applySetting, revisionConflictBody } from "../settings/config-settings.js";
import { httpStatusForPiResourceError } from "../settings/pi-resource-errors.js";
import { isRevision } from "../settings/revision.js";
import { SettingValidationError, validateSetting, type SettingKey } from "../settings/registry.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const MAX_REQUEST_BODY_BYTES = 16 * 1024;
const MAX_CAUSAL_MESSAGE_CHARS = 512;
const SKILL_ID = /^skill_[a-f0-9]{64}$/;
const EXTENSION_ID = /^extension_[a-f0-9]{64}$/;
const log = createLogger({ base: { component: "route_server_resources" } });

type ResourceOperation = "catalog" | "detail" | "file" | "mutation" | "guide_persistence";
type ResourceKind = "skill" | "extension" | "mobile_output_guide" | "pi_config";
type ErrorCategory =
  | "conflict"
  | "fsync_failed"
  | "loader"
  | "malformed_settings"
  | "not_found"
  | "permission_denied"
  | "rename_failed"
  | "unknown"
  | "validation"
  | "write_failed";

interface ErrorDiagnostic {
  category: ErrorCategory;
  message: string;
}

const ERROR_DIAGNOSTICS: Record<ErrorCategory, ErrorDiagnostic> = {
  conflict: { category: "conflict", message: "settings revision conflict" },
  fsync_failed: { category: "fsync_failed", message: "settings fsync failed" },
  loader: { category: "loader", message: "Pi resource loader failed" },
  malformed_settings: { category: "malformed_settings", message: "Pi settings are malformed" },
  not_found: { category: "not_found", message: "resource was not found" },
  permission_denied: { category: "permission_denied", message: "filesystem access denied" },
  rename_failed: { category: "rename_failed", message: "settings rename failed" },
  unknown: { category: "unknown", message: "server resource operation failed" },
  validation: { category: "validation", message: "request body validation failed" },
  write_failed: { category: "write_failed", message: "settings write failed" },
};

function error(res: ServerResponse, helpers: RouteHelpers, message: string): void {
  helpers.error(res, 400, message);
}

function hasNoQuery(url: URL): boolean {
  return [...url.searchParams.keys()].length === 0;
}

function hasExactQuery(url: URL, key: string): string | undefined {
  const keys = [...url.searchParams.keys()];
  if (keys.length !== 1 || keys[0] !== key || url.searchParams.getAll(key).length !== 1) {
    return undefined;
  }
  const value = url.searchParams.get(key);
  return value && value.length > 0 ? value : undefined;
}

function decodeSegment(segment: string): string | undefined {
  try {
    const decoded = decodeURIComponent(segment);
    return decoded.includes("/") || decoded.includes("\\") || decoded.includes("\0")
      ? undefined
      : decoded;
  } catch {
    return undefined;
  }
}

function acceptsJson(req: IncomingMessage): boolean {
  const contentType = req.headers?.["content-type"];
  const value = Array.isArray(contentType) ? contentType[0] : contentType;
  return value?.split(";", 1)[0]?.trim().toLowerCase() === "application/json";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return (
    actual.length === sortedExpected.length &&
    actual.every((key, index) => key === sortedExpected[index])
  );
}

async function parseJsonObject(
  req: IncomingMessage,
  helpers: RouteHelpers,
  expectedKeys: readonly string[],
  maxBytes = MAX_REQUEST_BODY_BYTES,
): Promise<Record<string, unknown> | undefined> {
  if (!acceptsJson(req)) return undefined;
  const body = await helpers.parseBody<unknown>(req, { maxBytes });
  if (!isRecord(body) || !hasExactKeys(body, expectedKeys)) return undefined;
  return body;
}

/** The validated value, or undefined for one the setting refuses (no validator returns undefined here). */
function acceptedValue<K extends SettingKey>(
  key: K,
  value: unknown,
): ReturnType<typeof validateSetting<K>> | undefined {
  try {
    return validateSetting(key, value);
  } catch (cause: unknown) {
    if (cause instanceof SettingValidationError) return undefined;
    throw cause;
  }
}

function errorForPiConfig(
  res: ServerResponse,
  helpers: RouteHelpers,
  operation: Extract<ResourceOperation, "catalog" | "mutation">,
  cause: unknown,
): void {
  if (httpStatusForPiResourceError(cause, 500) === 400 && cause instanceof Error) {
    logRouteRejected(operation, "pi_config", "validation");
    helpers.error(res, 400, cause.message);
    return;
  }
  logRouteFailure(operation, "pi_config", cause);
  const action = operation === "mutation" ? "update" : "load";
  helpers.error(res, 500, `Unable to ${action} Pi configuration`);
}

function errorForResource(
  res: ServerResponse,
  helpers: RouteHelpers,
  resource: "Skill" | "Extension",
  operation: ResourceOperation,
  cause: unknown,
): void {
  const resourceKind = resource.toLowerCase() as Extract<ResourceKind, "skill" | "extension">;
  const status = httpStatusForPiResourceError(cause, 500);
  if (status === 404) {
    logRouteRejected(operation, resourceKind, "not_found");
    helpers.error(res, 404, `${resource} not found`);
    return;
  }
  if (status === 400 && cause instanceof Error) {
    logRouteRejected(operation, resourceKind, "validation");
    helpers.error(res, 400, cause.message);
    return;
  }
  if (status === 409 && cause instanceof Error) {
    logRouteRejected(operation, resourceKind, "conflict");
    helpers.error(res, 409, cause.message);
    return;
  }

  logRouteFailure(operation, resourceKind, cause);
  const action = operation === "mutation" ? "update" : "load";
  helpers.error(res, 500, `Unable to ${action} server ${resource.toLowerCase()}s`);
}

function logRouteFailure(
  operation: ResourceOperation,
  resourceKind: ResourceKind,
  cause: unknown,
): void {
  const diagnostic = classifyError(cause);
  log.error("server_resources.route_failed", {
    operation,
    resourceKind,
    category: diagnostic.category,
    message: diagnostic.message,
  });
}

function logRouteRejected(
  operation: ResourceOperation,
  resourceKind: ResourceKind,
  category: Extract<ErrorCategory, "conflict" | "not_found" | "permission_denied" | "validation">,
): void {
  const diagnostic = ERROR_DIAGNOSTICS[category];
  log.info("server_resources.route_rejected", {
    operation,
    resourceKind,
    category: diagnostic.category,
    message: diagnostic.message,
  });
}

function classifyError(cause: unknown): ErrorDiagnostic {
  if (httpStatusForPiResourceError(cause, 500) === 404) return ERROR_DIAGNOSTICS.not_found;

  const messages = causalMessages(cause);
  if (
    hasErrorCode(cause, "EACCES") ||
    hasErrorCode(cause, "EPERM") ||
    matches(messages, /\b(?:eacces|eperm|permission denied)\b/)
  ) {
    return ERROR_DIAGNOSTICS.permission_denied;
  }
  if (matches(messages, /\bfsync\b/)) return ERROR_DIAGNOSTICS.fsync_failed;
  if (matches(messages, /\brename\b/)) return ERROR_DIAGNOSTICS.rename_failed;
  if (matches(messages, /\bwrite\b/)) return ERROR_DIAGNOSTICS.write_failed;
  if (
    matches(
      messages,
      /\b(?:malformed|invalid)\b.*\bsettings\b|\bsettings\b.*\b(?:malformed|invalid|expected)\b|\b(?:json|parse)\b.*\bsettings\b/,
    )
  ) {
    return ERROR_DIAGNOSTICS.malformed_settings;
  }
  if (matches(messages, /\b(?:loader|load enabled pi extensions|resolve pi resources)\b/)) {
    return ERROR_DIAGNOSTICS.loader;
  }
  if (matches(messages, /\b(?:validation|expected)\b/)) return ERROR_DIAGNOSTICS.validation;
  return ERROR_DIAGNOSTICS.unknown;
}

function causalMessages(cause: unknown): string[] {
  const messages: string[] = [];
  let current = cause;
  for (let depth = 0; depth < 4 && current instanceof Error; depth += 1) {
    messages.push(current.message.slice(0, MAX_CAUSAL_MESSAGE_CHARS).toLowerCase());
    current = current.cause;
  }
  return messages;
}

function hasErrorCode(cause: unknown, expected: "EACCES" | "EPERM"): boolean {
  let current = cause;
  for (let depth = 0; depth < 4 && current instanceof Error; depth += 1) {
    const code = (current as Error & { code?: unknown }).code;
    if (code === expected) return true;
    current = current.cause;
  }
  return false;
}

function matches(messages: string[], pattern: RegExp): boolean {
  return messages.some((message) => pattern.test(message));
}

/** Owner-authenticated, server-global Pi resource catalog and Oppi settings routes. */
export function createServerResourceRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  async function listSkills(url: URL, res: ServerResponse): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.listSkills());
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Skill", "catalog", cause);
    }
  }

  async function skillDetail(id: string, url: URL, res: ServerResponse): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.getSkillDetail(id));
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Skill", "detail", cause);
    }
  }

  async function skillFile(id: string, url: URL, res: ServerResponse): Promise<void> {
    const filePath = hasExactQuery(url, "path");
    if (!filePath) {
      error(res, helpers, "path query parameter required");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.readSkillFileSnapshot(id, filePath));
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Skill", "file", cause);
    }
  }

  async function setSkillEnabled(
    id: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let body: Record<string, unknown> | undefined;
    try {
      body = await parseJsonObject(req, helpers, ["enabled"]);
    } catch {
      logRouteRejected("mutation", "skill", "validation");
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    if (!body || typeof body.enabled !== "boolean") {
      logRouteRejected("mutation", "skill", "validation");
      error(res, helpers, "Request body must be exactly { enabled: boolean }");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.setSkillEnabled(id, body.enabled));
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Skill", "mutation", cause);
    }
  }

  /** `?plugins=true` adds the rows that are only a plugin; clients that predate plugins omit it. */
  async function listExtensions(url: URL, res: ServerResponse): Promise<void> {
    const plugins = hasExactQuery(url, "plugins");
    if (!hasNoQuery(url) && plugins !== "true") {
      error(res, helpers, "This server-global route accepts only plugins=true");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.listExtensions({ plugins: plugins === "true" }));
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Extension", "catalog", cause);
    }
  }

  async function extensionDetail(id: string, url: URL, res: ServerResponse): Promise<void> {
    const inspectForAgent = hasExactQuery(url, "agentTools");
    if (!hasNoQuery(url) && inspectForAgent !== "true") {
      error(res, helpers, "This server-global route accepts only agentTools=true");
      return;
    }
    try {
      helpers.json(
        res,
        inspectForAgent === "true"
          ? await ctx.serverResources.inspectAgentExtensionTools(id)
          : await ctx.serverResources.getExtensionDetail(id),
      );
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Extension", "detail", cause);
    }
  }

  async function setExtensionEnabled(
    id: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let body: Record<string, unknown> | undefined;
    try {
      body = await parseJsonObject(req, helpers, ["enabled"]);
    } catch {
      logRouteRejected("mutation", "extension", "validation");
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    if (!body || typeof body.enabled !== "boolean") {
      logRouteRejected("mutation", "extension", "validation");
      error(res, helpers, "Request body must be exactly { enabled: boolean }");
      return;
    }
    try {
      let summary = await ctx.serverResources.setExtensionEnabled(id, body.enabled);
      try {
        await ctx.refreshModelCatalog({ force: true });
      } catch (refreshError: unknown) {
        log.warn("server_resources.extension_catalog_refresh_failed", {
          extensionId: id,
          error: refreshError instanceof Error ? refreshError.message : String(refreshError),
        });
      }
      // Durable sessions load a Pi package's plugins when their store opens and on reload, so the
      // toggle reaches them only through a reload, after which the row shows its plugin as it is
      // now. A package without a plugin changes nothing there: its toggle stays a settings write.
      // Switched on, the plugin that reload loaded is turned on too.
      if (ctx.sessions.durableSessionsAvailable()) {
        try {
          if (await ctx.serverResources.hasPlugin(id)) {
            await ctx.sessions.reloadDurableExtensions();
            if (body.enabled) await ctx.serverResources.enableAttachedPlugin(id);
            summary = (await ctx.serverResources.getExtensionDetail(id)).summary;
          }
        } catch (reloadError: unknown) {
          log.warn("server_resources.durable_extensions_reload_failed", {
            extensionId: id,
            error: reloadError instanceof Error ? reloadError.message : String(reloadError),
          });
        }
      }
      helpers.json(res, summary);
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Extension", "mutation", cause);
    }
  }

  /**
   * Discover and load every plugin again in the running server, without a restart: the report of
   * what loaded, kept its previous code, was removed, skipped, or failed.
   */
  async function reloadPlugins(res: ServerResponse): Promise<void> {
    try {
      helpers.json(res, await ctx.sessions.reloadDurableExtensions());
    } catch (cause: unknown) {
      logRouteFailure("mutation", "extension", cause);
      helpers.error(res, 500, `Unable to reload plugins: ${safeErrorMessage(cause)}`);
    }
  }

  async function getPiSystemPrompt(url: URL, res: ServerResponse): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.getPiSystemPrompt());
    } catch (cause: unknown) {
      errorForPiConfig(res, helpers, "catalog", cause);
    }
  }

  async function getPiDefaultTools(url: URL, res: ServerResponse): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.getPiDefaultTools());
    } catch (cause: unknown) {
      errorForPiConfig(res, helpers, "catalog", cause);
    }
  }

  async function replacePiDefaultTools(req: IncomingMessage, res: ServerResponse): Promise<void> {
    let body: Record<string, unknown> | undefined;
    try {
      body = await parseJsonObject(req, helpers, ["defaultTools"]);
    } catch {
      logRouteRejected("mutation", "pi_config", "validation");
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    const defaultTools = acceptedValue("piDefaultTools", body?.defaultTools);
    if (defaultTools === undefined) {
      logRouteRejected("mutation", "pi_config", "validation");
      error(res, helpers, "Request body must be exactly { defaultTools: string[] | null }");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.setPiDefaultTools(defaultTools));
    } catch (cause: unknown) {
      errorForPiConfig(res, helpers, "mutation", cause);
    }
  }

  async function replacePiDefaultModel(
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    let body: Record<string, unknown> | undefined;
    try {
      body = await parseJsonObject(req, helpers, ["model"]);
    } catch {
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    const model = acceptedValue("piDefaultModel", body?.model);
    if (model === undefined) {
      error(res, helpers, "Request body must be exactly { model: string }");
      return;
    }
    try {
      await ctx.refreshModelCatalog();
      const candidate = ctx.getModelCatalog().find((item) => item.id === model);
      if (!candidate) {
        error(res, helpers, "Model is not available in this server's catalog");
        return;
      }
      const modelId = candidate.id.startsWith(`${candidate.provider}/`)
        ? candidate.id.slice(candidate.provider.length + 1)
        : candidate.id;
      const updated = await ctx.serverResources.setPiDefaultModel(candidate.provider, modelId);
      helpers.json(res, updated);
    } catch (cause: unknown) {
      errorForPiConfig(res, helpers, "mutation", cause);
    }
  }

  function getMobileOutputGuide(url: URL, res: ServerResponse): void {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    helpers.json(res, ctx.storage.getMobileOutputGuideSettings());
  }

  async function replaceMobileOutputGuide(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let body: Record<string, unknown> | undefined;
    try {
      body = await parseJsonObject(req, helpers, ["enabled", "baseRevision"]);
    } catch {
      logRouteRejected("guide_persistence", "mobile_output_guide", "validation");
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    const replacement = body && acceptedValue("mobileOutputGuide", { enabled: body.enabled });
    if (!body || !replacement || !isRevision(body.baseRevision)) {
      logRouteRejected("guide_persistence", "mobile_output_guide", "validation");
      error(
        res,
        helpers,
        "Request body must be exactly { enabled: boolean, baseRevision: number }",
      );
      return;
    }

    try {
      const result = applySetting(ctx.storage, "mobileOutputGuide", replacement, body.baseRevision);
      if (!result.ok) {
        logRouteRejected("guide_persistence", "mobile_output_guide", "conflict");
        helpers.json(res, revisionConflictBody("mobileOutputGuide", result.current), 409);
        return;
      }
      helpers.json(res, result.current);
    } catch (cause: unknown) {
      logRouteFailure("guide_persistence", "mobile_output_guide", cause);
      helpers.error(res, 500, "Unable to update Mobile Output Guide setting");
    }
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/server/resources/skills" && method === "GET") {
      await listSkills(url, res);
      return true;
    }
    if (path === "/server/resources/extensions" && method === "GET") {
      await listExtensions(url, res);
      return true;
    }
    if (path === "/server/resources/extensions/reload" && method === "POST") {
      await reloadPlugins(res);
      return true;
    }
    if (path === "/server/resources/pi/system-prompt" && method === "GET") {
      await getPiSystemPrompt(url, res);
      return true;
    }
    if (path === "/server/resources/pi/default-tools") {
      if (method === "GET") await getPiDefaultTools(url, res);
      else if (method === "PUT") await replacePiDefaultTools(req, res);
      else return false;
      return true;
    }
    if (path === "/server/resources/pi/default-model" && method === "PUT") {
      await replacePiDefaultModel(url, req, res);
      return true;
    }
    if (path === "/server/mobile-output-guide") {
      if (method === "GET") getMobileOutputGuide(url, res);
      else if (method === "PUT") await replaceMobileOutputGuide(req, res);
      else return false;
      return true;
    }

    const skillFileMatch = path.match(/^\/server\/resources\/skills\/([^/]+)\/file$/);
    if (skillFileMatch && method === "GET") {
      const id = decodeSegment(skillFileMatch[1]);
      if (!id || !SKILL_ID.test(id)) error(res, helpers, "Invalid skill identifier");
      else await skillFile(id, url, res);
      return true;
    }
    const skillEnabledMatch = path.match(/^\/server\/resources\/skills\/([^/]+)\/enabled$/);
    if (skillEnabledMatch && method === "PUT") {
      const id = decodeSegment(skillEnabledMatch[1]);
      if (!id || !SKILL_ID.test(id)) error(res, helpers, "Invalid skill identifier");
      else await setSkillEnabled(id, req, res);
      return true;
    }
    const skillDetailMatch = path.match(/^\/server\/resources\/skills\/([^/]+)$/);
    if (skillDetailMatch && method === "GET") {
      const id = decodeSegment(skillDetailMatch[1]);
      if (!id || !SKILL_ID.test(id)) error(res, helpers, "Invalid skill identifier");
      else await skillDetail(id, url, res);
      return true;
    }

    const extensionEnabledMatch = path.match(/^\/server\/resources\/extensions\/([^/]+)\/enabled$/);
    if (extensionEnabledMatch && method === "PUT") {
      const id = decodeSegment(extensionEnabledMatch[1]);
      if (!id || !EXTENSION_ID.test(id)) {
        error(res, helpers, "Invalid extension identifier");
      } else {
        await setExtensionEnabled(id, req, res);
      }
      return true;
    }
    const extensionDetailMatch = path.match(/^\/server\/resources\/extensions\/([^/]+)$/);
    if (extensionDetailMatch && method === "GET") {
      const id = decodeSegment(extensionDetailMatch[1]);
      if (!id || !EXTENSION_ID.test(id)) {
        error(res, helpers, "Invalid extension identifier");
      } else {
        await extensionDetail(id, url, res);
      }
      return true;
    }

    return false;
  };
}

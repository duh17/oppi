import type { IncomingMessage, ServerResponse } from "node:http";

import {
  ServerResourceNotFoundError,
  ServerResourceServiceError,
  ServerResourceValidationError,
} from "../server-resource-service.js";
import { createLogger } from "../logger.js";
import type { OppiApprovalPolicy } from "../oppi-extension-settings.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const MAX_REQUEST_BODY_BYTES = 16 * 1024;
const MAX_CAUSAL_MESSAGE_CHARS = 512;
const SKILL_ID = /^skill_[a-f0-9]{64}$/;
const EXTENSION_ID = /^extension_[a-f0-9]{64}$/;
const log = createLogger({ base: { component: "route_server_resources" } });

type ResourceOperation = "catalog" | "detail" | "file" | "mutation" | "oppi_persistence";
type ResourceKind = "skill" | "extension" | "oppi_configuration";
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

function isApprovalPolicy(value: unknown): value is OppiApprovalPolicy {
  return (
    value === "confirmDestructiveOnly" || value === "confirmAllChanges" || value === "readOnly"
  );
}

function isOptionalBoolean(value: unknown): value is boolean | undefined {
  return value === undefined || typeof value === "boolean";
}

function isBaseRevision(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function errorForResource(
  res: ServerResponse,
  helpers: RouteHelpers,
  resource: "Skill" | "Extension",
  operation: ResourceOperation,
  cause: unknown,
): void {
  const resourceKind = resource.toLowerCase() as Extract<ResourceKind, "skill" | "extension">;
  if (cause instanceof ServerResourceNotFoundError) {
    logRouteRejected(operation, resourceKind, "not_found");
    helpers.error(res, 404, `${resource} not found`);
    return;
  }
  if (cause instanceof ServerResourceValidationError) {
    logRouteRejected(operation, resourceKind, "validation");
    helpers.error(res, 400, cause.message);
    return;
  }

  logRouteFailure(operation, resourceKind, cause);
  const action = operation === "mutation" ? "update" : "load";
  if (cause instanceof ServerResourceServiceError) {
    helpers.error(res, 500, `Unable to ${action} server ${resource.toLowerCase()}s`);
    return;
  }
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
  if (cause instanceof ServerResourceNotFoundError) return ERROR_DIAGNOSTICS.not_found;

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

  async function listExtensions(url: URL, res: ServerResponse): Promise<void> {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    try {
      helpers.json(res, await ctx.serverResources.listExtensions());
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
    if (id === "oppi") {
      error(res, helpers, "The built-in Oppi extension uses its configuration endpoint");
      return;
    }
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
      const summary = await ctx.serverResources.setExtensionEnabled(id, body.enabled);
      try {
        await ctx.refreshModelCatalog({ force: true });
      } catch (refreshError: unknown) {
        log.warn("server_resources.extension_catalog_refresh_failed", {
          extensionId: id,
          error: refreshError instanceof Error ? refreshError.message : String(refreshError),
        });
      }
      helpers.json(res, summary);
    } catch (cause: unknown) {
      errorForResource(res, helpers, "Extension", "mutation", cause);
    }
  }

  function getOppiConfiguration(url: URL, res: ServerResponse): void {
    if (!hasNoQuery(url)) {
      error(res, helpers, "This server-global route does not accept query parameters");
      return;
    }
    helpers.json(res, ctx.storage.getOppiExtensionSettings());
  }

  async function replaceOppiConfiguration(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let body: Record<string, unknown> | undefined;
    try {
      if (acceptsJson(req)) {
        const parsed = await helpers.parseBody<unknown>(req, { maxBytes: MAX_REQUEST_BODY_BYTES });
        if (
          isRecord(parsed) &&
          (hasExactKeys(parsed, ["enabled", "approvalPolicy", "baseRevision"]) ||
            hasExactKeys(parsed, [
              "enabled",
              "approvalPolicy",
              "baseRevision",
              "mobileOutputGuideEnabled",
            ]))
        ) {
          body = parsed;
        }
      }
    } catch {
      logRouteRejected("oppi_persistence", "oppi_configuration", "validation");
      error(res, helpers, "Request body must be valid JSON within 16 KiB");
      return;
    }
    if (
      !body ||
      typeof body.enabled !== "boolean" ||
      !isApprovalPolicy(body.approvalPolicy) ||
      !isBaseRevision(body.baseRevision) ||
      !isOptionalBoolean(body.mobileOutputGuideEnabled)
    ) {
      logRouteRejected("oppi_persistence", "oppi_configuration", "validation");
      error(
        res,
        helpers,
        "Request body must include enabled, approvalPolicy, and a non-negative baseRevision",
      );
      return;
    }

    try {
      const result = ctx.storage.replaceOppiExtensionSettings(body.baseRevision, {
        enabled: body.enabled,
        approvalPolicy: body.approvalPolicy,
        ...(body.mobileOutputGuideEnabled !== undefined
          ? { mobileOutputGuideEnabled: body.mobileOutputGuideEnabled }
          : {}),
      });
      if (!result.ok) {
        logRouteRejected("oppi_persistence", "oppi_configuration", "conflict");
        helpers.json(
          res,
          {
            error: "Oppi extension configuration changed",
            code: "revision_conflict",
            current: result.current,
          },
          409,
        );
        return;
      }
      helpers.json(res, result.current);
    } catch (cause: unknown) {
      logRouteFailure("oppi_persistence", "oppi_configuration", cause);
      helpers.error(res, 500, "Unable to update Oppi extension configuration");
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
    if (path === "/server/extensions/oppi/config") {
      if (method === "GET") getOppiConfiguration(url, res);
      else if (method === "PUT") await replaceOppiConfiguration(req, res);
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
      if (!id || (id !== "oppi" && !EXTENSION_ID.test(id))) {
        error(res, helpers, "Invalid extension identifier");
      } else {
        await setExtensionEnabled(id, req, res);
      }
      return true;
    }
    const extensionDetailMatch = path.match(/^\/server\/resources\/extensions\/([^/]+)$/);
    if (extensionDetailMatch && method === "GET") {
      const id = decodeSegment(extensionDetailMatch[1]);
      if (!id || (id !== "oppi" && !EXTENSION_ID.test(id))) {
        error(res, helpers, "Invalid extension identifier");
      } else {
        await extensionDetail(id, url, res);
      }
      return true;
    }

    return false;
  };
}

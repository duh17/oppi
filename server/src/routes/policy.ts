import type { IncomingMessage, ServerResponse } from "node:http";

import { defaultPolicy } from "../policy-presets.js";
import type { Rule, RuleInput } from "../rules.js";
import type { AuditEntry } from "../audit.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createPolicyRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function isRuleVisibleToUser(rule: Rule): boolean {
    switch (rule.scope) {
      case "session":
        return rule.sessionId ? Boolean(ctx.storage.getSession(rule.sessionId)) : false;
      case "workspace":
        return rule.workspaceId ? Boolean(ctx.storage.getWorkspace(rule.workspaceId)) : false;
      case "global":
        return true; // single-owner: all rules are visible
      default:
        return false;
    }
  }

  function sessionBelongsToWorkspace(sessionId: string | undefined, workspaceId: string): boolean {
    if (!sessionId) return false;
    const session = ctx.storage.getSession(sessionId);
    return session?.workspaceId === workspaceId;
  }

  function handleGetPolicyFallback(res: ServerResponse): void {
    helpers.json(res, { fallback: ctx.gate.getDefaultFallback() });
  }

  async function handlePatchPolicyFallback(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<Record<string, unknown>>(req);
    const rawFallback = body.fallback;

    const normalizedFallback =
      rawFallback === "block" || rawFallback === "deny" || rawFallback === "denied"
        ? "deny"
        : rawFallback === "allow" || rawFallback === "ask"
          ? rawFallback
          : null;

    if (!normalizedFallback) {
      helpers.error(res, 400, 'fallback must be one of "allow", "ask", "deny"');
      return;
    }

    const persistedFallback: "allow" | "ask" | "block" =
      normalizedFallback === "deny" ? "block" : normalizedFallback;

    const currentConfig = ctx.storage.getConfig();
    const nextPolicy = {
      ...(currentConfig.policy || defaultPolicy()),
      fallback: persistedFallback,
    };

    ctx.storage.updateConfig({ policy: nextPolicy });
    ctx.gate.setDefaultFallback(normalizedFallback);

    helpers.json(res, { fallback: normalizedFallback });
  }

  function handleGetPolicyRules(url: URL, res: ServerResponse): void {
    const workspaceId = url.searchParams.get("workspaceId") || undefined;
    if (workspaceId) {
      const workspace = ctx.storage.getWorkspace(workspaceId);
      if (!workspace) {
        helpers.error(res, 404, "Workspace not found");
        return;
      }
    }

    const scope = url.searchParams.get("scope") || undefined;
    if (scope && scope !== "session" && scope !== "workspace" && scope !== "global") {
      helpers.error(res, 400, 'scope must be one of: "session", "workspace", "global"');
      return;
    }

    let rules = ctx.gate.ruleStore.getAll().filter((rule) => isRuleVisibleToUser(rule));

    if (workspaceId) {
      rules = rules.filter((rule) => {
        if (rule.scope === "global") return true;
        if (rule.scope === "workspace") return rule.workspaceId === workspaceId;
        if (rule.scope === "session") {
          return sessionBelongsToWorkspace(rule.sessionId, workspaceId);
        }
        return false;
      });
    }

    if (scope) {
      rules = rules.filter((rule) => rule.scope === scope);
    }

    rules.sort((a, b) => b.createdAt - a.createdAt);

    helpers.json(res, { rules });
  }

  async function handleCreatePolicyRule(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<Record<string, unknown>>(req);

    const rawDecision = body.decision;
    const decision =
      rawDecision === "block"
        ? "deny"
        : rawDecision === "allow" || rawDecision === "ask" || rawDecision === "deny"
          ? rawDecision
          : null;
    if (!decision) {
      helpers.error(res, 400, 'decision must be one of "allow", "ask", "deny"');
      return;
    }

    const rawScope = typeof body.scope === "string" ? body.scope : "global";
    if (rawScope !== "session" && rawScope !== "workspace" && rawScope !== "global") {
      helpers.error(res, 400, 'scope must be one of: "session", "workspace", "global"');
      return;
    }

    const input: RuleInput = {
      decision,
      scope: rawScope,
      source: "manual",
    };

    if (typeof body.tool === "string") {
      const trimmed = body.tool.trim();
      if (!trimmed) {
        helpers.error(res, 400, "tool cannot be empty");
        return;
      }
      input.tool = trimmed;
    }

    if (typeof body.pattern === "string") {
      const trimmed = body.pattern.trim();
      if (trimmed.length > 0) {
        input.pattern = trimmed;
      }
    }

    if (typeof body.executable === "string") {
      const trimmed = body.executable.trim();
      if (trimmed.length > 0) {
        input.executable = trimmed;
      }
    }

    if (typeof body.label === "string") {
      const trimmed = body.label.trim();
      if (trimmed.length > 0) {
        input.label = trimmed;
      }
    }

    if (body.expiresAt !== undefined) {
      if (typeof body.expiresAt !== "number" || !Number.isFinite(body.expiresAt)) {
        helpers.error(res, 400, "expiresAt must be a number");
        return;
      }
      const expiresAt = Math.trunc(body.expiresAt);
      if (expiresAt <= 0) {
        helpers.error(res, 400, "expiresAt must be a positive timestamp");
        return;
      }
      input.expiresAt = expiresAt;
    }

    if (typeof body.source === "string") {
      if (body.source !== "preset" && body.source !== "learned" && body.source !== "manual") {
        helpers.error(res, 400, 'source must be one of: "preset", "learned", "manual"');
        return;
      }
      input.source = body.source;
    }

    if (rawScope === "workspace") {
      if (typeof body.workspaceId !== "string" || body.workspaceId.trim().length === 0) {
        helpers.error(res, 400, "workspaceId is required for workspace scope");
        return;
      }
      const workspaceId = body.workspaceId.trim();
      if (!ctx.storage.getWorkspace(workspaceId)) {
        helpers.error(res, 404, "Workspace not found");
        return;
      }
      input.workspaceId = workspaceId;
    }

    if (rawScope === "session") {
      if (typeof body.sessionId !== "string" || body.sessionId.trim().length === 0) {
        helpers.error(res, 400, "sessionId is required for session scope");
        return;
      }
      const sessionId = body.sessionId.trim();
      if (!ctx.storage.getSession(sessionId)) {
        helpers.error(res, 404, "Session not found");
        return;
      }
      input.sessionId = sessionId;
    }

    const tool =
      typeof input.tool === "string" && input.tool.trim().length > 0 ? input.tool.trim() : "*";
    if (tool === "*" && !input.pattern && !input.executable) {
      helpers.error(res, 400, "rule must specify tool, pattern, or executable");
      return;
    }

    let rule: Rule;
    try {
      rule = ctx.gate.ruleStore.add(input);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to create rule";
      helpers.error(res, 400, message);
      return;
    }

    helpers.json(res, { rule }, 201);
  }

  async function handlePatchPolicyRule(
    path: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const ruleId = decodeURIComponent(path.split("/").pop() || "");
    if (!ruleId) {
      helpers.error(res, 400, "Missing rule ID");
      return;
    }

    const allRules = ctx.gate.ruleStore.getAll();
    const existing = allRules.find((r) => r.id === ruleId);
    if (!existing || !isRuleVisibleToUser(existing)) {
      helpers.error(res, 404, "Rule not found");
      return;
    }

    const body = await helpers.parseBody<Record<string, unknown>>(req);
    const hasField = (key: string): boolean => Object.prototype.hasOwnProperty.call(body, key);

    const hasPatchField =
      hasField("decision") ||
      hasField("label") ||
      hasField("tool") ||
      hasField("pattern") ||
      hasField("executable") ||
      hasField("expiresAt");

    if (!hasPatchField) {
      helpers.error(res, 400, "At least one patch field is required");
      return;
    }

    const updates: {
      decision?: "allow" | "ask" | "deny";
      tool?: string | null;
      pattern?: string | null;
      executable?: string | null;
      label?: string | null;
      expiresAt?: number | null;
    } = {};

    if (hasField("decision")) {
      const rawDecision = body.decision;
      const normalized =
        rawDecision === "block"
          ? "deny"
          : rawDecision === "allow" || rawDecision === "ask" || rawDecision === "deny"
            ? rawDecision
            : null;
      if (!normalized) {
        helpers.error(res, 400, 'decision must be one of "allow", "ask", "deny"');
        return;
      }
      updates.decision = normalized;
    }

    if (hasField("label")) {
      if (body.label === null) {
        updates.label = null;
      } else if (typeof body.label === "string") {
        const trimmed = body.label.trim();
        updates.label = trimmed.length > 0 ? trimmed : null;
      } else {
        helpers.error(res, 400, "label must be a string or null");
        return;
      }
    }

    if (hasField("tool")) {
      if (body.tool === null) {
        updates.tool = null;
      } else if (typeof body.tool === "string") {
        const trimmed = body.tool.trim();
        if (!trimmed) {
          helpers.error(res, 400, "tool cannot be empty");
          return;
        }
        updates.tool = trimmed;
      } else {
        helpers.error(res, 400, "tool must be a string or null");
        return;
      }
    }

    if (hasField("pattern")) {
      if (body.pattern === null) {
        updates.pattern = null;
      } else if (typeof body.pattern === "string") {
        const trimmed = body.pattern.trim();
        updates.pattern = trimmed.length > 0 ? trimmed : null;
      } else {
        helpers.error(res, 400, "pattern must be a string or null");
        return;
      }
    }

    if (hasField("executable")) {
      if (body.executable === null) {
        updates.executable = null;
      } else if (typeof body.executable === "string") {
        const trimmed = body.executable.trim();
        updates.executable = trimmed.length > 0 ? trimmed : null;
      } else {
        helpers.error(res, 400, "executable must be a string or null");
        return;
      }
    }

    if (hasField("expiresAt")) {
      if (body.expiresAt === null) {
        updates.expiresAt = null;
      } else if (typeof body.expiresAt === "number" && Number.isFinite(body.expiresAt)) {
        const timestamp = Math.trunc(body.expiresAt);
        if (timestamp <= 0) {
          helpers.error(res, 400, "expiresAt must be a positive timestamp or null");
          return;
        }
        updates.expiresAt = timestamp;
      } else {
        helpers.error(res, 400, "expiresAt must be a number or null");
        return;
      }
    }

    let updated: Rule | null;
    try {
      updated = ctx.gate.ruleStore.update(ruleId, updates);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to update rule";
      helpers.error(res, 400, message);
      return;
    }

    if (!updated) {
      helpers.error(res, 500, "Failed to update rule");
      return;
    }

    if (!updated.tool || updated.tool.trim().length === 0) {
      helpers.error(res, 400, "rule.tool cannot be empty");
      return;
    }

    console.log(`[policy] Rule ${ruleId} updated: ${updated.label || "(no label)"}`);
    helpers.json(res, { rule: updated });
  }

  function handleDeletePolicyRule(path: string, res: ServerResponse): void {
    const ruleId = decodeURIComponent(path.split("/").pop() || "");
    if (!ruleId) {
      helpers.error(res, 400, "Missing rule ID");
      return;
    }

    // Verify rule exists and belongs to this user
    const allRules = ctx.gate.ruleStore.getAll();
    const rule = allRules.find((r) => r.id === ruleId);
    if (!rule) {
      helpers.error(res, 404, "Rule not found");
      return;
    }

    if (!isRuleVisibleToUser(rule)) {
      helpers.error(res, 404, "Rule not found");
      return;
    }

    const removed = ctx.gate.ruleStore.remove(ruleId);
    if (!removed) {
      helpers.error(res, 500, "Failed to remove rule");
      return;
    }

    console.log(`[policy] Rule ${ruleId} deleted: ${rule.label || "(no label)"}`);
    helpers.json(res, { ok: true, deleted: ruleId });
  }

  function handleGetPolicyAudit(url: URL, res: ServerResponse): void {
    const sessionId = url.searchParams.get("sessionId") || undefined;
    const workspaceId = url.searchParams.get("workspaceId") || undefined;

    if (sessionId) {
      const session = ctx.storage.getSession(sessionId);
      if (!session) {
        helpers.error(res, 404, "Session not found");
        return;
      }
    }

    if (workspaceId) {
      const workspace = ctx.storage.getWorkspace(workspaceId);
      if (!workspace) {
        helpers.error(res, 404, "Workspace not found");
        return;
      }
    }

    const limitParam = url.searchParams.get("limit");
    const beforeParam = url.searchParams.get("before");

    let limit = 50;
    if (limitParam !== null) {
      const parsedLimit = Number.parseInt(limitParam, 10);
      if (!Number.isFinite(parsedLimit) || parsedLimit <= 0 || parsedLimit > 500) {
        helpers.error(res, 400, "limit must be an integer between 1 and 500");
        return;
      }
      limit = parsedLimit;
    }

    let before: number | undefined;
    if (beforeParam !== null) {
      const parsedBefore = Number.parseInt(beforeParam, 10);
      if (!Number.isFinite(parsedBefore) || parsedBefore <= 0) {
        helpers.error(res, 400, "before must be a positive integer timestamp");
        return;
      }
      before = parsedBefore;
    }

    const entries: AuditEntry[] = ctx.gate.auditLog.query({
      limit,
      before,
      sessionId,
      workspaceId,
    });

    helpers.json(res, { entries });
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/policy/fallback" && method === "GET") {
      handleGetPolicyFallback(res);
      return true;
    }

    if (path === "/policy/fallback" && method === "PATCH") {
      await handlePatchPolicyFallback(req, res);
      return true;
    }

    if (path === "/policy/rules" && method === "GET") {
      handleGetPolicyRules(url, res);
      return true;
    }

    if (path === "/policy/rules" && method === "POST") {
      await handleCreatePolicyRule(req, res);
      return true;
    }

    if (path.startsWith("/policy/rules/") && method === "PATCH") {
      await handlePatchPolicyRule(path, req, res);
      return true;
    }

    if (path.startsWith("/policy/rules/") && method === "DELETE") {
      handleDeletePolicyRule(path, res);
      return true;
    }

    if (path === "/policy/audit" && method === "GET") {
      handleGetPolicyAudit(url, res);
      return true;
    }

    return false;
  };
}

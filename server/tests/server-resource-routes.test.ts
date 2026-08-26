import type { IncomingMessage } from "node:http";

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ServerResourceNotFoundError,
  ServerResourceValidationError,
} from "../src/server-resource-service.js";
import { RouteHandler } from "../src/routes/index.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const FILE_REVISION = "a".repeat(64);

const skill = {
  id: "skill_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  name: "review",
  description: "Review changes",
  provenance: { kind: "piAgent" as const, label: "~/.pi/agent/skills" },
  path: "/agent/skills/review/SKILL.md",
  state: "enabled" as const,
  warnings: [],
  editable: true,
};

const extension = {
  id: "extension_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  name: "review-tools",
  kind: "file" as const,
  provenance: { kind: "piAgent" as const, label: "~/.pi/agent/extensions" },
  path: "/agent/extensions/review-tools.ts",
  state: "on" as const,
  warnings: [],
  isRemovable: false as const,
};

function jsonRequest(body: unknown, contentType = "application/json"): IncomingMessage {
  const request = makeRequest(body);
  request.headers = { "content-type": contentType };
  return request;
}

function makeRoutes() {
  const serverResources = {
    listSkills: vi.fn(async () => ({ skills: [skill] })),
    getSkillDetail: vi.fn(async () => ({
      summary: skill,
      skillMarkdown: "# Review",
      files: ["SKILL.md", "notes.md"],
    })),
    readSkillFile: vi.fn(async () => "notes"),
    readSkillFileSnapshot: vi.fn(async () => ({ content: "notes", revision: FILE_REVISION })),
    setSkillEnabled: vi.fn(async () => ({ ...skill, state: "disabled" as const })),
    listExtensions: vi.fn(async () => ({ extensions: [extension], builtInTools: [] })),
    getExtensionDetail: vi.fn(async () => ({ summary: extension })),
    inspectAgentExtensionTools: vi.fn(async () => ({
      summary: extension,
      contributedTools: ["review"],
    })),
    setExtensionEnabled: vi.fn(async () => ({ ...extension, state: "off" as const })),
    getPiSystemPrompt: vi.fn(async () => ({
      source: "default" as const,
      path: "~/.pi/agent/SYSTEM.md",
      content: "You are an expert coding assistant operating inside pi",
    })),
    getPiDefaultTools: vi.fn(async () => ({ defaultTools: null })),
    setPiDefaultTools: vi.fn(async (defaultTools: string[] | null) => ({ defaultTools })),
  };
  const refreshModelCatalog = vi.fn(async () => undefined);
  const storage = {
    getMobileOutputGuideSettings: vi.fn(() => ({ enabled: false, revision: 0 })),
    replaceMobileOutputGuideSettings: vi.fn(() => ({
      ok: true as const,
      current: { enabled: true, revision: 1 },
    })),
  };
  return {
    routes: new RouteHandler({
      serverResources,
      storage,
      refreshModelCatalog,
    } as unknown as RouteContext),
    serverResources,
    storage,
    refreshModelCatalog,
  };
}

async function dispatch(
  routes: RouteHandler,
  method: string,
  path: string,
  request: IncomingMessage = {} as IncomingMessage,
) {
  const response = makeResponse();
  const url = new URL(`http://localhost${path}`);
  await routes.dispatch(method, url.pathname, url, request, response as never);
  return response;
}

describe("server resource routes", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("emits bounded causal logs while preserving resource error responses", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
    const { routes, serverResources, storage } = makeRoutes();
    const sensitiveContext = "/private/oppi/secret-token/settings.json Bearer sk_live_12345678";

    serverResources.listSkills.mockRejectedValueOnce(
      new Error(`EACCES: permission denied, open '${sensitiveContext}'`),
    );
    serverResources.getSkillDetail.mockRejectedValueOnce(
      new Error(`Pi settings load failed: malformed JSON at ${sensitiveContext}`),
    );
    serverResources.readSkillFileSnapshot.mockRejectedValueOnce(
      new Error(`Failed to load enabled Pi extensions from ${sensitiveContext}`),
    );
    serverResources.setExtensionEnabled.mockRejectedValueOnce(
      new Error(`write failed for ${sensitiveContext}`),
    );
    storage.replaceMobileOutputGuideSettings.mockImplementationOnce(() => {
      throw new Error(`fsync failed for ${sensitiveContext}`);
    });
    storage.replaceMobileOutputGuideSettings.mockImplementationOnce(() => {
      throw new Error(`rename failed for ${sensitiveContext}`);
    });
    storage.replaceMobileOutputGuideSettings.mockReturnValueOnce({
      ok: false,
      reason: "revision_conflict",
      current: { enabled: false, revision: 2 },
    });
    serverResources.getExtensionDetail.mockRejectedValueOnce(
      new ServerResourceNotFoundError("extension"),
    );

    expect((await dispatch(routes, "GET", "/server/resources/skills")).statusCode).toBe(500);
    expect((await dispatch(routes, "GET", `/server/resources/skills/${skill.id}`)).statusCode).toBe(
      500,
    );
    expect(
      (await dispatch(routes, "GET", `/server/resources/skills/${skill.id}/file?path=notes.md`))
        .statusCode,
    ).toBe(500);
    expect(
      (
        await dispatch(
          routes,
          "PUT",
          `/server/resources/extensions/${extension.id}/enabled`,
          jsonRequest({ enabled: false }),
        )
      ).statusCode,
    ).toBe(500);
    expect(
      (
        await dispatch(
          routes,
          "PUT",
          "/server/mobile-output-guide",
          jsonRequest({ enabled: true, baseRevision: 0 }),
        )
      ).statusCode,
    ).toBe(500);
    expect(
      (
        await dispatch(
          routes,
          "PUT",
          "/server/mobile-output-guide",
          jsonRequest({ enabled: true, baseRevision: 0 }),
        )
      ).statusCode,
    ).toBe(500);
    expect(
      (
        await dispatch(
          routes,
          "PUT",
          "/server/mobile-output-guide",
          jsonRequest({ enabled: true, baseRevision: 0 }),
        )
      ).statusCode,
    ).toBe(409);
    expect(
      (await dispatch(routes, "GET", `/server/resources/extensions/${extension.id}`)).statusCode,
    ).toBe(404);
    expect(
      (
        await dispatch(
          routes,
          "PUT",
          `/server/resources/skills/${skill.id}/enabled`,
          jsonRequest({ enabled: "not-a-boolean" }),
        )
      ).statusCode,
    ).toBe(400);

    const logs = stderr.mock.calls.map(([chunk]) => {
      const entry = JSON.parse(String(chunk)) as Record<string, unknown>;
      delete entry.ts;
      return entry;
    });
    const expectedLogs = [
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "catalog",
        resourceKind: "skill",
        category: "permission_denied",
        message: "filesystem access denied",
      },
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "detail",
        resourceKind: "skill",
        category: "malformed_settings",
        message: "Pi settings are malformed",
      },
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "file",
        resourceKind: "skill",
        category: "loader",
        message: "Pi resource loader failed",
      },
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "mutation",
        resourceKind: "extension",
        category: "write_failed",
        message: "settings write failed",
      },
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "guide_persistence",
        resourceKind: "mobile_output_guide",
        category: "fsync_failed",
        message: "settings fsync failed",
      },
      {
        level: "error",
        event: "server_resources.route_failed",
        component: "route_server_resources",
        operation: "guide_persistence",
        resourceKind: "mobile_output_guide",
        category: "rename_failed",
        message: "settings rename failed",
      },
      {
        level: "info",
        event: "server_resources.route_rejected",
        component: "route_server_resources",
        operation: "guide_persistence",
        resourceKind: "mobile_output_guide",
        category: "conflict",
        message: "settings revision conflict",
      },
      {
        level: "info",
        event: "server_resources.route_rejected",
        component: "route_server_resources",
        operation: "detail",
        resourceKind: "extension",
        category: "not_found",
        message: "resource was not found",
      },
      {
        level: "info",
        event: "server_resources.route_rejected",
        component: "route_server_resources",
        operation: "mutation",
        resourceKind: "skill",
        category: "validation",
        message: "request body validation failed",
      },
    ];
    const configuredLevel = process.env.OPPI_LOG_LEVEL?.trim().toLowerCase();
    const visibleLogs =
      configuredLevel === "warn" || configuredLevel === "error"
        ? expectedLogs.filter((entry) => entry.level === "error")
        : expectedLogs;
    expect(logs).toEqual(visibleLogs);

    const rawLogs = stderr.mock.calls.map(([chunk]) => String(chunk)).join("\n");
    expect(rawLogs).not.toContain(sensitiveContext);
    expect(rawLogs).not.toContain(skill.id);
    expect(rawLogs).not.toContain(extension.id);
  });

  it("serves global skill catalogs, details, files, and authoritative mutations", async () => {
    const { routes, serverResources } = makeRoutes();

    const list = await dispatch(routes, "GET", "/server/resources/skills");
    expect(list.statusCode).toBe(200);
    expect(JSON.parse(list.body)).toEqual({ skills: [skill] });

    const detail = await dispatch(routes, "GET", `/server/resources/skills/${skill.id}`);
    expect(detail.statusCode).toBe(200);
    expect(JSON.parse(detail.body)).toMatchObject({
      summary: skill,
      files: ["SKILL.md", "notes.md"],
    });

    const file = await dispatch(
      routes,
      "GET",
      `/server/resources/skills/${skill.id}/file?path=notes.md`,
    );
    expect(file.statusCode).toBe(200);
    expect(JSON.parse(file.body)).toEqual({ content: "notes", revision: FILE_REVISION });

    const filePut = await dispatch(
      routes,
      "PUT",
      `/server/resources/skills/${skill.id}/file?path=notes.md`,
      jsonRequest({ content: "updated", baseRevision: FILE_REVISION }),
    );
    expect(filePut.statusCode).toBe(404);

    const enabled = await dispatch(
      routes,
      "PUT",
      `/server/resources/skills/${skill.id}/enabled`,
      jsonRequest({ enabled: false }),
    );
    expect(enabled.statusCode).toBe(200);
    expect(JSON.parse(enabled.body)).toEqual({ ...skill, state: "disabled" });
    expect(serverResources.setSkillEnabled).toHaveBeenCalledWith(skill.id, false);
  });

  it("serves and mutates only discovered Pi extensions", async () => {
    const { routes, serverResources, refreshModelCatalog } = makeRoutes();

    const list = await dispatch(routes, "GET", "/server/resources/extensions");
    expect(list.statusCode).toBe(200);
    expect(JSON.parse(list.body)).toEqual({ extensions: [extension], builtInTools: [] });

    const detail = await dispatch(routes, "GET", `/server/resources/extensions/${extension.id}`);
    expect(detail.statusCode).toBe(200);
    expect(JSON.parse(detail.body)).toEqual({ summary: extension });

    const enabled = await dispatch(
      routes,
      "PUT",
      `/server/resources/extensions/${extension.id}/enabled`,
      jsonRequest({ enabled: false }),
    );
    expect(enabled.statusCode).toBe(200);
    expect(serverResources.setExtensionEnabled).toHaveBeenCalledWith(extension.id, false);
    expect(refreshModelCatalog).toHaveBeenCalledWith({ force: true });

    expect((await dispatch(routes, "GET", "/server/resources/extensions/oppi")).statusCode).toBe(
      400,
    );
  });

  it("gets and CAS-replaces the Mobile Output Guide setting", async () => {
    const { routes, storage } = makeRoutes();

    const get = await dispatch(routes, "GET", "/server/mobile-output-guide");
    expect(get.statusCode).toBe(200);
    expect(JSON.parse(get.body)).toEqual({ enabled: false, revision: 0 });

    const put = await dispatch(
      routes,
      "PUT",
      "/server/mobile-output-guide",
      jsonRequest({ enabled: true, baseRevision: 0 }),
    );
    expect(put.statusCode).toBe(200);
    expect(JSON.parse(put.body)).toEqual({ enabled: true, revision: 1 });
    expect(storage.replaceMobileOutputGuideSettings).toHaveBeenCalledWith(0, { enabled: true });

    storage.replaceMobileOutputGuideSettings.mockReturnValueOnce({
      ok: false,
      reason: "revision_conflict",
      current: { enabled: false, revision: 2 },
    });
    const conflict = await dispatch(
      routes,
      "PUT",
      "/server/mobile-output-guide",
      jsonRequest({ enabled: false, baseRevision: 1 }),
    );
    expect(conflict.statusCode).toBe(409);
    expect(JSON.parse(conflict.body)).toEqual({
      error: "Mobile Output Guide setting changed",
      code: "revision_conflict",
      current: { enabled: false, revision: 2 },
    });
  });

  it("rejects cwd, malformed paths, unknown queries, invalid bodies, and wrong content types", async () => {
    const { routes, serverResources } = makeRoutes();
    serverResources.getSkillDetail.mockRejectedValueOnce(new ServerResourceNotFoundError("skill"));

    const cases: Array<{ method: string; path: string; request?: IncomingMessage }> = [
      { method: "GET", path: "/server/resources/skills?cwd=%2Fworkspace" },
      { method: "GET", path: "/server/resources/skills?unexpected=1" },
      { method: "GET", path: "/server/resources/skills/not-an-id" },
      { method: "GET", path: "/server/resources/skills/%E0%A4%A" },
      { method: "GET", path: `/server/resources/skills/${skill.id}/file` },
      { method: "GET", path: `/server/resources/skills/${skill.id}/file?path=one&path=two` },
      {
        method: "PUT",
        path: `/server/resources/skills/${skill.id}/enabled`,
        request: jsonRequest({ enabled: true }, "text/plain"),
      },
      {
        method: "PUT",
        path: `/server/resources/skills/${skill.id}/enabled`,
        request: jsonRequest({ enabled: true, extra: true }),
      },
      {
        method: "PUT",
        path: "/server/mobile-output-guide",
        request: jsonRequest({ enabled: true, approvalPolicy: "wrong", baseRevision: 0 }),
      },
    ];

    for (const testCase of cases) {
      const response = await dispatch(routes, testCase.method, testCase.path, testCase.request);
      expect(response.statusCode, `${testCase.method} ${testCase.path}`).toBe(400);
      expect(JSON.parse(response.body).error).toBeTypeOf("string");
    }

    const missing = await dispatch(routes, "GET", `/server/resources/skills/${skill.id}`);
    expect(missing.statusCode).toBe(404);
    expect(JSON.parse(missing.body)).toEqual({ error: "Skill not found" });
  });

  it("gets Pi system prompt and defaultTools, and writes only defaultTools", async () => {
    const { routes, serverResources } = makeRoutes();

    const prompt = await dispatch(routes, "GET", "/server/resources/pi/system-prompt");
    expect(prompt.statusCode).toBe(200);
    expect(JSON.parse(prompt.body)).toEqual({
      source: "default",
      path: "~/.pi/agent/SYSTEM.md",
      content: "You are an expert coding assistant operating inside pi",
    });

    const tools = await dispatch(routes, "GET", "/server/resources/pi/default-tools");
    expect(tools.statusCode).toBe(200);
    expect(JSON.parse(tools.body)).toEqual({ defaultTools: null });

    const put = await dispatch(
      routes,
      "PUT",
      "/server/resources/pi/default-tools",
      jsonRequest({ defaultTools: ["read", "grep"] }),
    );
    expect(put.statusCode).toBe(200);
    expect(JSON.parse(put.body)).toEqual({ defaultTools: ["read", "grep"] });
    expect(serverResources.setPiDefaultTools).toHaveBeenCalledWith(["read", "grep"]);

    const inherit = await dispatch(
      routes,
      "PUT",
      "/server/resources/pi/default-tools",
      jsonRequest({ defaultTools: null }),
    );
    expect(inherit.statusCode).toBe(200);
    expect(JSON.parse(inherit.body)).toEqual({ defaultTools: null });
    expect(serverResources.setPiDefaultTools).toHaveBeenCalledWith(null);

    const empty = await dispatch(
      routes,
      "PUT",
      "/server/resources/pi/default-tools",
      jsonRequest({ defaultTools: [] }),
    );
    expect(empty.statusCode).toBe(200);
    expect(JSON.parse(empty.body)).toEqual({ defaultTools: [] });
  });

  it("rejects invalid Pi defaultTools bodies and unexpected query parameters", async () => {
    const { routes } = makeRoutes();
    const cases: Array<{ method: string; path: string; request?: IncomingMessage }> = [
      { method: "GET", path: "/server/resources/pi/system-prompt?cwd=%2Fworkspace" },
      { method: "GET", path: "/server/resources/pi/default-tools?unexpected=1" },
      {
        method: "PUT",
        path: "/server/resources/pi/default-tools",
        request: jsonRequest({ defaultTools: ["read"], extra: true }),
      },
      {
        method: "PUT",
        path: "/server/resources/pi/default-tools",
        request: jsonRequest({ tools: ["read"] }),
      },
      {
        method: "PUT",
        path: "/server/resources/pi/default-tools",
        request: jsonRequest({ defaultTools: ["read"] }, "text/plain"),
      },
    ];

    for (const testCase of cases) {
      const response = await dispatch(routes, testCase.method, testCase.path, testCase.request);
      expect(response.statusCode, `${testCase.method} ${testCase.path}`).toBe(400);
      expect(JSON.parse(response.body).error).toBeTypeOf("string");
    }
  });

  it("does not handle similarly named or unsupported routes", async () => {
    const { routes } = makeRoutes();
    const unsupported = await dispatch(routes, "POST", "/server/resources/skills");
    const unrelated = await dispatch(routes, "GET", "/server/resources/skillz");

    expect(unsupported.statusCode).toBe(404);
    expect(unrelated.statusCode).toBe(404);
  });
});

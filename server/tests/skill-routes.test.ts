import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSkillRoutes } from "../src/routes/skills.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("skills module", () => {
  it("handles GET /skills in isolation", async () => {
    const ctx = {
      skillRegistry: {
        list: vi.fn(() => [{ name: "fetch", description: "Fetch URLs" }]),
      },
    } as unknown as RouteContext;

    const dispatch = createSkillRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/skills",
      url: new URL("http://localhost/skills"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);

    const body = JSON.parse(res.body) as { skills: unknown[] };
    expect(body.skills).toHaveLength(1);
  });

  it("returns 404 for unknown skill detail", async () => {
    const ctx = {
      skillRegistry: {
        getDetail: vi.fn(() => undefined),
      },
    } as unknown as RouteContext;

    const dispatch = createSkillRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/skills/nonexistent",
      url: new URL("http://localhost/skills/nonexistent"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Skill not found" });
  });

  it("validates path param on skill file access", async () => {
    const ctx = {
      skillRegistry: {},
    } as unknown as RouteContext;

    const dispatch = createSkillRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/skills/fetch/file",
      url: new URL("http://localhost/skills/fetch/file"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "path parameter required" });
  });

  it("returns 403 for skill mutation endpoints", async () => {
    const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "DELETE",
      path: "/me/skills/some-skill",
      url: new URL("http://localhost/me/skills/some-skill"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(403);
  });

  it("reports host path status", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-host-path-route-"));
    try {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/host/path/status",
        url: new URL(`http://localhost/host/path/status?path=${encodeURIComponent(root)}`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { status: { exists: boolean; isDirectory: boolean } };
      expect(body.status.exists).toBe(true);
      expect(body.status.isDirectory).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("creates host workspace directories only after confirmation", async () => {
    const root = join(homedir(), "workspace");
    const target = join(root, `oppi-host-create-route-${Date.now()}`);
    mkdirSync(root, { recursive: true });
    rmSync(target, { recursive: true, force: true });
    try {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
      const unconfirmed = makeResponse();

      await dispatch({
        method: "POST",
        path: "/host/path/create",
        url: new URL("http://localhost/host/path/create"),
        req: makeRequest({ path: target }) as never,
        res: unconfirmed as never,
      });

      expect(unconfirmed.statusCode).toBe(400);
      expect(existsSync(target)).toBe(false);

      const confirmed = makeResponse();
      const handled = await dispatch({
        method: "POST",
        path: "/host/path/create",
        url: new URL("http://localhost/host/path/create"),
        req: makeRequest({ path: target, confirmed: true }) as never,
        res: confirmed as never,
      });

      expect(handled).toBe(true);
      expect(confirmed.statusCode).toBe(201);
      expect(existsSync(target)).toBe(true);
    } finally {
      rmSync(target, { recursive: true, force: true });
    }
  });

  it("rejects host directory creation outside workspace roots", async () => {
    const target = join(tmpdir(), `oppi-host-create-denied-${Date.now()}`);
    rmSync(target, { recursive: true, force: true });
    try {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/host/path/create",
        url: new URL("http://localhost/host/path/create"),
        req: makeRequest({ path: target, confirmed: true }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(403);
      expect(existsSync(target)).toBe(false);
    } finally {
      rmSync(target, { recursive: true, force: true });
    }
  });

  it("returns host path completions", async () => {
    const root = join(homedir(), "workspace", `oppi-host-complete-route-${Date.now()}`);
    const child = join(root, "project-alpha");
    rmSync(root, { recursive: true, force: true });
    mkdirSync(child, { recursive: true });
    try {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
      const res = makeResponse();
      const prefix = join(root, "project-a");

      const handled = await dispatch({
        method: "GET",
        path: "/host/path/completions",
        url: new URL(`http://localhost/host/path/completions?prefix=${encodeURIComponent(prefix)}`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { completions: Array<{ path: string }> };
      expect(body.completions.map((item) => item.path)).toContain(child.replace(homedir(), "~"));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/other/path",
      url: new URL("http://localhost/other/path"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});

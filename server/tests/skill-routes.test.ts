import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
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

  it("lists cwd-local Pi skills", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-skill-route-cwd-"));
    const skillDir = join(cwd, ".pi", "skills", "cwd-route-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: cwd-route-skill",
        "description: Cwd-local skill for route tests.",
        "---",
        "Use this cwd-local skill.",
      ].join("\n"),
    );

    try {
      const ctx = { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext;
      const dispatch = createSkillRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL(`http://localhost/skills?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { skills: Array<{ name: string }> };
      expect(body.skills.map((skill) => skill.name)).toContain("cwd-route-skill");
      expect(ctx.skillRegistry.list).not.toHaveBeenCalled();
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("writes project Pi settings when toggling cwd-local skills", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-skill-route-toggle-"));
    const skillDir = join(cwd, ".pi", "skills", "toggle-route-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: toggle-route-skill",
        "description: Toggle skill for route tests.",
        "---",
        "Use this toggle skill.",
      ].join("\n"),
    );

    try {
      const ctx = { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext;
      const dispatch = createSkillRoutes(ctx, createRouteHelpers());
      const disableRes = makeResponse();

      const disabled = await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "skills",
          path: join(skillDir, "SKILL.md"),
          enabled: false,
        }) as never,
        res: disableRes as never,
      });

      expect(disabled).toBe(true);
      expect(disableRes.statusCode).toBe(200);
      const settings = JSON.parse(readFileSync(join(cwd, ".pi", "settings.json"), "utf-8")) as {
        skills?: string[];
      };
      expect(settings.skills).toContain("-skills/toggle-route-skill/SKILL.md");

      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL(`http://localhost/skills?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: listRes as never,
      });
      const body = JSON.parse(listRes.body) as {
        skills: Array<{ name: string; enabled: boolean }>;
      };
      expect(body.skills.find((skill) => skill.name === "toggle-route-skill")?.enabled).toBe(false);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("accepts the skill path returned to clients when toggling Pi settings", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-skill-route-client-toggle-"));
    const skillDir = join(cwd, ".pi", "skills", "client-toggle-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: client-toggle-skill",
        "description: Skill path returned by the client catalog.",
        "---",
        "Use this client-toggle skill.",
      ].join("\n"),
    );

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL(`http://localhost/skills?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: listRes as never,
      });
      const body = JSON.parse(listRes.body) as { skills: Array<{ name: string; path: string }> };
      const skillPath = body.skills.find((skill) => skill.name === "client-toggle-skill")?.path;
      expect(skillPath).toBe(skillDir);

      const toggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "skills",
          path: skillPath,
          enabled: false,
        }) as never,
        res: toggleRes as never,
      });

      expect(toggleRes.statusCode).toBe(200);
      const settings = JSON.parse(readFileSync(join(cwd, ".pi", "settings.json"), "utf-8")) as {
        skills?: string[];
      };
      expect(settings.skills).toContain("-skills/client-toggle-skill/SKILL.md");
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("accepts extension directory paths when toggling Pi settings", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-extension-route-client-toggle-"));
    const extensionDir = join(cwd, ".pi", "extensions", "client-toggle-extension");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(
      join(extensionDir, "index.ts"),
      [
        "import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';",
        "export default function (_pi: ExtensionAPI) {}",
      ].join("\n"),
    );

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const toggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "extensions",
          path: extensionDir,
          enabled: false,
        }) as never,
        res: toggleRes as never,
      });

      expect(toggleRes.statusCode).toBe(200);
      const settings = JSON.parse(readFileSync(join(cwd, ".pi", "settings.json"), "utf-8")) as {
        extensions?: string[];
      };
      expect(settings.extensions).toContain("-extensions/client-toggle-extension/index.ts");
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("writes project package filters when toggling global Pi package resources", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-resource-route-package-scope-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const packageDir = join(root, "pi-package");
    const skillDir = join(packageDir, "skills", "package-route-skill");
    const extensionPath = join(packageDir, "extensions", "package-route-extension.ts");
    mkdirSync(skillDir, { recursive: true });
    mkdirSync(join(packageDir, "extensions"), { recursive: true });
    mkdirSync(agentDir, { recursive: true });
    mkdirSync(cwd, { recursive: true });
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({ name: "oppi-route-package", version: "1.0.0" }),
    );
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: package-route-skill",
        "description: Package skill toggled from a workspace.",
        "---",
        "Use this package-route skill.",
      ].join("\n"),
    );
    writeFileSync(extensionPath, "export default function () {}\n");
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: [packageDir] }));

    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const skillToggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "skills",
          path: skillDir,
          enabled: false,
        }) as never,
        res: skillToggleRes as never,
      });
      expect(skillToggleRes.statusCode).toBe(200);

      const extensionToggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "extensions",
          path: extensionPath,
          enabled: false,
        }) as never,
        res: extensionToggleRes as never,
      });
      expect(extensionToggleRes.statusCode).toBe(200);

      expect(JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf-8"))).toEqual({
        packages: [packageDir],
      });
      const settings = JSON.parse(readFileSync(join(cwd, ".pi", "settings.json"), "utf-8")) as {
        packages?: Array<{ source?: string; skills?: string[]; extensions?: string[] }>;
        skills?: string[];
        extensions?: string[];
      };
      expect(settings.packages).toEqual([
        {
          source: packageDir,
          skills: ["-skills/package-route-skill/SKILL.md"],
          extensions: ["-extensions/package-route-extension.ts"],
        },
      ]);
      expect(settings.skills).toBeUndefined();
      expect(settings.extensions).toBeUndefined();

      const skillsRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL(`http://localhost/skills?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: skillsRes as never,
      });
      const skillsBody = JSON.parse(skillsRes.body) as {
        skills: Array<{ name: string; enabled: boolean }>;
      };
      expect(skillsBody.skills.find((skill) => skill.name === "package-route-skill")?.enabled).toBe(
        false,
      );

      const extensionsRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/extensions",
        url: new URL(`http://localhost/extensions?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: extensionsRes as never,
      });
      const extensionsBody = JSON.parse(extensionsRes.body) as {
        extensions: Array<{ name: string; enabled: boolean }>;
      };
      expect(
        extensionsBody.extensions.find((ext) => ext.name === "package-route-extension")?.enabled,
      ).toBe(false);
    } finally {
      if (previousAgentDir === undefined) {
        delete process.env.PI_CODING_AGENT_DIR;
      } else {
        process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      }
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("writes workspace project settings when toggling global Pi resources", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-resource-route-workspace-scope-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const skillDir = join(agentDir, "skills", "global-route-skill");
    const extensionPath = join(agentDir, "extensions", "global-route-extension.ts");
    mkdirSync(skillDir, { recursive: true });
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    mkdirSync(cwd, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: global-route-skill",
        "description: Global skill toggled from a workspace.",
        "---",
        "Use this global-route skill.",
      ].join("\n"),
    );
    writeFileSync(extensionPath, "export default function () {}\n");

    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const skillToggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "skills",
          path: skillDir,
          enabled: false,
        }) as never,
        res: skillToggleRes as never,
      });
      expect(skillToggleRes.statusCode).toBe(200);

      const extensionToggleRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/pi/resources/enabled",
        url: new URL("http://localhost/pi/resources/enabled"),
        req: makeRequest({
          cwd,
          type: "extensions",
          path: extensionPath,
          enabled: false,
        }) as never,
        res: extensionToggleRes as never,
      });
      expect(extensionToggleRes.statusCode).toBe(200);

      expect(existsSync(join(agentDir, "settings.json"))).toBe(false);
      const settings = JSON.parse(readFileSync(join(cwd, ".pi", "settings.json"), "utf-8")) as {
        skills?: string[];
        extensions?: string[];
      };
      expect(
        settings.skills?.some(
          (entry) => entry.includes("global-route-skill") && !entry.startsWith("-"),
        ),
      ).toBe(true);
      expect(
        settings.skills?.some(
          (entry) => entry.includes("global-route-skill") && entry.startsWith("-"),
        ),
      ).toBe(true);
      expect(
        settings.extensions?.some(
          (entry) => entry.includes("global-route-extension") && !entry.startsWith("-"),
        ),
      ).toBe(true);
      expect(
        settings.extensions?.some(
          (entry) => entry.includes("global-route-extension") && entry.startsWith("-"),
        ),
      ).toBe(true);

      const skillsRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL(`http://localhost/skills?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: skillsRes as never,
      });
      const skillsBody = JSON.parse(skillsRes.body) as {
        skills: Array<{ name: string; enabled: boolean }>;
      };
      expect(skillsBody.skills.find((skill) => skill.name === "global-route-skill")?.enabled).toBe(
        false,
      );

      const extensionsRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/extensions",
        url: new URL(`http://localhost/extensions?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: extensionsRes as never,
      });
      const extensionsBody = JSON.parse(extensionsRes.body) as {
        extensions: Array<{ name: string; enabled: boolean }>;
      };
      expect(
        extensionsBody.extensions.find((ext) => ext.name === "global-route-extension")?.enabled,
      ).toBe(false);
    } finally {
      if (previousAgentDir === undefined) {
        delete process.env.PI_CODING_AGENT_DIR;
      } else {
        process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      }
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("does not list or read cwd-local skill files through symlinks", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-skill-route-symlink-"));
    const skillDir = join(cwd, ".pi", "skills", "safe-route-skill");
    const secretPath = join(cwd, "outside-secret.txt");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: safe-route-skill",
        "description: Skill with a symlinked file.",
        "---",
        "Use this safe-route skill.",
      ].join("\n"),
    );
    writeFileSync(secretPath, "secret outside skill dir");
    symlinkSync(secretPath, join(skillDir, "linked-secret.txt"));

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const detailRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills/safe-route-skill",
        url: new URL(`http://localhost/skills/safe-route-skill?cwd=${encodeURIComponent(cwd)}`),
        req: {} as never,
        res: detailRes as never,
      });

      expect(detailRes.statusCode).toBe(200);
      const detail = JSON.parse(detailRes.body) as { files: string[]; content: string };
      expect(detail.content).toContain("Use this safe-route skill.");
      expect(detail.files).not.toContain("linked-secret.txt");

      const fileRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/skills/safe-route-skill/file",
        url: new URL(
          `http://localhost/skills/safe-route-skill/file?cwd=${encodeURIComponent(cwd)}&path=linked-secret.txt`,
        ),
        req: {} as never,
        res: fileRes as never,
      });

      expect(fileRes.statusCode).toBe(404);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("does not read oversized cwd-local skill files", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-skill-route-large-"));
    const skillDir = join(cwd, ".pi", "skills", "large-route-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: large-route-skill",
        "description: Skill with a large file.",
        "---",
        "Use this large-route skill.",
      ].join("\n"),
    );
    writeFileSync(join(skillDir, "large.txt"), "x".repeat(1024 * 1024 + 1));

    try {
      const dispatch = createSkillRoutes(
        { skillRegistry: { list: vi.fn(() => []) } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const fileRes = makeResponse();

      await dispatch({
        method: "GET",
        path: "/skills/large-route-skill/file",
        url: new URL(
          `http://localhost/skills/large-route-skill/file?cwd=${encodeURIComponent(cwd)}&path=large.txt`,
        ),
        req: {} as never,
        res: fileRes as never,
      });

      expect(fileRes.statusCode).toBe(404);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
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

  it("does not handle removed user skill endpoints", async () => {
    const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "DELETE",
      path: "/me/skills/some-skill",
      url: new URL("http://localhost/me/skills/some-skill"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(false);
    expect(res.statusCode).toBe(0);
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

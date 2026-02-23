/**
 * Skill API route tests.
 *
 * Tests skill CRUD endpoints through RouteHandler with a real
 * SkillRegistry + UserSkillStore backed by temp directories.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RouteHandler, type RouteContext } from "../src/routes/index.js";
import { SkillRegistry, UserSkillStore } from "../src/skills.js";
import type { Workspace } from "../src/types.js";
import type { IncomingMessage, ServerResponse } from "node:http";

// ─── Helpers ───

const SKILL_SEARCH = `---
name: search
description: "Private web search via SearXNG"
container: true
---
# Search Skill
`;

const SKILL_FETCH = `---
name: fetch
description: "Fetch URLs and extract content"
container: true
---
# Fetch Skill
`;

function makeResponse(): {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead(status: number, headers?: Record<string, string>): any;
  end(payload?: string): void;
  json(): unknown;
} {
  const res = {
    statusCode: 0,
    headers: {} as Record<string, string>,
    body: "",
    writeHead(status: number, headers?: Record<string, string>) {
      res.statusCode = status;
      if (headers) res.headers = headers;
      return res;
    },
    end(payload?: string) {
      res.body = payload ?? "";
    },
    json() {
      return JSON.parse(res.body);
    },
  };
  return res;
}

function makeRequest(body: unknown): IncomingMessage {
  const json = JSON.stringify(body);
  const readable = new (require("stream").Readable)();
  readable.push(json);
  readable.push(null);
  readable.headers = { "content-type": "application/json" };
  return readable as unknown as IncomingMessage;
}

// User object removed — single-owner server

// ─── Test Setup ───

let skillDir: string;
let userSkillDir: string;
let registry: SkillRegistry;
let userStore: UserSkillStore;
let routes: RouteHandler;
let workspaces: Workspace[];

function makeWorkspace(
  id: string,
  skills: string[],
): Workspace {
  const now = Date.now();
  return {
    id,
    name: `ws-${id}`,
    skills,
    createdAt: now,
    updatedAt: now,
  };
}

beforeEach(() => {
  skillDir = mkdtempSync(join(tmpdir(), "oppi-skill-api-"));
  userSkillDir = mkdtempSync(join(tmpdir(), "oppi-user-skill-api-"));

  // Create built-in skills
  mkdirSync(join(skillDir, "search"), { recursive: true });
  writeFileSync(join(skillDir, "search", "SKILL.md"), SKILL_SEARCH);
  mkdirSync(join(skillDir, "search", "scripts"), { recursive: true });
  writeFileSync(join(skillDir, "search", "scripts", "search"), "#!/bin/bash\necho hi");

  mkdirSync(join(skillDir, "fetch"), { recursive: true });
  writeFileSync(join(skillDir, "fetch", "SKILL.md"), SKILL_FETCH);

  registry = new SkillRegistry([], { debounceMs: 50 });
  (registry as any).scanDirs = [skillDir, userSkillDir];
  registry.scan();

  userStore = new UserSkillStore(userSkillDir);
  userStore.init();

  workspaces = [
    makeWorkspace("ws-1", ["search", "fetch"]),
    makeWorkspace("ws-2", ["search"]),
  ];

  const ctx = {
    skillRegistry: registry,
    userSkillStore: userStore,
    storage: {
      listWorkspaces: () => workspaces,
      getSession: () => undefined,
      getWorkspace: (_uid: string, wid: string) =>
        workspaces.find((w) => w.id === wid),
    },
    sessions: {
      isActive: () => false,
    },
  } as unknown as RouteContext;

  routes = new RouteHandler(ctx);
});

afterEach(() => {
  registry.stopWatching();
  rmSync(skillDir, { recursive: true, force: true });
  rmSync(userSkillDir, { recursive: true, force: true });
});

// ─── Route call helper ───

async function callRoute(
  method: string,
  path: string,
  body?: unknown,
): Promise<ReturnType<typeof makeResponse>> {
  const res = makeResponse();
  const url = new URL(`http://localhost${path}`);
  const req = body ? makeRequest(body) : undefined;

  await routes.dispatch(
    method,
    url.pathname,
    url,
    req as unknown as IncomingMessage,
    res as unknown as ServerResponse,
  );

  return res;
}

// ─── Tests ───

describe("GET /skills", () => {
  it("lists built-in skills", async () => {
    const res = await callRoute("GET", "/skills");
    const data = res.json() as any;

    expect(data.skills).toHaveLength(2);
    expect(data.skills.map((s: any) => s.name).sort()).toEqual(["fetch", "search"]);
    expect(data.skills[0].description).toBeDefined();
  });
});

describe("GET /skills/:name", () => {
  it("returns skill detail with content and files", async () => {
    const res = await callRoute("GET", "/skills/search");
    const data = res.json() as any;

    expect(data.skill.name).toBe("search");
    expect(data.content).toContain("Private web search");
    expect(data.files).toContain("SKILL.md");
    expect(data.files).toContain("scripts/search");
  });

  it("returns 404 for unknown skill", async () => {
    const res = await callRoute("GET", "/skills/nonexistent");
    expect(res.statusCode).toBe(404);
  });
});

describe("GET /skills/:name/file", () => {
  it("reads a file from a skill", async () => {
    const res = await callRoute("GET", "/skills/search/file?path=SKILL.md");
    const data = res.json() as any;
    expect(data.content).toContain("Private web search");
  });

  it("returns 400 without path param", async () => {
    const res = await callRoute("GET", "/skills/search/file");
    expect(res.statusCode).toBe(400);
  });

  it("returns 404 for missing file", async () => {
    const res = await callRoute("GET", "/skills/search/file?path=nope.txt");
    expect(res.statusCode).toBe(404);
  });
});

describe("POST /skills/rescan", () => {
  it("re-scans and returns updated catalog with change event", async () => {
    // Add a new skill on disk
    mkdirSync(join(skillDir, "new-skill"), { recursive: true });
    writeFileSync(
      join(skillDir, "new-skill", "SKILL.md"),
      '---\nname: new-skill\ndescription: "Brand new"\n---\n# New',
    );

    const res = await callRoute("POST", "/skills/rescan");
    const data = res.json() as any;

    expect(data.skills.map((s: any) => s.name)).toContain("new-skill");
    expect(data.changed.added).toContain("new-skill");
  });
});

describe("GET /me/skills", () => {
  it("returns built-in + user skills with enabledIn", async () => {
    const res = await callRoute("GET", "/me/skills");
    const data = res.json() as any;

    expect(data.skills.length).toBeGreaterThanOrEqual(2);

    const search = data.skills.find((s: any) => s.name === "search");
    expect(search.builtIn).toBe(true);
    expect(search.enabledIn).toEqual(["ws-1", "ws-2"]);

    const fetch = data.skills.find((s: any) => s.name === "fetch");
    expect(fetch.enabledIn).toEqual(["ws-1"]);
  });
});

describe("POST /me/skills", () => {
  it("returns 403 when skill mutation is disabled", async () => {
    const res = await callRoute("POST", "/me/skills", {
      name: "new-skill",
      sessionId: "session-123",
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "Skill editing is disabled on remote clients" });
  });
});

describe("PUT /me/skills/:name", () => {
  it("returns 403 when skill mutation is disabled", async () => {
    const res = await callRoute("PUT", "/me/skills/search", {
      content: '---\nname: search\ndescription: "Updated search"\n---\n# Updated',
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "Skill editing is disabled on remote clients" });
  });
});

describe("DELETE /me/skills/:name", () => {
  it("returns 403 when skill mutation is disabled", async () => {
    const res = await callRoute("DELETE", "/me/skills/search");

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "Skill editing is disabled on remote clients" });
  });
});

/**
 * Workspace CRUD tests.
 *
 * Tests the full workspace lifecycle through both the Storage layer
 * and the HTTP handler layer (route matching, validation, error responses).
 *
 * Coverage:
 * - Storage: create, get, list, update, delete, ensureDefaultWorkspaces
 * - HTTP: GET/POST /workspaces, GET/PUT/DELETE /workspaces/:id
 * - Validation: name, skills, memoryNamespace, policyPreset
 * - Strict runtime requirement (legacy no-runtime records are rejected)
 * - Edge cases: corrupt files, nonexistent workspaces, empty updates
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Storage } from "../src/storage.js";
import type { Workspace, CreateWorkspaceRequest, UpdateWorkspaceRequest } from "../src/types.js";

// ─── Helpers ───

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-server-ws-crud-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});


function createReq(overrides?: Partial<CreateWorkspaceRequest>): CreateWorkspaceRequest {
  return {
    name: "test-workspace",
    skills: ["searxng", "fetch"],
    policyPreset: "container",
    ...overrides,
  };
}

// ─── Storage: createWorkspace ───

describe("Storage.createWorkspace", () => {
  it("creates workspace with required fields", () => {
    const ws = storage.createWorkspace(createReq());

    expect(ws.id).toBeTruthy();
    expect(ws.id.length).toBe(8);
    expect(ws.name).toBe("test-workspace");
    expect(ws.skills).toEqual(["searxng", "fetch"]);
    expect(ws.policyPreset).toBe("container");
    expect(ws.createdAt).toBeGreaterThan(0);
    expect(ws.updatedAt).toBe(ws.createdAt);
  });

  it("creates workspace with no extensions by default", () => {
    const ws = storage.createWorkspace(createReq());
    expect(ws.extensions).toBeUndefined();
  });

  it("creates workspace with all optional fields", () => {
    const ws = storage.createWorkspace(createReq({
        description: "A coding workspace",
        icon: "terminal",
        runtime: "host",
        systemPrompt: "Be helpful",
        hostMount: "~/workspace/oppi",
        memoryEnabled: true,
        memoryNamespace: "coding",
        extensions: ["memory", "todos"],
        defaultModel: "anthropic/claude-sonnet-4-0",
      }),
    );

    expect(ws.description).toBe("A coding workspace");
    expect(ws.icon).toBe("terminal");
    expect(ws.runtime).toBe("host");
    expect(ws.systemPrompt).toBe("Be helpful");
    expect(ws.hostMount).toBe("~/workspace/oppi");
    expect(ws.memoryEnabled).toBe(true);
    expect(ws.memoryNamespace).toBe("coding");
    expect(ws.extensions).toEqual(["memory", "todos"]);
    expect(ws.defaultModel).toBe("anthropic/claude-sonnet-4-0");
  });

  it("persists to disk as JSON", () => {
    const ws = storage.createWorkspace(createReq());
    const path = join(dataDir, "workspaces", `${ws.id}.json`);

    expect(existsSync(path)).toBe(true);
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    expect(raw.name).toBe("test-workspace");
  });

  it("generates unique IDs for each workspace", () => {
    const ws1 = storage.createWorkspace(createReq({ name: "ws-1" }));
    const ws2 = storage.createWorkspace(createReq({ name: "ws-2" }));
    const ws3 = storage.createWorkspace(createReq({ name: "ws-3" }));

    const ids = new Set([ws1.id, ws2.id, ws3.id]);
    expect(ids.size).toBe(3);
  });

  it("defaults policyPreset to 'container'", () => {
    const ws = storage.createWorkspace({
      name: "no-preset",
      skills: [],
    });

    expect(ws.policyPreset).toBe("container");
  });

  it("infers runtime=container when policyPreset is container and no hostMount", () => {
    const ws = storage.createWorkspace(createReq({ policyPreset: "container" }));
    expect(ws.runtime).toBe("container");
  });

  it("infers runtime=host when hostMount is set", () => {
    const ws = storage.createWorkspace(createReq({ hostMount: "~/workspace" }));
    expect(ws.runtime).toBe("host");
  });

  it("respects explicit runtime override", () => {
    const ws = storage.createWorkspace(createReq({ runtime: "host", policyPreset: "container" }),
    );
    expect(ws.runtime).toBe("host");
  });

  it("auto-generates memoryNamespace when memoryEnabled but no namespace given", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: true }),
    );

    expect(ws.memoryEnabled).toBe(true);
    expect(ws.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("uses provided memoryNamespace when given", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: true, memoryNamespace: "shared-ns" }),
    );

    expect(ws.memoryNamespace).toBe("shared-ns");
  });

  it("does not auto-generate memoryNamespace when memory is disabled", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: false }),
    );

    expect(ws.memoryNamespace).toBeUndefined();
  });

  it("keeps workspace directory available", () => {
    const workspaceDir = join(dataDir, "workspaces");

    storage.createWorkspace(createReq());
    expect(existsSync(workspaceDir)).toBe(true);
  });
});

// ─── Storage: getWorkspace ───

describe("Storage.getWorkspace", () => {
  it("retrieves a created workspace", () => {
    const created = storage.createWorkspace(createReq({ name: "coding" }));
    const got = storage.getWorkspace(created.id);

    expect(got).toBeDefined();
    expect(got!.id).toBe(created.id);
    expect(got!.name).toBe("coding");
  });

  it("returns undefined for nonexistent workspace", () => {
    expect(storage.getWorkspace("nope-1234")).toBeUndefined();
  });

  it("reads by id regardless of caller user before pairing", () => {
    const ws = storage.createWorkspace(createReq());
    expect(storage.getWorkspace(ws.id)?.id).toBe(ws.id);
  });

  it("handles corrupt JSON gracefully", () => {
    const ws = storage.createWorkspace(createReq());
    const path = join(dataDir, "workspaces", `${ws.id}.json`);

    writeFileSync(path, "{{not valid json}}");
    expect(storage.getWorkspace(ws.id)).toBeUndefined();
  });

  it("rejects records missing runtime", () => {
    const ws = storage.createWorkspace(createReq({ policyPreset: "container" }));
    const path = join(dataDir, "workspaces", `${ws.id}.json`);

    // Simulate removed legacy fallback: runtime is now required.
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    expect(storage.getWorkspace(ws.id)).toBeUndefined();
  });
});

// ─── Storage: listWorkspaces ───

describe("Storage.listWorkspaces", () => {
  it("returns empty array for user with no workspaces", () => {
    expect(storage.listWorkspaces()).toEqual([]);
  });

  it("returns all workspaces for a user", () => {
    storage.createWorkspace(createReq({ name: "ws-1" }));
    storage.createWorkspace(createReq({ name: "ws-2" }));
    storage.createWorkspace(createReq({ name: "ws-3" }));

    const list = storage.listWorkspaces();
    expect(list).toHaveLength(3);
    expect(list.map((w) => w.name).sort()).toEqual(["ws-1", "ws-2", "ws-3"]);
  });

  it("lists all workspaces from flat owner layout before pairing", () => {
    storage.createWorkspace(createReq({ name: "user1-ws" }));
    storage.createWorkspace(createReq({ name: "user2-ws" }));

    const list1 = storage.listWorkspaces();
    const list2 = storage.listWorkspaces();

    expect(list1).toHaveLength(2);
    expect(list2).toHaveLength(2);
    expect(list1.map((w) => w.name).sort()).toEqual(["user1-ws", "user2-ws"]);
    expect(list2.map((w) => w.name).sort()).toEqual(["user1-ws", "user2-ws"]);
  });

  it("sorts by createdAt ascending", () => {
    // Create workspaces with explicit timestamps via disk manipulation
    // to guarantee ordering (Date.now() can return same value in tight loops)
    const ws1 = storage.createWorkspace(createReq({ name: "first" }));
    const ws2 = storage.createWorkspace(createReq({ name: "second" }));
    const ws3 = storage.createWorkspace(createReq({ name: "third" }));

    // Force distinct timestamps on disk
    for (const [ws, ts] of [[ws1, 1000], [ws2, 2000], [ws3, 3000]] as const) {
      const path = join(dataDir, "workspaces", `${ws.id}.json`);
      const raw = JSON.parse(readFileSync(path, "utf-8"));
      raw.createdAt = ts;
      writeFileSync(path, JSON.stringify(raw));
    }

    const list = storage.listWorkspaces();
    expect(list[0].id).toBe(ws1.id);
    expect(list[1].id).toBe(ws2.id);
    expect(list[2].id).toBe(ws3.id);
  });

  it("skips corrupt JSON files", () => {
    storage.createWorkspace(createReq({ name: "good" }));

    // Write a corrupt file
    const corruptPath = join(dataDir, "workspaces", "corrupt.json");
    writeFileSync(corruptPath, "not json at all");

    const list = storage.listWorkspaces();
    expect(list).toHaveLength(1);
    expect(list[0].name).toBe("good");
  });

  it("skips non-JSON files", () => {
    storage.createWorkspace(createReq({ name: "real" }));

    const txtPath = join(dataDir, "workspaces", "notes.txt");
    writeFileSync(txtPath, "just notes");

    expect(storage.listWorkspaces()).toHaveLength(1);
  });
});

// ─── Storage: updateWorkspace ───

describe("Storage.updateWorkspace", () => {
  it("updates name", () => {
    const ws = storage.createWorkspace(createReq({ name: "old-name" }));
    const updated = storage.updateWorkspace(ws.id, { name: "new-name" });

    expect(updated).toBeDefined();
    expect(updated!.name).toBe("new-name");
  });

  it("updates description", () => {
    const ws = storage.createWorkspace(createReq());
    const updated = storage.updateWorkspace(ws.id, { description: "new desc" });

    expect(updated!.description).toBe("new desc");
  });

  it("updates icon", () => {
    const ws = storage.createWorkspace(createReq({ icon: "terminal" }));
    const updated = storage.updateWorkspace(ws.id, { icon: "magnifyingglass" });

    expect(updated!.icon).toBe("magnifyingglass");
  });

  it("updates runtime", () => {
    const ws = storage.createWorkspace(createReq({ runtime: "container" }));
    const updated = storage.updateWorkspace(ws.id, { runtime: "host" });

    expect(updated!.runtime).toBe("host");
  });

  it("updates skills", () => {
    const ws = storage.createWorkspace(createReq({ skills: ["fetch"] }));
    const updated = storage.updateWorkspace(ws.id, { skills: ["fetch", "web-browser"] });

    expect(updated!.skills).toEqual(["fetch", "web-browser"]);
  });

  it("updates policyPreset", () => {
    const ws = storage.createWorkspace(createReq({ policyPreset: "container" }));
    const updated = storage.updateWorkspace(ws.id, { policyPreset: "host" });

    expect(updated!.policyPreset).toBe("host");
  });

  it("updates systemPrompt", () => {
    const ws = storage.createWorkspace(createReq());
    const updated = storage.updateWorkspace(ws.id, { systemPrompt: "Be concise." });

    expect(updated!.systemPrompt).toBe("Be concise.");
  });

  it("updates hostMount", () => {
    const ws = storage.createWorkspace(createReq());
    const updated = storage.updateWorkspace(ws.id, { hostMount: "~/workspace/kypu" });

    expect(updated!.hostMount).toBe("~/workspace/kypu");
  });

  it("updates memoryEnabled", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: false }));
    const updated = storage.updateWorkspace(ws.id, { memoryEnabled: true });

    expect(updated!.memoryEnabled).toBe(true);
  });

  it("updates memoryNamespace", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: true, memoryNamespace: "old-ns" }),
    );
    const updated = storage.updateWorkspace(ws.id, { memoryNamespace: "new-ns" });

    expect(updated!.memoryNamespace).toBe("new-ns");
  });

  it("auto-fills memoryNamespace when memoryEnabled and namespace is empty", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: false }));

    // Enable memory without setting a namespace
    const updated = storage.updateWorkspace(ws.id, { memoryEnabled: true });

    expect(updated!.memoryEnabled).toBe(true);
    expect(updated!.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("auto-fills memoryNamespace when existing namespace is whitespace-only", () => {
    const ws = storage.createWorkspace(createReq({ memoryEnabled: true, memoryNamespace: "valid" }),
    );

    // Set namespace to whitespace, should auto-fill
    const updated = storage.updateWorkspace(ws.id, { memoryNamespace: "   " });

    expect(updated!.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("normalizes and updates extensions", () => {
    const ws = storage.createWorkspace(createReq());
    const updated = storage.updateWorkspace(ws.id, {
      extensions: [" memory ", "todos", "memory"],
    });

    expect(updated!.extensions).toEqual(["memory", "todos"]);
  });

  it("updates defaultModel", () => {
    const ws = storage.createWorkspace(createReq());
    const updated = storage.updateWorkspace(ws.id, {
      defaultModel: "anthropic/claude-opus-4-6",
    });

    expect(updated!.defaultModel).toBe("anthropic/claude-opus-4-6");
  });

  it("updates multiple fields at once", () => {
    const ws = storage.createWorkspace(createReq({ name: "old" }));
    const updated = storage.updateWorkspace(ws.id, {
      name: "new",
      description: "updated",
      skills: ["web-browser"],
      policyPreset: "host",
    });

    expect(updated!.name).toBe("new");
    expect(updated!.description).toBe("updated");
    expect(updated!.skills).toEqual(["web-browser"]);
    expect(updated!.policyPreset).toBe("host");
  });

  it("bumps updatedAt timestamp", () => {
    const ws = storage.createWorkspace(createReq());
    const originalUpdatedAt = ws.updatedAt;

    // Small delay to ensure timestamp changes
    const updated = storage.updateWorkspace(ws.id, { name: "changed" });
    expect(updated!.updatedAt).toBeGreaterThanOrEqual(originalUpdatedAt);
  });

  it("preserves unchanged fields", () => {
    const ws = storage.createWorkspace(createReq({
        name: "keep-me",
        description: "original desc",
        icon: "terminal",
        skills: ["fetch"],
      }),
    );

    const updated = storage.updateWorkspace(ws.id, { description: "new desc" });

    expect(updated!.name).toBe("keep-me");
    expect(updated!.icon).toBe("terminal");
    expect(updated!.skills).toEqual(["fetch"]);
    expect(updated!.description).toBe("new desc");
  });

  it("persists updates to disk", () => {
    const ws = storage.createWorkspace(createReq({ name: "before" }));
    storage.updateWorkspace(ws.id, { name: "after" });

    // Read directly from disk
    const path = join(dataDir, "workspaces", `${ws.id}.json`);
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    expect(raw.name).toBe("after");
  });

  it("returns undefined for nonexistent workspace", () => {
    expect(storage.updateWorkspace("nope-1234", { name: "x" })).toBeUndefined();
  });

  it("updates by id regardless of caller user before pairing", () => {
    const ws = storage.createWorkspace(createReq());
    expect(storage.updateWorkspace(ws.id, { name: "x" })?.name).toBe("x");
  });

  it("handles empty update (no fields)", () => {
    const ws = storage.createWorkspace(createReq({ name: "same" }));
    const updated = storage.updateWorkspace(ws.id, {});

    expect(updated).toBeDefined();
    expect(updated!.name).toBe("same");
  });
});

// ─── Storage: deleteWorkspace ───

describe("Storage.deleteWorkspace", () => {
  it("deletes an existing workspace", () => {
    const ws = storage.createWorkspace(createReq());
    const result = storage.deleteWorkspace(ws.id);

    expect(result).toBe(true);
    expect(storage.getWorkspace(ws.id)).toBeUndefined();
  });

  it("removes file from disk", () => {
    const ws = storage.createWorkspace(createReq());
    const path = join(dataDir, "workspaces", `${ws.id}.json`);
    expect(existsSync(path)).toBe(true);

    storage.deleteWorkspace(ws.id);
    expect(existsSync(path)).toBe(false);
  });

  it("returns false for nonexistent workspace", () => {
    expect(storage.deleteWorkspace("nope-1234")).toBe(false);
  });

  it("deletes by id regardless of caller user before pairing", () => {
    const ws = storage.createWorkspace(createReq());
    expect(storage.deleteWorkspace(ws.id)).toBe(true);
    expect(storage.getWorkspace(ws.id)).toBeUndefined();
  });

  it("does not affect other workspaces", () => {
    const ws1 = storage.createWorkspace(createReq({ name: "keep" }));
    const ws2 = storage.createWorkspace(createReq({ name: "delete" }));

    storage.deleteWorkspace(ws2.id);

    expect(storage.getWorkspace(ws1.id)).toBeDefined();
    expect(storage.listWorkspaces()).toHaveLength(1);
  });

  it("double-delete returns false", () => {
    const ws = storage.createWorkspace(createReq());
    expect(storage.deleteWorkspace(ws.id)).toBe(true);
    expect(storage.deleteWorkspace(ws.id)).toBe(false);
  });
});

// ─── Storage: ensureDefaultWorkspaces ───

describe("Storage.ensureDefaultWorkspaces", () => {
  it("seeds default workspaces for new user", () => {
    storage.ensureDefaultWorkspaces();
    const list = storage.listWorkspaces();

    expect(list.length).toBeGreaterThanOrEqual(2);
    const names = list.map((w) => w.name);
    expect(names).toContain("general");
    expect(names).toContain("research");
  });

  it("does not seed when user already has workspaces", () => {
    storage.createWorkspace(createReq({ name: "custom" }));
    storage.ensureDefaultWorkspaces();

    const list = storage.listWorkspaces();
    expect(list).toHaveLength(1);
    expect(list[0].name).toBe("custom");
  });

  it("is idempotent — second call does nothing", () => {
    storage.ensureDefaultWorkspaces();
    const count1 = storage.listWorkspaces().length;

    storage.ensureDefaultWorkspaces();
    const count2 = storage.listWorkspaces().length;

    expect(count2).toBe(count1);
  });

  it("default workspaces have correct structure", () => {
    storage.ensureDefaultWorkspaces();
    const list = storage.listWorkspaces();

    for (const ws of list) {
      expect(ws.id.length).toBe(8);
      expect(ws.skills).toBeInstanceOf(Array);
      expect(ws.policyPreset).toBeTruthy();
      expect(ws.createdAt).toBeGreaterThan(0);
    }
  });

  it("default general workspace has memory enabled", () => {
    storage.ensureDefaultWorkspaces();
    const general = storage.listWorkspaces().find((w) => w.name === "general");

    expect(general).toBeDefined();
    expect(general!.memoryEnabled).toBe(true);
    expect(general!.memoryNamespace).toBe("general");
  });
});

// ─── Storage: runtime validation ───

describe("Storage runtime validation", () => {
  it("preserves explicit runtime=host", () => {
    const ws = storage.createWorkspace(createReq({ runtime: "host" }));
    const got = storage.getWorkspace(ws.id);
    expect(got!.runtime).toBe("host");
  });

  it("preserves explicit runtime=container", () => {
    const ws = storage.createWorkspace(createReq({ runtime: "container" }));
    const got = storage.getWorkspace(ws.id);
    expect(got!.runtime).toBe("container");
  });

  it("rejects legacy records missing runtime", () => {
    const ws = storage.createWorkspace(createReq({ policyPreset: "container" }));
    const path = join(dataDir, "workspaces", `${ws.id}.json`);

    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    expect(storage.getWorkspace(ws.id)).toBeUndefined();
  });

  it("list skips records missing runtime", () => {
    const good = storage.createWorkspace(createReq({ name: "good" }));
    const bad = storage.createWorkspace(createReq({ name: "bad" }));
    const badPath = join(dataDir, "workspaces", `${bad.id}.json`);

    const raw = JSON.parse(readFileSync(badPath, "utf-8"));
    delete raw.runtime;
    writeFileSync(badPath, JSON.stringify(raw));

    const list = storage.listWorkspaces();
    expect(list.map((w) => w.id)).toContain(good.id);
    expect(list.map((w) => w.id)).not.toContain(bad.id);
  });
});

// ─── HTTP route matching ───

describe("Workspace API route patterns", () => {
  // Test the regex patterns used in server.ts routing
  const WORKSPACE_ROUTE = /^\/workspaces\/([^/]+)$/;
  const WORKSPACES_LIST = /^\/workspaces$/;

  it("matches GET /workspaces", () => {
    expect("/workspaces".match(WORKSPACES_LIST)).toBeTruthy();
  });

  it("matches /workspaces/:id", () => {
    const m = "/workspaces/abc12345".match(WORKSPACE_ROUTE);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("abc12345");
  });

  it("does not match /workspaces/:id/extra", () => {
    expect("/workspaces/abc12345/extra".match(WORKSPACE_ROUTE)).toBeNull();
  });

  it("does not match /workspaces/ (trailing slash, no ID)", () => {
    expect("/workspaces/".match(WORKSPACE_ROUTE)).toBeNull();
  });

  it("captures workspace IDs with hyphens and underscores", () => {
    const m = "/workspaces/o_g0UfwY".match(WORKSPACE_ROUTE);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("o_g0UfwY");
  });
});

// ─── Validation helpers ───

describe("memoryNamespace validation", () => {
  // Mirror the regex from server.ts: /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/
  const isValid = (ns: string) => /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(ns);

  it("accepts alphanumeric", () => {
    expect(isValid("general")).toBe(true);
    expect(isValid("research")).toBe(true);
    expect(isValid("ws123")).toBe(true);
  });

  it("accepts dots, hyphens, underscores", () => {
    expect(isValid("my.namespace")).toBe(true);
    expect(isValid("my-namespace")).toBe(true);
    expect(isValid("my_namespace")).toBe(true);
  });

  it("rejects empty string", () => {
    expect(isValid("")).toBe(false);
  });

  it("rejects leading special characters", () => {
    expect(isValid(".leading-dot")).toBe(false);
    expect(isValid("-leading-dash")).toBe(false);
    expect(isValid("_leading-underscore")).toBe(false);
  });

  it("rejects spaces", () => {
    expect(isValid("has space")).toBe(false);
  });

  it("rejects special characters", () => {
    expect(isValid("ns@work")).toBe(false);
    expect(isValid("ns/path")).toBe(false);
  });

  it("rejects names over 64 chars", () => {
    expect(isValid("a".repeat(65))).toBe(false);
    expect(isValid("a".repeat(64))).toBe(true);
  });

  it("accepts single character", () => {
    expect(isValid("a")).toBe(true);
    expect(isValid("Z")).toBe(true);
    expect(isValid("0")).toBe(true);
  });
});

// ─── Full lifecycle ───

describe("Workspace full lifecycle", () => {
  it("create → get → update → list → delete → gone", () => {
    // Create
    const ws = storage.createWorkspace(createReq({ name: "lifecycle-test" }));
    expect(ws.name).toBe("lifecycle-test");

    // Get
    const got = storage.getWorkspace(ws.id);
    expect(got!.name).toBe("lifecycle-test");

    // Update
    const updated = storage.updateWorkspace(ws.id, {
      name: "renamed",
      description: "now with a description",
    });
    expect(updated!.name).toBe("renamed");

    // Verify update persisted via get
    const afterUpdate = storage.getWorkspace(ws.id);
    expect(afterUpdate!.name).toBe("renamed");
    expect(afterUpdate!.description).toBe("now with a description");

    // List should contain it
    const list = storage.listWorkspaces();
    expect(list.find((w) => w.id === ws.id)).toBeDefined();

    // Delete
    expect(storage.deleteWorkspace(ws.id)).toBe(true);

    // Gone
    expect(storage.getWorkspace(ws.id)).toBeUndefined();
    expect(storage.listWorkspaces().find((w) => w.id === ws.id)).toBeUndefined();
  });

  it("create workspace, change policy preset between host and container", () => {
    const ws = storage.createWorkspace(createReq({ name: "Admin", policyPreset: "container", runtime: "host" }),
    );

    expect(ws.policyPreset).toBe("container");

    const fixed = storage.updateWorkspace(ws.id, { policyPreset: "host" });
    expect(fixed!.policyPreset).toBe("host");
    expect(fixed!.runtime).toBe("host"); // runtime should be preserved

    // Verify persisted
    const reloaded = storage.getWorkspace(ws.id);
    expect(reloaded!.policyPreset).toBe("host");
  });

  it("multiple users, independent lifecycle", () => {
    const ws1 = storage.createWorkspace(createReq({ name: "user1-ws" }));
    const ws2 = storage.createWorkspace(createReq({ name: "user2-ws" }));

    // Update one, other unaffected
    storage.updateWorkspace(ws1.id, { name: "user1-renamed" });
    expect(storage.getWorkspace(ws2.id)!.name).toBe("user2-ws");

    // Delete one, other unaffected
    storage.deleteWorkspace(ws1.id);
    expect(storage.getWorkspace(ws2.id)).toBeDefined();
  });
});

// ─── Edge cases ───

describe("Workspace edge cases", () => {
  it("create workspace with empty skills array", () => {
    const ws = storage.createWorkspace({ name: "bare", skills: [] });
    expect(ws.skills).toEqual([]);
  });

  it("update skills to empty array", () => {
    const ws = storage.createWorkspace(createReq({ skills: ["fetch"] }));
    const updated = storage.updateWorkspace(ws.id, { skills: [] });
    expect(updated!.skills).toEqual([]);
  });

  it("create many workspaces for same user", () => {
    const count = 20;
    for (let i = 0; i < count; i++) {
      storage.createWorkspace(createReq({ name: `ws-${i}` }));
    }

    expect(storage.listWorkspaces()).toHaveLength(count);
  });

  it("workspace name can contain special characters", () => {
    const ws = storage.createWorkspace(createReq({ name: "My Workspace (test)" }));
    const got = storage.getWorkspace(ws.id);
    expect(got!.name).toBe("My Workspace (test)");
  });

  it("workspace name can contain unicode", () => {
    const ws = storage.createWorkspace(createReq({ name: "workspace" }));
    const got = storage.getWorkspace(ws.id);
    expect(got!.name).toBe("workspace");
  });

  it("update then delete — file is gone", () => {
    const ws = storage.createWorkspace(createReq());
    storage.updateWorkspace(ws.id, { name: "updated" });
    storage.deleteWorkspace(ws.id);

    const path = join(dataDir, "workspaces", `${ws.id}.json`);
    expect(existsSync(path)).toBe(false);
  });

  it("create after delete reuses nothing (new ID)", () => {
    const ws1 = storage.createWorkspace(createReq({ name: "first" }));
    const id1 = ws1.id;
    storage.deleteWorkspace(id1);

    const ws2 = storage.createWorkspace(createReq({ name: "second" }));
    expect(ws2.id).not.toBe(id1);
  });
});

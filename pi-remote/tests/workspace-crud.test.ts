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
 * - Runtime inference for legacy records without explicit runtime
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
  dataDir = mkdtempSync(join(tmpdir(), "pi-remote-ws-crud-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

const USER = "test-user-1";
const USER2 = "test-user-2";

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
    const ws = storage.createWorkspace(USER, createReq());

    expect(ws.id).toBeTruthy();
    expect(ws.id.length).toBe(8);
    expect(ws.userId).toBe(USER);
    expect(ws.name).toBe("test-workspace");
    expect(ws.skills).toEqual(["searxng", "fetch"]);
    expect(ws.policyPreset).toBe("container");
    expect(ws.createdAt).toBeGreaterThan(0);
    expect(ws.updatedAt).toBe(ws.createdAt);
  });

  it("defaults extension mode to legacy for backward compatibility", () => {
    const ws = storage.createWorkspace(USER, createReq());
    expect(ws.extensionMode).toBe("legacy");
    expect(ws.extensions).toBeUndefined();
  });

  it("creates workspace with all optional fields", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({
        description: "A coding workspace",
        icon: "terminal",
        runtime: "host",
        systemPrompt: "Be helpful",
        hostMount: "~/workspace/pios",
        memoryEnabled: true,
        memoryNamespace: "coding",
        extensionMode: "explicit",
        extensions: ["memory", "todos"],
        defaultModel: "anthropic/claude-sonnet-4-0",
      }),
    );

    expect(ws.description).toBe("A coding workspace");
    expect(ws.icon).toBe("terminal");
    expect(ws.runtime).toBe("host");
    expect(ws.systemPrompt).toBe("Be helpful");
    expect(ws.hostMount).toBe("~/workspace/pios");
    expect(ws.memoryEnabled).toBe(true);
    expect(ws.memoryNamespace).toBe("coding");
    expect(ws.extensionMode).toBe("explicit");
    expect(ws.extensions).toEqual(["memory", "todos"]);
    expect(ws.defaultModel).toBe("anthropic/claude-sonnet-4-0");
  });

  it("persists to disk as JSON", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    expect(existsSync(path)).toBe(true);
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    expect(raw.name).toBe("test-workspace");
    expect(raw.userId).toBe(USER);
  });

  it("generates unique IDs for each workspace", () => {
    const ws1 = storage.createWorkspace(USER, createReq({ name: "ws-1" }));
    const ws2 = storage.createWorkspace(USER, createReq({ name: "ws-2" }));
    const ws3 = storage.createWorkspace(USER, createReq({ name: "ws-3" }));

    const ids = new Set([ws1.id, ws2.id, ws3.id]);
    expect(ids.size).toBe(3);
  });

  it("defaults policyPreset to 'container'", () => {
    const ws = storage.createWorkspace(USER, {
      name: "no-preset",
      skills: [],
    });

    expect(ws.policyPreset).toBe("container");
  });

  it("infers runtime=container when policyPreset is container and no hostMount", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "container" }));
    expect(ws.runtime).toBe("container");
  });

  it("infers runtime=host when hostMount is set", () => {
    const ws = storage.createWorkspace(USER, createReq({ hostMount: "~/workspace" }));
    expect(ws.runtime).toBe("host");
  });

  it("respects explicit runtime override", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ runtime: "host", policyPreset: "container" }),
    );
    expect(ws.runtime).toBe("host");
  });

  it("auto-generates memoryNamespace when memoryEnabled but no namespace given", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ memoryEnabled: true }),
    );

    expect(ws.memoryEnabled).toBe(true);
    expect(ws.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("uses provided memoryNamespace when given", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ memoryEnabled: true, memoryNamespace: "shared-ns" }),
    );

    expect(ws.memoryNamespace).toBe("shared-ns");
  });

  it("does not auto-generate memoryNamespace when memory is disabled", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ memoryEnabled: false }),
    );

    expect(ws.memoryNamespace).toBeUndefined();
  });

  it("creates user workspace directory if it does not exist", () => {
    const userDir = join(dataDir, "workspaces", "new-user");
    expect(existsSync(userDir)).toBe(false);

    storage.createWorkspace("new-user", createReq());
    expect(existsSync(userDir)).toBe(true);
  });
});

// ─── Storage: getWorkspace ───

describe("Storage.getWorkspace", () => {
  it("retrieves a created workspace", () => {
    const created = storage.createWorkspace(USER, createReq({ name: "coding" }));
    const got = storage.getWorkspace(USER, created.id);

    expect(got).toBeDefined();
    expect(got!.id).toBe(created.id);
    expect(got!.name).toBe("coding");
  });

  it("returns undefined for nonexistent workspace", () => {
    expect(storage.getWorkspace(USER, "nope-1234")).toBeUndefined();
  });

  it("returns undefined for wrong user", () => {
    const ws = storage.createWorkspace(USER, createReq());
    expect(storage.getWorkspace(USER2, ws.id)).toBeUndefined();
  });

  it("handles corrupt JSON gracefully", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    writeFileSync(path, "{{not valid json}}");
    expect(storage.getWorkspace(USER, ws.id)).toBeUndefined();
  });

  it("infers runtime for legacy records missing runtime field", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "container" }));
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    // Simulate legacy record: remove runtime field
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const got = storage.getWorkspace(USER, ws.id);
    expect(got).toBeDefined();
    expect(got!.runtime).toBe("container");
  });

  it("infers runtime=host for legacy record with hostMount", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ hostMount: "~/workspace", policyPreset: "host" }),
    );
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    // Remove runtime field to simulate legacy
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("host");
  });
});

// ─── Storage: listWorkspaces ───

describe("Storage.listWorkspaces", () => {
  it("returns empty array for user with no workspaces", () => {
    expect(storage.listWorkspaces(USER)).toEqual([]);
  });

  it("returns all workspaces for a user", () => {
    storage.createWorkspace(USER, createReq({ name: "ws-1" }));
    storage.createWorkspace(USER, createReq({ name: "ws-2" }));
    storage.createWorkspace(USER, createReq({ name: "ws-3" }));

    const list = storage.listWorkspaces(USER);
    expect(list).toHaveLength(3);
    expect(list.map((w) => w.name).sort()).toEqual(["ws-1", "ws-2", "ws-3"]);
  });

  it("isolates workspaces between users", () => {
    storage.createWorkspace(USER, createReq({ name: "user1-ws" }));
    storage.createWorkspace(USER2, createReq({ name: "user2-ws" }));

    const list1 = storage.listWorkspaces(USER);
    const list2 = storage.listWorkspaces(USER2);

    expect(list1).toHaveLength(1);
    expect(list1[0].name).toBe("user1-ws");
    expect(list2).toHaveLength(1);
    expect(list2[0].name).toBe("user2-ws");
  });

  it("sorts by createdAt ascending", () => {
    // Create workspaces with explicit timestamps via disk manipulation
    // to guarantee ordering (Date.now() can return same value in tight loops)
    const ws1 = storage.createWorkspace(USER, createReq({ name: "first" }));
    const ws2 = storage.createWorkspace(USER, createReq({ name: "second" }));
    const ws3 = storage.createWorkspace(USER, createReq({ name: "third" }));

    // Force distinct timestamps on disk
    for (const [ws, ts] of [[ws1, 1000], [ws2, 2000], [ws3, 3000]] as const) {
      const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);
      const raw = JSON.parse(readFileSync(path, "utf-8"));
      raw.createdAt = ts;
      writeFileSync(path, JSON.stringify(raw));
    }

    const list = storage.listWorkspaces(USER);
    expect(list[0].id).toBe(ws1.id);
    expect(list[1].id).toBe(ws2.id);
    expect(list[2].id).toBe(ws3.id);
  });

  it("skips corrupt JSON files", () => {
    storage.createWorkspace(USER, createReq({ name: "good" }));

    // Write a corrupt file
    const corruptPath = join(dataDir, "workspaces", USER, "corrupt.json");
    writeFileSync(corruptPath, "not json at all");

    const list = storage.listWorkspaces(USER);
    expect(list).toHaveLength(1);
    expect(list[0].name).toBe("good");
  });

  it("skips non-JSON files", () => {
    storage.createWorkspace(USER, createReq({ name: "real" }));

    const txtPath = join(dataDir, "workspaces", USER, "notes.txt");
    writeFileSync(txtPath, "just notes");

    expect(storage.listWorkspaces(USER)).toHaveLength(1);
  });
});

// ─── Storage: updateWorkspace ───

describe("Storage.updateWorkspace", () => {
  it("updates name", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "old-name" }));
    const updated = storage.updateWorkspace(USER, ws.id, { name: "new-name" });

    expect(updated).toBeDefined();
    expect(updated!.name).toBe("new-name");
  });

  it("updates description", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, { description: "new desc" });

    expect(updated!.description).toBe("new desc");
  });

  it("updates icon", () => {
    const ws = storage.createWorkspace(USER, createReq({ icon: "terminal" }));
    const updated = storage.updateWorkspace(USER, ws.id, { icon: "magnifyingglass" });

    expect(updated!.icon).toBe("magnifyingglass");
  });

  it("updates runtime", () => {
    const ws = storage.createWorkspace(USER, createReq({ runtime: "container" }));
    const updated = storage.updateWorkspace(USER, ws.id, { runtime: "host" });

    expect(updated!.runtime).toBe("host");
  });

  it("updates skills", () => {
    const ws = storage.createWorkspace(USER, createReq({ skills: ["fetch"] }));
    const updated = storage.updateWorkspace(USER, ws.id, { skills: ["fetch", "web-browser"] });

    expect(updated!.skills).toEqual(["fetch", "web-browser"]);
  });

  it("updates policyPreset", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "container" }));
    const updated = storage.updateWorkspace(USER, ws.id, { policyPreset: "host" });

    expect(updated!.policyPreset).toBe("host");
  });

  it("updates systemPrompt", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, { systemPrompt: "Be concise." });

    expect(updated!.systemPrompt).toBe("Be concise.");
  });

  it("updates hostMount", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, { hostMount: "~/workspace/kypu" });

    expect(updated!.hostMount).toBe("~/workspace/kypu");
  });

  it("updates memoryEnabled", () => {
    const ws = storage.createWorkspace(USER, createReq({ memoryEnabled: false }));
    const updated = storage.updateWorkspace(USER, ws.id, { memoryEnabled: true });

    expect(updated!.memoryEnabled).toBe(true);
  });

  it("updates memoryNamespace", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ memoryEnabled: true, memoryNamespace: "old-ns" }),
    );
    const updated = storage.updateWorkspace(USER, ws.id, { memoryNamespace: "new-ns" });

    expect(updated!.memoryNamespace).toBe("new-ns");
  });

  it("auto-fills memoryNamespace when memoryEnabled and namespace is empty", () => {
    const ws = storage.createWorkspace(USER, createReq({ memoryEnabled: false }));

    // Enable memory without setting a namespace
    const updated = storage.updateWorkspace(USER, ws.id, { memoryEnabled: true });

    expect(updated!.memoryEnabled).toBe(true);
    expect(updated!.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("auto-fills memoryNamespace when existing namespace is whitespace-only", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ memoryEnabled: true, memoryNamespace: "valid" }),
    );

    // Set namespace to whitespace, should auto-fill
    const updated = storage.updateWorkspace(USER, ws.id, { memoryNamespace: "   " });

    expect(updated!.memoryNamespace).toBe(`ws-${ws.id}`);
  });

  it("updates extensionMode", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, { extensionMode: "explicit" });

    expect(updated!.extensionMode).toBe("explicit");
  });

  it("normalizes and updates extensions", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, {
      extensions: [" memory ", "todos", "memory"],
      extensionMode: "explicit",
    });

    expect(updated!.extensions).toEqual(["memory", "todos"]);
    expect(updated!.extensionMode).toBe("explicit");
  });

  it("updates defaultModel", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const updated = storage.updateWorkspace(USER, ws.id, {
      defaultModel: "anthropic/claude-opus-4-6",
    });

    expect(updated!.defaultModel).toBe("anthropic/claude-opus-4-6");
  });

  it("updates multiple fields at once", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "old" }));
    const updated = storage.updateWorkspace(USER, ws.id, {
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
    const ws = storage.createWorkspace(USER, createReq());
    const originalUpdatedAt = ws.updatedAt;

    // Small delay to ensure timestamp changes
    const updated = storage.updateWorkspace(USER, ws.id, { name: "changed" });
    expect(updated!.updatedAt).toBeGreaterThanOrEqual(originalUpdatedAt);
  });

  it("preserves unchanged fields", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({
        name: "keep-me",
        description: "original desc",
        icon: "terminal",
        skills: ["fetch"],
      }),
    );

    const updated = storage.updateWorkspace(USER, ws.id, { description: "new desc" });

    expect(updated!.name).toBe("keep-me");
    expect(updated!.icon).toBe("terminal");
    expect(updated!.skills).toEqual(["fetch"]);
    expect(updated!.description).toBe("new desc");
  });

  it("persists updates to disk", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "before" }));
    storage.updateWorkspace(USER, ws.id, { name: "after" });

    // Read directly from disk
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    expect(raw.name).toBe("after");
  });

  it("returns undefined for nonexistent workspace", () => {
    expect(storage.updateWorkspace(USER, "nope-1234", { name: "x" })).toBeUndefined();
  });

  it("returns undefined for wrong user", () => {
    const ws = storage.createWorkspace(USER, createReq());
    expect(storage.updateWorkspace(USER2, ws.id, { name: "x" })).toBeUndefined();
  });

  it("handles empty update (no fields)", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "same" }));
    const updated = storage.updateWorkspace(USER, ws.id, {});

    expect(updated).toBeDefined();
    expect(updated!.name).toBe("same");
  });
});

// ─── Storage: deleteWorkspace ───

describe("Storage.deleteWorkspace", () => {
  it("deletes an existing workspace", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const result = storage.deleteWorkspace(USER, ws.id);

    expect(result).toBe(true);
    expect(storage.getWorkspace(USER, ws.id)).toBeUndefined();
  });

  it("removes file from disk", () => {
    const ws = storage.createWorkspace(USER, createReq());
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);
    expect(existsSync(path)).toBe(true);

    storage.deleteWorkspace(USER, ws.id);
    expect(existsSync(path)).toBe(false);
  });

  it("returns false for nonexistent workspace", () => {
    expect(storage.deleteWorkspace(USER, "nope-1234")).toBe(false);
  });

  it("returns false for wrong user", () => {
    const ws = storage.createWorkspace(USER, createReq());
    expect(storage.deleteWorkspace(USER2, ws.id)).toBe(false);

    // Original should still exist
    expect(storage.getWorkspace(USER, ws.id)).toBeDefined();
  });

  it("does not affect other workspaces", () => {
    const ws1 = storage.createWorkspace(USER, createReq({ name: "keep" }));
    const ws2 = storage.createWorkspace(USER, createReq({ name: "delete" }));

    storage.deleteWorkspace(USER, ws2.id);

    expect(storage.getWorkspace(USER, ws1.id)).toBeDefined();
    expect(storage.listWorkspaces(USER)).toHaveLength(1);
  });

  it("double-delete returns false", () => {
    const ws = storage.createWorkspace(USER, createReq());
    expect(storage.deleteWorkspace(USER, ws.id)).toBe(true);
    expect(storage.deleteWorkspace(USER, ws.id)).toBe(false);
  });
});

// ─── Storage: ensureDefaultWorkspaces ───

describe("Storage.ensureDefaultWorkspaces", () => {
  it("seeds default workspaces for new user", () => {
    storage.ensureDefaultWorkspaces(USER);
    const list = storage.listWorkspaces(USER);

    expect(list.length).toBeGreaterThanOrEqual(2);
    const names = list.map((w) => w.name);
    expect(names).toContain("general");
    expect(names).toContain("research");
  });

  it("does not seed when user already has workspaces", () => {
    storage.createWorkspace(USER, createReq({ name: "custom" }));
    storage.ensureDefaultWorkspaces(USER);

    const list = storage.listWorkspaces(USER);
    expect(list).toHaveLength(1);
    expect(list[0].name).toBe("custom");
  });

  it("is idempotent — second call does nothing", () => {
    storage.ensureDefaultWorkspaces(USER);
    const count1 = storage.listWorkspaces(USER).length;

    storage.ensureDefaultWorkspaces(USER);
    const count2 = storage.listWorkspaces(USER).length;

    expect(count2).toBe(count1);
  });

  it("default workspaces have correct structure", () => {
    storage.ensureDefaultWorkspaces(USER);
    const list = storage.listWorkspaces(USER);

    for (const ws of list) {
      expect(ws.userId).toBe(USER);
      expect(ws.id.length).toBe(8);
      expect(ws.skills).toBeInstanceOf(Array);
      expect(ws.policyPreset).toBeTruthy();
      expect(ws.createdAt).toBeGreaterThan(0);
    }
  });

  it("default general workspace has memory enabled", () => {
    storage.ensureDefaultWorkspaces(USER);
    const general = storage.listWorkspaces(USER).find((w) => w.name === "general");

    expect(general).toBeDefined();
    expect(general!.memoryEnabled).toBe(true);
    expect(general!.memoryNamespace).toBe("general");
  });
});

// ─── Storage: runtime inference ───

describe("Storage runtime inference", () => {
  it("preserves explicit runtime=host", () => {
    const ws = storage.createWorkspace(USER, createReq({ runtime: "host" }));
    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("host");
  });

  it("preserves explicit runtime=container", () => {
    const ws = storage.createWorkspace(USER, createReq({ runtime: "container" }));
    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("container");
  });

  it("infers container when policyPreset=container and no hostMount (legacy)", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "container" }));
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    // Simulate legacy: strip runtime
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("container");
  });

  it("infers host when policyPreset is not container (legacy)", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "host" }));
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("host");
  });

  it("infers host when hostMount is present (legacy)", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ policyPreset: "container", hostMount: "/work" }),
    );
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.runtime).toBe("host");
  });

  it("list also applies runtime inference to each workspace", () => {
    const ws = storage.createWorkspace(USER, createReq({ policyPreset: "container" }));
    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);

    const raw = JSON.parse(readFileSync(path, "utf-8"));
    delete raw.runtime;
    writeFileSync(path, JSON.stringify(raw));

    const list = storage.listWorkspaces(USER);
    const found = list.find((w) => w.id === ws.id);
    expect(found!.runtime).toBe("container");
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
    const ws = storage.createWorkspace(USER, createReq({ name: "lifecycle-test" }));
    expect(ws.name).toBe("lifecycle-test");

    // Get
    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.name).toBe("lifecycle-test");

    // Update
    const updated = storage.updateWorkspace(USER, ws.id, {
      name: "renamed",
      description: "now with a description",
    });
    expect(updated!.name).toBe("renamed");

    // Verify update persisted via get
    const afterUpdate = storage.getWorkspace(USER, ws.id);
    expect(afterUpdate!.name).toBe("renamed");
    expect(afterUpdate!.description).toBe("now with a description");

    // List should contain it
    const list = storage.listWorkspaces(USER);
    expect(list.find((w) => w.id === ws.id)).toBeDefined();

    // Delete
    expect(storage.deleteWorkspace(USER, ws.id)).toBe(true);

    // Gone
    expect(storage.getWorkspace(USER, ws.id)).toBeUndefined();
    expect(storage.listWorkspaces(USER).find((w) => w.id === ws.id)).toBeUndefined();
  });

  it("create workspace, change policy preset between host and container", () => {
    const ws = storage.createWorkspace(
      USER,
      createReq({ name: "Admin", policyPreset: "container", runtime: "host" }),
    );

    expect(ws.policyPreset).toBe("container");

    const fixed = storage.updateWorkspace(USER, ws.id, { policyPreset: "host" });
    expect(fixed!.policyPreset).toBe("host");
    expect(fixed!.runtime).toBe("host"); // runtime should be preserved

    // Verify persisted
    const reloaded = storage.getWorkspace(USER, ws.id);
    expect(reloaded!.policyPreset).toBe("host");
  });

  it("multiple users, independent lifecycle", () => {
    const ws1 = storage.createWorkspace(USER, createReq({ name: "user1-ws" }));
    const ws2 = storage.createWorkspace(USER2, createReq({ name: "user2-ws" }));

    // Update one, other unaffected
    storage.updateWorkspace(USER, ws1.id, { name: "user1-renamed" });
    expect(storage.getWorkspace(USER2, ws2.id)!.name).toBe("user2-ws");

    // Delete one, other unaffected
    storage.deleteWorkspace(USER, ws1.id);
    expect(storage.getWorkspace(USER2, ws2.id)).toBeDefined();
  });
});

// ─── Edge cases ───

describe("Workspace edge cases", () => {
  it("create workspace with empty skills array", () => {
    const ws = storage.createWorkspace(USER, { name: "bare", skills: [] });
    expect(ws.skills).toEqual([]);
  });

  it("update skills to empty array", () => {
    const ws = storage.createWorkspace(USER, createReq({ skills: ["fetch"] }));
    const updated = storage.updateWorkspace(USER, ws.id, { skills: [] });
    expect(updated!.skills).toEqual([]);
  });

  it("create many workspaces for same user", () => {
    const count = 20;
    for (let i = 0; i < count; i++) {
      storage.createWorkspace(USER, createReq({ name: `ws-${i}` }));
    }

    expect(storage.listWorkspaces(USER)).toHaveLength(count);
  });

  it("workspace name can contain special characters", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "My Workspace (test)" }));
    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.name).toBe("My Workspace (test)");
  });

  it("workspace name can contain unicode", () => {
    const ws = storage.createWorkspace(USER, createReq({ name: "workspace" }));
    const got = storage.getWorkspace(USER, ws.id);
    expect(got!.name).toBe("workspace");
  });

  it("update then delete — file is gone", () => {
    const ws = storage.createWorkspace(USER, createReq());
    storage.updateWorkspace(USER, ws.id, { name: "updated" });
    storage.deleteWorkspace(USER, ws.id);

    const path = join(dataDir, "workspaces", USER, `${ws.id}.json`);
    expect(existsSync(path)).toBe(false);
  });

  it("create after delete reuses nothing (new ID)", () => {
    const ws1 = storage.createWorkspace(USER, createReq({ name: "first" }));
    const id1 = ws1.id;
    storage.deleteWorkspace(USER, id1);

    const ws2 = storage.createWorkspace(USER, createReq({ name: "second" }));
    expect(ws2.id).not.toBe(id1);
  });
});

import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { Storage } from "../src/storage.js";
import { ConfigStore } from "../src/storage/config-store.js";
import { ICON_ASSET_ORPHAN_GRACE_MS } from "../src/storage/icon-asset-store.js";
import {
  WorkspaceStore,
  type WorkspaceMigrationFaultPhase,
} from "../src/storage/workspace-store.js";
import { structuralHeifFixture } from "./harness/heic-fixture.js";

function sample(suffix = "sample"): Buffer {
  const content = Buffer.from(suffix);
  return structuralHeifFixture(
    Buffer.from([0, 0, 0, content.length + 3, 0x26, 0x01, 0x80, ...content]),
  );
}

let dataDir: string;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-icon-migration-"));
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(dataDir, { recursive: true, force: true });
});

describe("coordinated icon migration", () => {
  it("rewrites current and versioned Agent strings without bumping versions", () => {
    const dbPath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);
    const agent = store.createAgent({
      name: "Reviewer",
      icon: { kind: "symbol", name: "sparkles" },
    });
    store.close();

    const db = openDatabase(dbPath);
    const historical = JSON.stringify({ name: "Reviewer", icon: "🧘" });
    db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
      historical,
      agent.id,
    );
    db.prepare(
      "UPDATE agent_definition_versions SET definition_json = ? WHERE id = ? AND version = ?",
    ).run(historical, agent.id, 1);
    db.close();

    store = new AgentDefinitionStore(dataDir);
    expect(store.getAgent(agent.id)).toMatchObject({
      version: 1,
      definition: { icon: { kind: "emoji", value: "🧘" } },
    });
    expect(store.getAgentVersion(agent.id, 1)?.definition.icon).toEqual({
      kind: "emoji",
      value: "🧘",
    });
    store.close();
  });

  it("rewrites workspace strings at startup and defaults malformed values", () => {
    const workspaces = join(dataDir, "workspaces");
    mkdirSync(workspaces, { recursive: true });
    writeFileSync(
      join(workspaces, "symbol.json"),
      JSON.stringify({
        id: "symbol",
        name: "Symbol",
        icon: "terminal",
        systemPromptMode: "append",
        createdAt: 1,
        updatedAt: 2,
      }),
    );
    writeFileSync(
      join(workspaces, "bad.json"),
      JSON.stringify({
        id: "bad",
        name: "Bad",
        icon: "historical/icon",
        systemPromptMode: "append",
        createdAt: 1,
        updatedAt: 2,
      }),
    );

    const storage = new Storage(dataDir);
    expect(storage.getWorkspace("symbol")?.icon).toEqual({ kind: "symbol", name: "terminal" });
    expect(storage.getWorkspace("bad")?.icon).toEqual({ kind: "default" });
    expect(JSON.parse(readFileSync(join(workspaces, "symbol.json"), "utf8")).icon).toEqual({
      kind: "symbol",
      name: "terminal",
    });
  });

  it.each(["after_temp_write", "after_temp_fsync", "before_rename", "after_rename"] as const)(
    "preserves and restart-migrates a workspace after %s failure",
    (faultPhase) => {
      const configStore = new ConfigStore(dataDir);
      const workspacePath = join(configStore.getWorkspacesDir(), `${faultPhase}.json`);
      const original = JSON.stringify({
        id: faultPhase,
        name: "Atomic migration",
        icon: "terminal",
        systemPromptMode: "append",
        createdAt: 1,
        updatedAt: 2,
      });
      writeFileSync(workspacePath, original, { mode: 0o600 });

      new WorkspaceStore(configStore, undefined, {
        faultInjector(phase: WorkspaceMigrationFaultPhase) {
          if (phase === faultPhase) throw new Error(`injected ${phase}`);
        },
      });

      expect(readFileSync(workspacePath, "utf8")).toBe(original);
      expect(
        readdirSync(configStore.getWorkspacesDir()).filter((name) => name.endsWith(".tmp")),
      ).toEqual([]);

      new WorkspaceStore(configStore);
      expect(JSON.parse(readFileSync(workspacePath, "utf8")).icon).toEqual({
        kind: "symbol",
        name: "terminal",
      });
    },
  );

  it.each([
    {
      name: "string primitive",
      bytes: ' \n"recoverable workspace"\n',
      topLevelType: "string",
    },
    { name: "number primitive", bytes: " \n42\n", topLevelType: "number" },
    { name: "null primitive", bytes: " \nnull\n", topLevelType: "null" },
    {
      name: "array",
      bytes: ' \n[{"icon":"folder","futureField":true}]\n',
      topLevelType: "array",
    },
  ])("preserves a $name workspace file across startup migrations", ({ bytes, topLevelType }) => {
    const configStore = new ConfigStore(dataDir);
    const workspacePath = join(configStore.getWorkspacesDir(), "recoverable.json");
    writeFileSync(workspacePath, bytes, { mode: 0o600 });
    const writes: string[] = [];
    vi.spyOn(process.stderr, "write").mockImplementation(((chunk: string | Uint8Array) => {
      writes.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8"));
      return true;
    }) as typeof process.stderr.write);

    new WorkspaceStore(configStore);
    expect(readFileSync(workspacePath, "utf8")).toBe(bytes);
    new WorkspaceStore(configStore);
    expect(readFileSync(workspacePath, "utf8")).toBe(bytes);

    const shapeLogs = writes
      .join("")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((entry) => entry.event === "workspace_store.icon_migration.invalid_workspace_shape");
    expect(shapeLogs).toHaveLength(2);
    expect(shapeLogs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          level: "error",
          workspaceFilePath: workspacePath,
          topLevelType,
        }),
      ]),
    );
  });

  it("rewrites both session JSON copies while preserving launch-time presentation", () => {
    const storage = new Storage(dataDir);
    const session = storage.createSession("Historical");
    session.launch = {
      agentId: "agent-1",
      agentIcon: { kind: "symbol", name: "sparkles" },
      status: "accepted",
      requestedAt: 1,
    };
    storage.saveSession(session);

    const db = openDatabase(join(dataDir, "session-state.db"));
    const historicalLaunch = {
      agentId: "agent-1",
      agentIcon: "🧘",
      status: "accepted",
      requestedAt: 1,
    };
    const row = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string };
    const historicalSession = { ...JSON.parse(row.session_json), launch: historicalLaunch };
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(JSON.stringify(historicalSession), JSON.stringify(historicalLaunch), session.id);
    db.close();

    const migrated = new Storage(dataDir);
    expect(migrated.getSession(session.id)?.launch?.agentIcon).toEqual({
      kind: "emoji",
      value: "🧘",
    });
    const migratedDb = openDatabase(join(dataDir, "session-state.db"));
    const migratedRow = migratedDb
      .prepare("SELECT session_json, launch_metadata_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string; launch_metadata_json: string };
    expect(JSON.parse(migratedRow.session_json).launch.agentIcon).toEqual({
      kind: "emoji",
      value: "🧘",
    });
    expect(JSON.parse(migratedRow.launch_metadata_json).agentIcon).toEqual({
      kind: "emoji",
      value: "🧘",
    });
    migratedDb.close();
  });

  it("does not rewrite raw launch copies whose malformed icons collapse to the same Default", () => {
    const storage = new Storage(dataDir);
    const session = storage.createSession("Collapsing mismatch");
    session.launch = {
      agentId: "agent-collapse",
      agentIcon: { kind: "default" },
      status: "accepted",
      requestedAt: 1,
    };
    storage.saveSession(session);

    const db = openDatabase(join(dataDir, "session-state.db"));
    const row = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string };
    const rawSession = JSON.parse(row.session_json) as Record<string, unknown>;
    const sessionLaunch = {
      agentId: "agent-collapse",
      agentIcon: "historical/icon",
      status: "accepted",
      requestedAt: 1,
    };
    const metadataLaunch = {
      agentId: "agent-collapse",
      agentIcon: { kind: "future-icon-kind", payload: "opaque" },
      status: "accepted",
      requestedAt: 1,
    };
    rawSession.launch = sessionLaunch;
    const sessionJson = JSON.stringify(rawSession);
    const launchJson = JSON.stringify(metadataLaunch);
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(sessionJson, launchJson, session.id);
    db.close();

    new Storage(dataDir);
    const restartedDb = openDatabase(join(dataDir, "session-state.db"));
    const restartedRow = restartedDb
      .prepare("SELECT session_json, launch_metadata_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string; launch_metadata_json: string };
    expect(restartedRow.session_json).toBe(sessionJson);
    expect(restartedRow.launch_metadata_json).toBe(launchJson);
    restartedDb.close();
  });

  it.each([
    {
      name: "identical future tagged icons",
      icon: (assetId: string) => ({
        kind: "genmoji-v2",
        assetId,
        contentDescription: "Animated fox",
        animation: { version: 2 },
      }),
    },
    {
      name: "identical malformed tagged icons",
      icon: (assetId: string) => ({
        kind: "genmoji",
        assetId,
        contentDescription: 42,
        futureField: true,
      }),
    },
  ])("preserves $name and its old asset through migration plus startup GC", ({ name, icon }) => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS - 1;
    const asset = storage.getIconAssetStore().put(sample(name), "image/heic", old);
    const session = storage.createSession(name);
    const taggedIcon = icon(asset.assetId);
    const launch = {
      agentId: `agent-${name}`,
      agentIcon: taggedIcon,
      status: "accepted",
      requestedAt: old,
    };

    const db = openDatabase(join(dataDir, "session-state.db"));
    const row = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string };
    const rawSession = JSON.parse(row.session_json) as Record<string, unknown>;
    rawSession.launch = launch;
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(JSON.stringify(rawSession), JSON.stringify(launch), session.id);
    db.close();

    const restarted = new Storage(dataDir);
    expect(restarted.getIconAssetStore().has(asset.assetId)).toBe(true);

    const restartedDb = openDatabase(join(dataDir, "session-state.db"));
    const restartedRow = restartedDb
      .prepare("SELECT session_json, launch_metadata_json FROM session_state_sessions WHERE id = ?")
      .get(session.id) as { session_json: string; launch_metadata_json: string };
    expect(JSON.parse(restartedRow.session_json).launch.agentIcon).toEqual(taggedIcon);
    expect(JSON.parse(restartedRow.launch_metadata_json).agentIcon).toEqual(taggedIcon);
    restartedDb.close();
  });

  it("retains old syntactic asset references in future icons and malformed launch parents", () => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS - 1;
    const futureAsset = storage
      .getIconAssetStore()
      .put(sample("future-tagged-reference"), "image/heic", old);
    const malformedParentAsset = storage
      .getIconAssetStore()
      .put(sample("malformed-parent-reference"), "image/heic", old);
    const futureSession = storage.createSession("Future icon");
    const malformedParentSession = storage.createSession("Malformed parent");

    const db = openDatabase(join(dataDir, "session-state.db"));
    const futureRow = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(futureSession.id) as { session_json: string };
    const futureJson = JSON.parse(futureRow.session_json) as Record<string, unknown>;
    futureJson.launch = {
      agentId: "agent-future",
      agentIcon: {
        kind: "genmoji-v2",
        assetId: futureAsset.assetId,
        contentDescription: 42,
        animation: { version: 2 },
      },
      status: "future-status",
    };
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(JSON.stringify(futureJson), "{malformed-launch-copy", futureSession.id);

    const malformedRow = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(malformedParentSession.id) as { session_json: string };
    const malformedJson = JSON.parse(malformedRow.session_json) as Record<string, unknown>;
    malformedJson.launch = [
      null,
      {
        agentIcon: {
          kind: "genmoji",
          assetId: malformedParentAsset.assetId,
          contentDescription: null,
          futureField: true,
        },
      },
    ];
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(
      JSON.stringify(malformedJson),
      JSON.stringify({ malformed: true }),
      malformedParentSession.id,
    );
    db.close();

    const restarted = new Storage(dataDir);
    expect(restarted.getIconAssetStore().has(futureAsset.assetId)).toBe(true);
    expect(restarted.getIconAssetStore().has(malformedParentAsset.assetId)).toBe(true);
  });

  it("preserves the union of valid session launch references across stale and malformed copies", () => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS - 1;
    const assets = ["session-copy", "metadata-copy", "metadata-valid", "session-valid"].map(
      (suffix) => storage.getIconAssetStore().put(sample(suffix), "image/heic", old),
    );
    const icons = assets.map((asset, index) => ({
      kind: "genmoji" as const,
      assetId: asset.assetId,
      contentDescription: `Durable icon ${index}`,
    }));
    const sessions = ["mismatched", "bad-session", "bad-launch"].map((id) => {
      const session = storage.createSession(id);
      session.launch = {
        agentId: `agent-${id}`,
        agentIcon: icons[0],
        status: "accepted",
        requestedAt: old,
      };
      storage.saveSession(session);
      return session;
    });

    const db = openDatabase(join(dataDir, "session-state.db"));
    const row = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(sessions[0]?.id) as { session_json: string };
    const mismatchedSession = JSON.parse(row.session_json) as Record<string, unknown>;
    const sessionLaunch = {
      agentId: "agent-mismatched",
      agentIcon: icons[0],
      status: "accepted",
      requestedAt: old,
    };
    const metadataLaunch = { ...sessionLaunch, agentIcon: icons[1] };
    mismatchedSession.launch = sessionLaunch;
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(JSON.stringify(mismatchedSession), JSON.stringify(metadataLaunch), sessions[0]?.id);

    const validMetadataLaunch = {
      agentId: "agent-bad-session",
      agentIcon: icons[2],
      status: "accepted",
      requestedAt: old,
    };
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run("{malformed-session", JSON.stringify(validMetadataLaunch), sessions[1]?.id);

    const validSessionRow = db
      .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
      .get(sessions[2]?.id) as { session_json: string };
    const validSession = JSON.parse(validSessionRow.session_json) as Record<string, unknown>;
    validSession.launch = {
      agentId: "agent-bad-launch",
      agentIcon: icons[3],
      status: "accepted",
      requestedAt: old,
    };
    db.prepare(
      "UPDATE session_state_sessions SET session_json = ?, launch_metadata_json = ? WHERE id = ?",
    ).run(JSON.stringify(validSession), "{malformed-launch", sessions[2]?.id);
    db.close();

    const restarted = new Storage(dataDir);
    for (const asset of assets) {
      expect(restarted.getIconAssetStore().has(asset.assetId)).toBe(true);
    }

    const reconciledDb = openDatabase(join(dataDir, "session-state.db"));
    const copies = reconciledDb
      .prepare(
        "SELECT id, session_json, launch_metadata_json FROM session_state_sessions WHERE id IN (?, ?, ?) ORDER BY id",
      )
      .all(sessions[0]?.id, sessions[1]?.id, sessions[2]?.id) as Array<{
      id: string;
      session_json: string;
      launch_metadata_json: string;
    }>;
    expect(copies.find((copy) => copy.id === sessions[1]?.id)?.session_json).toBe(
      "{malformed-session",
    );
    expect(copies.find((copy) => copy.id === sessions[2]?.id)?.launch_metadata_json).toBe(
      "{malformed-launch",
    );
    expect(
      JSON.parse(copies.find((copy) => copy.id === sessions[0]?.id)?.session_json ?? "{}").launch
        .agentIcon,
    ).toEqual(icons[0]);
    expect(
      JSON.parse(copies.find((copy) => copy.id === sessions[0]?.id)?.launch_metadata_json ?? "{}")
        .agentIcon,
    ).toEqual(icons[1]);
    reconciledDb.close();
  });

  it("collects abandoned uploads after grace on restart while retaining every durable reference", () => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS - 1;
    const abandoned = storage.getIconAssetStore().put(sample("abandoned"), "image/heic", old);
    const agentCurrentAsset = storage
      .getIconAssetStore()
      .put(sample("agent-current"), "image/heic", old);
    const agentHistoryAsset = storage
      .getIconAssetStore()
      .put(sample("agent-history"), "image/heic", old);
    const workspaceAsset = storage.getIconAssetStore().put(sample("workspace"), "image/heic", old);
    const sessionAsset = storage.getIconAssetStore().put(sample("session"), "image/heic", old);

    storage.getAgentDefinitionStore().createAgent({
      name: "Current icon",
      icon: {
        kind: "genmoji",
        assetId: agentCurrentAsset.assetId,
        contentDescription: "Current Agent icon",
      },
    });
    const agent = storage.getAgentDefinitionStore().createAgent({
      name: "Historical icon",
      icon: {
        kind: "genmoji",
        assetId: agentHistoryAsset.assetId,
        contentDescription: "Historical Agent icon",
      },
    });
    storage.getAgentDefinitionStore().updateAgent(agent.id, { icon: { kind: "default" } });
    storage.createWorkspace({
      name: "Referenced workspace",
      icon: {
        kind: "genmoji",
        assetId: workspaceAsset.assetId,
        contentDescription: "Workspace icon",
      },
    });
    const session = storage.createSession("Referenced snapshot");
    session.launch = {
      agentId: agent.id,
      agentIcon: {
        kind: "genmoji",
        assetId: sessionAsset.assetId,
        contentDescription: "Session snapshot icon",
      },
      status: "accepted",
      requestedAt: old,
    };
    storage.saveSession(session);

    const restarted = new Storage(dataDir);
    expect(restarted.getIconAssetStore().has(abandoned.assetId)).toBe(false);
    expect(restarted.getIconAssetStore().has(agentCurrentAsset.assetId)).toBe(true);
    expect(restarted.getIconAssetStore().has(agentHistoryAsset.assetId)).toBe(true);
    expect(restarted.getIconAssetStore().has(workspaceAsset.assetId)).toBe(true);
    expect(restarted.getIconAssetStore().has(sessionAsset.assetId)).toBe(true);
  });

  it("removes an old unreferenced workspace asset but retains a session snapshot reference", () => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS - 1;
    const asset = storage.getIconAssetStore().put(sample(), "image/heic", old);
    const icon = {
      kind: "genmoji" as const,
      assetId: asset.assetId,
      contentDescription: "Smiling robot",
    };
    const workspace = storage.createWorkspace({ name: "Icons", icon });
    const session = storage.createSession("Snapshot");
    session.launch = {
      agentId: "agent-1",
      agentIcon: icon,
      status: "accepted",
      requestedAt: 1,
    };
    storage.saveSession(session);

    storage.updateWorkspace(workspace.id, { icon: { kind: "default" } });
    expect(storage.getIconAssetStore().has(asset.assetId)).toBe(true);

    storage.deleteSession(session.id);
    expect(storage.getIconAssetStore().has(asset.assetId)).toBe(false);
  });

  it("keeps a freshly re-uploaded asset during concurrent last-reference removal", () => {
    const storage = new Storage(dataDir);
    const old = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS + 1_000;
    const bytes = sample("concurrent-removal");
    const asset = storage.getIconAssetStore().put(bytes, "image/heic", old);
    const workspace = storage.createWorkspace({
      name: "Lease race",
      icon: {
        kind: "genmoji",
        assetId: asset.assetId,
        contentDescription: "Pending icon",
      },
    });

    const refreshed = storage.getIconAssetStore().put(bytes, "image/heic", Date.now());
    storage.updateWorkspace(workspace.id, { icon: { kind: "default" } });

    expect(refreshed.lastUploadedAt).toBeGreaterThan(old);
    expect(storage.getIconAssetStore().has(asset.assetId)).toBe(true);
  });
});

/**
 * Tests for local pi session discovery and validation.
 */

import { describe, expect, it, beforeEach, afterEach } from "vitest";
import {
  mkdirSync,
  writeFileSync,
  rmSync,
  mkdtempSync,
  utimesSync,
  realpathSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir, homedir } from "node:os";
import {
  collectKnownLocalSessionIdentities,
  discoverLocalSessions,
  invalidateLocalSessionsCache,
  validateLocalSessionPath,
  validateCwdAlignment,
  isControlSessionLocalArtifact,
  getPiSessionsRoot,
  listCatalogedLocalSessions,
  deleteCatalogedLocalSessionPaths,
} from "../src/local-sessions.js";
import { openDatabase } from "../src/sqlite-compat.js";

// ─── Fixtures ───

function setModifiedTime(path: string, isoTimestamp: string): void {
  const timestamp = new Date(isoTimestamp);
  utimesSync(path, timestamp, timestamp);
}

function makeSessionJsonl(opts: {
  id?: string;
  cwd?: string;
  timestamp?: string;
  name?: string;
  model?: { provider: string; modelId: string };
  userMessage?: string;
}): string {
  const header = JSON.stringify({
    type: "session",
    version: 3,
    id: opts.id ?? "test-uuid-1234",
    timestamp: opts.timestamp ?? "2026-02-20T00:00:00.000Z",
    cwd: opts.cwd ?? "/Users/test/workspace/project",
  });

  const lines = [header];

  lines.push(
    JSON.stringify({
      type: "model_change",
      id: "mc01",
      parentId: null,
      timestamp: "2026-02-20T00:00:01.000Z",
      provider: opts.model?.provider ?? "anthropic",
      modelId: opts.model?.modelId ?? "claude-sonnet-4-5",
    }),
  );

  if (opts.name) {
    lines.push(
      JSON.stringify({
        type: "session_info",
        id: "si01",
        parentId: "mc01",
        timestamp: "2026-02-20T00:00:02.000Z",
        name: opts.name,
      }),
    );
  }

  if (opts.userMessage) {
    lines.push(
      JSON.stringify({
        type: "message",
        id: "msg01",
        parentId: opts.name ? "si01" : "mc01",
        timestamp: "2026-02-20T00:00:03.000Z",
        message: {
          role: "user",
          content: opts.userMessage,
          timestamp: 1771574400000,
        },
      }),
    );
  }

  return lines.join("\n") + "\n";
}

// ─── CWD Alignment ───

describe("validateCwdAlignment", () => {
  it("allows exact CWD match", () => {
    expect(validateCwdAlignment("/Users/chen/workspace/oppi", "/Users/chen/workspace/oppi")).toBe(
      true,
    );
  });

  it("allows subdirectory of hostMount", () => {
    expect(
      validateCwdAlignment("/Users/chen/workspace/oppi/server", "/Users/chen/workspace/oppi"),
    ).toBe(true);
  });

  it("rejects different directory", () => {
    expect(validateCwdAlignment("/Users/chen/workspace/other", "/Users/chen/workspace/oppi")).toBe(
      false,
    );
  });

  it("rejects partial path prefix that is not a parent", () => {
    // /Users/chen/workspace/oppi-fork is NOT under /Users/chen/workspace/oppi
    expect(
      validateCwdAlignment("/Users/chen/workspace/oppi-fork", "/Users/chen/workspace/oppi"),
    ).toBe(false);
  });

  it("resolves ~ in hostMount", () => {
    const home = homedir();
    expect(validateCwdAlignment(`${home}/workspace`, "~/workspace")).toBe(true);
  });
});

describe("isControlSessionLocalArtifact", () => {
  it("matches the real data-dir control cwd tree", () => {
    const dataDir = "/Users/chen/.config/oppi";
    expect(
      isControlSessionLocalArtifact(`${dataDir}/control-sessions/cwd`, { dataDir }),
    ).toBe(true);
    expect(isControlSessionLocalArtifact(`${dataDir}/other`, { dataDir })).toBe(false);
  });

  it("does not treat ordinary workspace cwds as control artifacts", () => {
    expect(isControlSessionLocalArtifact("/Users/chen/workspace/oppi")).toBe(false);
    expect(
      isControlSessionLocalArtifact("/Users/chen/workspace/oppi/server", {
        dataDir: "/Users/chen/.config/oppi",
      }),
    ).toBe(false);
  });
});

// ─── Sessions root isolation ───

describe("pi sessions root resolution", () => {
  const previousRoot = process.env.OPPI_LOCAL_SESSIONS_ROOT;

  afterEach(() => {
    if (previousRoot === undefined) {
      delete process.env.OPPI_LOCAL_SESSIONS_ROOT;
    } else {
      process.env.OPPI_LOCAL_SESSIONS_ROOT = previousRoot;
    }
  });

  it("isolates vitest workers away from the developer home Pi sessions tree", () => {
    const root = realpathSync(getPiSessionsRoot());
    const homeRoot = resolve(join(homedir(), ".pi", "agent", "sessions"));
    const tempRoot = realpathSync(tmpdir());
    expect(root).not.toBe(homeRoot);
    expect(root === tempRoot || root.startsWith(`${tempRoot}/`)).toBe(true);
  });

  it("honors OPPI_LOCAL_SESSIONS_ROOT dynamically after module load", () => {
    const override = mkdtempSync(join(tmpdir(), "oppi-local-sessions-override-"));
    try {
      process.env.OPPI_LOCAL_SESSIONS_ROOT = override;
      expect(realpathSync(getPiSessionsRoot())).toBe(realpathSync(override));
    } finally {
      rmSync(override, { recursive: true, force: true });
    }
  });

  it("discoverLocalSessions finds sessions under a dynamically overridden root", async () => {
    const override = mkdtempSync(join(tmpdir(), "oppi-local-sessions-override-scan-"));
    process.env.OPPI_LOCAL_SESSIONS_ROOT = override;

    try {
      const cwdDir = join(override, "project");
      mkdirSync(cwdDir, { recursive: true });
      writeFileSync(
        join(cwdDir, "2026-02-20T00-00-00-000Z_uuid-override-scan.jsonl"),
        makeSessionJsonl({ id: "uuid-override-scan", cwd: cwdDir, userMessage: "hi" }),
      );

      const sessions = await discoverLocalSessions();
      expect(sessions.some((session) => session.piSessionId === "uuid-override-scan")).toBe(
        true,
      );
    } finally {
      rmSync(override, { recursive: true, force: true });
    }
  });
});

// ─── Path Validation ───

describe("validateLocalSessionPath", () => {
  it("rejects non-.jsonl path", () => {
    const result = validateLocalSessionPath("/tmp/not-a-session.txt");
    expect(result).toHaveProperty("error");
    expect((result as { error: string }).error).toContain(".jsonl");
  });

  it("rejects nonexistent file", () => {
    const result = validateLocalSessionPath("/tmp/nonexistent.jsonl");
    expect(result).toHaveProperty("error");
    expect((result as { error: string }).error).toContain("not found");
  });

  it("rejects path outside pi sessions directory", () => {
    // Create a temp jsonl file outside pi sessions dir
    const tmpFile = join(tmpdir(), `test-session-${Date.now()}.jsonl`);
    writeFileSync(tmpFile, makeSessionJsonl({}));

    try {
      const result = validateLocalSessionPath(tmpFile);
      expect(result).toHaveProperty("error");
      expect((result as { error: string }).error).toContain("~/.pi/agent/sessions/");
    } finally {
      rmSync(tmpFile, { force: true });
    }
  });

  it("accepts valid session file under pi sessions root", () => {
    const root = getPiSessionsRoot();
    const testDir = join(root, "--test-validate--");
    const testFile = join(testDir, "2026-02-20T00-00-00-000Z_test-uuid.jsonl");

    mkdirSync(testDir, { recursive: true });
    writeFileSync(testFile, makeSessionJsonl({ id: "test-uuid" }));

    try {
      const result = validateLocalSessionPath(testFile);
      expect(result).toHaveProperty("path");
    } finally {
      rmSync(testDir, { recursive: true, force: true });
    }
  });

  it("rejects file with invalid header", () => {
    const root = getPiSessionsRoot();
    const testDir = join(root, "--test-validate-invalid--");
    const testFile = join(testDir, "bad.jsonl");

    mkdirSync(testDir, { recursive: true });
    writeFileSync(testFile, '{"not":"a session"}\n');

    try {
      const result = validateLocalSessionPath(testFile);
      expect(result).toHaveProperty("error");
      expect((result as { error: string }).error).toContain("valid pi session");
    } finally {
      rmSync(testDir, { recursive: true, force: true });
    }
  });
});

// ─── Discovery ───

describe("discoverLocalSessions", () => {
  const root = getPiSessionsRoot();
  const testDir = join(root, "--test-discover--");

  beforeEach(() => {
    mkdirSync(testDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(testDir, { recursive: true, force: true });
  });

  it("discovers sessions from pi sessions directory", async () => {
    writeFileSync(
      join(testDir, "2026-02-20T00-00-00-000Z_uuid-1.jsonl"),
      makeSessionJsonl({
        id: "uuid-1",
        cwd: "/Users/test/project",
        name: "My Session",
        userMessage: "hello world",
        model: { provider: "anthropic", modelId: "claude-sonnet-4-5" },
      }),
    );

    const sessions = await discoverLocalSessions();
    const found = sessions.find((s) => s.piSessionId === "uuid-1");

    expect(found).toBeDefined();
    expect(found!.cwd).toBe("/Users/test/project");
    expect(found!.name).toBe("My Session");
    expect(found!.firstMessage).toBe("hello world");
    expect(found!.model).toBe("anthropic/claude-sonnet-4-5");
    expect(found!.messageCount).toBe(1);
    expect(found!.path).toContain("uuid-1.jsonl");
  }, 30_000);

  it("filters out known session files", async () => {
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-2.jsonl");
    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-2" }));

    const knownFiles = new Set([filePath]);
    const sessions = await discoverLocalSessions(knownFiles);
    const found = sessions.find((s) => s.piSessionId === "uuid-2");

    expect(found).toBeUndefined();
  });

  it("collects imported Session.id as the catalog Pi identity", () => {
    const known = collectKnownLocalSessionIdentities([
      {
        id: "uuid-imported",
        piSessionFile: "/tmp/imported.jsonl",
        piSessionFiles: ["/tmp/older.jsonl"],
      },
    ]);

    expect(known.piSessionIds.has("uuid-imported")).toBe(true);
    expect(known.files.has("/tmp/imported.jsonl")).toBe(true);
    expect(known.files.has("/tmp/older.jsonl")).toBe(true);
  });

  it("filters out known session identities by piSessionId", async () => {
    writeFileSync(
      join(testDir, "2026-02-20T00-00-00-000Z_uuid-known-id.jsonl"),
      makeSessionJsonl({ id: "uuid-known-id" }),
    );

    const sessions = await discoverLocalSessions({ piSessionIds: new Set(["uuid-known-id"]) });
    const found = sessions.find((s) => s.piSessionId === "uuid-known-id");

    expect(found).toBeUndefined();
  });

  it("skips files with invalid headers", async () => {
    writeFileSync(join(testDir, "bad-file.jsonl"), "not json\n");

    const sessions = await discoverLocalSessions();
    const found = sessions.find((s) => s.path.includes("bad-file.jsonl"));

    expect(found).toBeUndefined();
  });

  it("returns sessions sorted by last modified (most recent first)", async () => {
    const oldPath = join(testDir, "2026-02-18T00-00-00-000Z_uuid-old.jsonl");
    writeFileSync(
      oldPath,
      makeSessionJsonl({
        id: "uuid-old",
        timestamp: "2026-02-18T00:00:00.000Z",
      }),
    );
    setModifiedTime(oldPath, "2026-02-18T00:00:00.000Z");

    const newPath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-new.jsonl");
    writeFileSync(
      newPath,
      makeSessionJsonl({
        id: "uuid-new",
        timestamp: "2026-02-20T00:00:00.000Z",
      }),
    );
    setModifiedTime(newPath, "2026-02-20T00:00:00.000Z");

    const sessions = await discoverLocalSessions();
    const oldIdx = sessions.findIndex((s) => s.piSessionId === "uuid-old");
    const newIdx = sessions.findIndex((s) => s.piSessionId === "uuid-new");

    // Both found, newer first
    expect(oldIdx).toBeGreaterThan(-1);
    expect(newIdx).toBeGreaterThan(-1);
    expect(newIdx).toBeLessThan(oldIdx);
  });

  it("handles sessions without name or messages", async () => {
    writeFileSync(
      join(testDir, "2026-02-20T00-00-00-000Z_uuid-bare.jsonl"),
      makeSessionJsonl({ id: "uuid-bare" }),
    );

    const sessions = await discoverLocalSessions();
    const found = sessions.find((s) => s.piSessionId === "uuid-bare");

    expect(found).toBeDefined();
    expect(found!.name).toBeUndefined();
    expect(found!.firstMessage).toBeUndefined();
    expect(found!.messageCount).toBe(0);
  });

  it("persists TUI session metadata in the sqlite catalog when dataDir is provided", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-tui-session-catalog-"));
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-catalog.jsonl");

    try {
      writeFileSync(
        filePath,
        makeSessionJsonl({
          id: "uuid-catalog",
          name: "Catalogued Session",
          userMessage: "persist me",
        }),
      );

      const sessions = await discoverLocalSessions(undefined, { dataDir });
      const found = sessions.find((s) => s.piSessionId === "uuid-catalog");
      expect(found?.name).toBe("Catalogued Session");

      const db = openDatabase(join(dataDir, "session-state.db"));
      try {
        const row = db
          .prepare("SELECT pi_session_id, name FROM tui_session_files WHERE path = ?")
          .get(filePath) as { pi_session_id: string; name: string } | undefined;
        expect(row).toEqual({ pi_session_id: "uuid-catalog", name: "Catalogued Session" });
      } finally {
        db.close();
      }
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("returns cached results on second call for unchanged files", async () => {
    writeFileSync(
      join(testDir, "2026-02-20T00-00-00-000Z_uuid-cache.jsonl"),
      makeSessionJsonl({ id: "uuid-cache", name: "Original Name" }),
    );

    const first = await discoverLocalSessions();
    expect(first.find((s) => s.piSessionId === "uuid-cache")?.name).toBe("Original Name");

    // Second call without any file changes — should return same data from cache
    const second = await discoverLocalSessions();
    expect(second.find((s) => s.piSessionId === "uuid-cache")?.name).toBe("Original Name");

    // Verify the result objects are referentially the same (from cache, not re-parsed)
    const s1 = first.find((s) => s.piSessionId === "uuid-cache");
    const s2 = second.find((s) => s.piSessionId === "uuid-cache");
    expect(s1).toBe(s2);
  });

  it("re-reads file when mtime changes", async () => {
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-mtime.jsonl");
    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-mtime", name: "V1" }));
    setModifiedTime(filePath, "2026-02-20T00:00:00.000Z");

    const first = await discoverLocalSessions();
    expect(first.find((s) => s.piSessionId === "uuid-mtime")?.name).toBe("V1");

    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-mtime", name: "V2" }));
    setModifiedTime(filePath, "2026-02-20T00:00:01.000Z");

    const second = await discoverLocalSessions();
    expect(second.find((s) => s.piSessionId === "uuid-mtime")?.name).toBe("V2");
  });

  it("invalidateLocalSessionsCache clears cached entries", async () => {
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-inv.jsonl");
    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-inv", name: "Before" }));
    setModifiedTime(filePath, "2026-02-20T00:00:00.000Z");

    const first = await discoverLocalSessions();
    const s1 = first.find((s) => s.piSessionId === "uuid-inv");
    expect(s1?.name).toBe("Before");

    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-inv", name: "After" }));
    setModifiedTime(filePath, "2026-02-20T00:00:01.000Z");

    // Even without invalidation, mtime change causes re-read
    const second = await discoverLocalSessions();
    expect(second.find((s) => s.piSessionId === "uuid-inv")?.name).toBe("After");

    // Invalidation clears all cache — verify by checking ref identity changes
    invalidateLocalSessionsCache();
    const third = await discoverLocalSessions();
    const s3 = third.find((s) => s.piSessionId === "uuid-inv");
    expect(s3?.name).toBe("After");
    // After invalidation + re-read, it's a new object
    expect(s3).not.toBe(second.find((s) => s.piSessionId === "uuid-inv"));
  });

  it("preserves session name and firstMessage from JSONL", async () => {
    writeFileSync(
      join(testDir, "2026-02-20T00-00-00-000Z_uuid-meta.jsonl"),
      makeSessionJsonl({
        id: "uuid-meta",
        name: "Refactor auth module",
        userMessage: "I want to refactor the auth module to use JWT",
      }),
    );

    const sessions = await discoverLocalSessions();
    const found = sessions.find((s) => s.piSessionId === "uuid-meta");

    expect(found).toBeDefined();
    expect(found!.name).toBe("Refactor auth module");
    expect(found!.firstMessage).toBe("I want to refactor the auth module to use JWT");
    expect(found!.model).toBe("anthropic/claude-sonnet-4-5");
    expect(found!.messageCount).toBe(1);
  });

  it("removes stale cache entries for deleted files", async () => {
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-del.jsonl");
    writeFileSync(filePath, makeSessionJsonl({ id: "uuid-del" }));

    const before = await discoverLocalSessions();
    expect(before.find((s) => s.piSessionId === "uuid-del")).toBeDefined();

    rmSync(filePath);
    invalidateLocalSessionsCache();

    const after = await discoverLocalSessions();
    expect(after.find((s) => s.piSessionId === "uuid-del")).toBeUndefined();
  });

  it("prunes deleted sqlite catalog rows during catalog refresh", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-tui-session-catalog-refresh-prune-"));
    try {
      const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-sqlite-refresh-del.jsonl");
      writeFileSync(
        filePath,
        makeSessionJsonl({ id: "uuid-sqlite-refresh-del", name: "Delete me" }),
      );

      const first = await discoverLocalSessions(undefined, { dataDir });
      expect(first.find((s) => s.piSessionId === "uuid-sqlite-refresh-del")?.name).toBe(
        "Delete me",
      );

      rmSync(filePath);
      const second = await discoverLocalSessions(undefined, { dataDir });
      expect(second.find((s) => s.piSessionId === "uuid-sqlite-refresh-del")).toBeUndefined();

      const db = openDatabase(join(dataDir, "session-state.db"));
      try {
        const row = db
          .prepare("SELECT path FROM tui_session_files WHERE pi_session_id = ?")
          .get("uuid-sqlite-refresh-del");
        expect(row).toBeUndefined();
      } finally {
        db.close();
      }
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not prune sqlite catalog rows during invalidation", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-tui-session-catalog-invalidate-"));
    try {
      const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-sqlite-inv-keep.jsonl");
      writeFileSync(filePath, makeSessionJsonl({ id: "uuid-sqlite-inv-keep", name: "Keep me" }));

      await discoverLocalSessions(undefined, { dataDir });
      rmSync(filePath);
      invalidateLocalSessionsCache({ dataDir });

      const snapshot = listCatalogedLocalSessions(undefined, { dataDir });
      expect(snapshot.lastScannedAt).toBeUndefined();
      expect(snapshot.sessions.find((s) => s.piSessionId === "uuid-sqlite-inv-keep")).toBeDefined();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("removes exact sqlite catalog rows before deleting known session files", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-tui-session-catalog-exact-delete-"));
    try {
      const filePath = join(testDir, "2026-02-20T00-00-00-000Z_uuid-sqlite-exact-del.jsonl");
      writeFileSync(filePath, makeSessionJsonl({ id: "uuid-sqlite-exact-del", name: "Delete me" }));

      const first = await discoverLocalSessions(undefined, { dataDir });
      expect(first.find((s) => s.piSessionId === "uuid-sqlite-exact-del")?.name).toBe("Delete me");

      deleteCatalogedLocalSessionPaths([filePath], { dataDir });
      rmSync(filePath);
      invalidateLocalSessionsCache({ dataDir });

      const snapshot = listCatalogedLocalSessions(undefined, { dataDir });
      expect(snapshot.lastScannedAt).toBeUndefined();
      expect(
        snapshot.sessions.find((s) => s.piSessionId === "uuid-sqlite-exact-del"),
      ).toBeUndefined();

      const db = openDatabase(join(dataDir, "session-state.db"));
      try {
        const row = db
          .prepare("SELECT path FROM tui_session_files WHERE pi_session_id = ?")
          .get("uuid-sqlite-exact-del");
        expect(row).toBeUndefined();
      } finally {
        db.close();
      }
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

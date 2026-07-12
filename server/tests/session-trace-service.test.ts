import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, symlinkSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { materializeToolMediaContentBlocks } from "../src/session-attachments.js";
import { SessionTraceService, type SessionTraceServiceDeps } from "../src/session-trace-service.js";
import type { Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function initGitRepo(root: string): void {
  git(root, ["init", "--initial-branch=main"]);
  git(root, ["config", "user.email", "oppi-test@example.invalid"]);
  git(root, ["config", "user.name", "Oppi Test"]);
  writeFileSync(join(root, "README.md"), "main checkout\n");
  git(root, ["add", "README.md"]);
  git(root, ["commit", "-m", "initial"]);
}

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Workspace",
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function writeJsonl(path: string, entries: Record<string, unknown>[]): void {
  writeFileSync(path, entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n", "utf8");
}

function makeService(options: {
  dataDir: string;
  storedSession?: Session;
  liveState?: { sessionFile?: string; sessionId?: string; leafId?: string | null } | null;
  fullOutputPath?: string | null;
  workspace?: Workspace;
  workspaces?: Workspace[];
}): { service: SessionTraceService; deps: SessionTraceServiceDeps } {
  const deps: SessionTraceServiceDeps = {
    storage: {
      getDataDir: vi.fn(() => options.dataDir),
      getSession: vi.fn(() => options.storedSession),
      getWorkspace: vi.fn(() => options.workspace),
      listWorkspaces: vi.fn(
        () => options.workspaces ?? (options.workspace ? [options.workspace] : []),
      ),
    },
    sessionRuntimes: {
      refreshSessionState: vi.fn(async () => options.liveState ?? null),
      getToolFullOutputPath: vi.fn(() => options.fullOutputPath ?? null),
    },
    ensureSessionContextWindow: vi.fn((session) => ({
      ...session,
      contextWindow: session.contextWindow ?? 200_000,
    })),
  };

  return { service: new SessionTraceService(deps), deps };
}

describe("SessionTraceService", () => {
  let tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs = [];
  });

  function tempDir(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix));
    tempDirs.push(dir);
    return dir;
  }

  it("loads a workspace trace after refreshing live session state", async () => {
    const dataDir = tempDir("oppi-session-trace-service-");
    const traceDir = join(dataDir, "ws-1", "sessions", "sess-1", "agent", "sessions", "--work--");
    mkdirSync(traceDir, { recursive: true });
    writeJsonl(join(traceDir, "2026-05-03T000000Z_pi-1.jsonl"), [
      { type: "session", id: "pi-1", cwd: dataDir },
      {
        type: "message",
        id: "u1",
        timestamp: "2026-05-03T00:00:01.000Z",
        message: { role: "user", content: [{ type: "text", text: "hello from stored trace" }] },
      },
    ]);
    const latestSession = makeSession({ id: "sess-1", workspaceId: "ws-1", name: "Latest" });
    const { service, deps } = makeService({ dataDir, storedSession: latestSession });

    const result = await service.getSessionWithTrace({ session: makeSession({ id: "sess-1" }) });

    expect(deps.sessionRuntimes.refreshSessionState).toHaveBeenCalledWith("sess-1");
    expect(result.session).toMatchObject({ id: "sess-1", name: "Latest", contextWindow: 200_000 });
    expect(result.trace.map((event) => [event.type, event.text])).toEqual([
      ["user", "hello from stored trace"],
    ]);
  });

  it("falls back to the live runtime trace file when stored traces are absent", async () => {
    const dataDir = tempDir("oppi-session-trace-live-");
    const liveTrace = join(dataDir, "live.jsonl");
    writeJsonl(liveTrace, [
      { type: "session", id: "pi-live", cwd: dataDir },
      {
        type: "message",
        id: "u1",
        timestamp: "2026-05-03T00:00:01.000Z",
        message: { role: "user", content: [{ type: "text", text: "hello live" }] },
      },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-05-03T00:00:02.000Z",
        message: { role: "assistant", content: [{ type: "text", text: "hello back" }] },
      },
    ]);
    const { service } = makeService({
      dataDir,
      storedSession: makeSession({ id: "sess-1", workspaceId: "ws-1" }),
      liveState: { sessionFile: liveTrace, sessionId: "pi-live", leafId: null },
    });

    const result = await service.getSessionWithTrace({ session: makeSession({ id: "sess-1" }) });

    expect(result.trace.map((event) => [event.type, event.text])).toEqual([
      ["user", "hello live"],
      ["assistant", "hello back"],
    ]);
  });

  it("returns stored image metadata instead of truncated inline image bytes in trace pages", async () => {
    const dataDir = tempDir("oppi-session-trace-page-image-");
    const traceDir = join(dataDir, "ws-1", "sessions", "sess-1", "agent", "sessions", "--work--");
    mkdirSync(traceDir, { recursive: true });
    const imageBytes = Buffer.alloc(8_192, 0x5a);
    const imageBlock = {
      type: "image",
      data: imageBytes.toString("base64"),
      mimeType: "image/png",
    };
    materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "sess-1",
      toolCallId: "tc-image",
      contents: [imageBlock],
      fallbackFileName: "screenshot.png",
    });
    writeJsonl(join(traceDir, "2026-05-03T000000Z_pi-1.jsonl"), [
      {
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-05-03T00:00:00.000Z",
        message: { role: "user", content: "show me a screenshot" },
      },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-05-03T00:00:01.000Z",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-image",
              name: "read",
              arguments: { path: "/tmp/screenshot.png" },
            },
          ],
        },
      },
      {
        type: "message",
        id: "r1",
        parentId: "a1",
        timestamp: "2026-05-03T00:00:02.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tc-image",
          toolName: "read",
          content: [
            { type: "text", text: "Read image file [image/png]" },
            imageBlock,
          ],
        },
      },
    ]);
    const session = makeSession({ id: "sess-1", workspaceId: "ws-1" });
    const { service } = makeService({ dataDir, storedSession: session });

    const result = await service.getSessionTracePage({
      session,
      targetEvents: 10,
      previewBytes: 64,
    });
    const toolResult = result?.trace.find((event) => event.type === "toolResult");
    const details = toolResult?.details as
      | { media?: Array<{ id?: string; kind?: string; mimeType?: string }> }
      | undefined;

    expect(toolResult?.output).toBe("Read image file [image/png]");
    expect(toolResult?.output).not.toContain("data:image/");
    expect(toolResult?.outputTruncated).toBeUndefined();
    expect(details?.media).toEqual([
      expect.objectContaining({
        id: expect.stringMatching(/^att_/),
        kind: "image",
        mimeType: "image/png",
      }),
    ]);
  });

  it("finds JSONL tool output across existing session trace files", async () => {
    const dataDir = tempDir("oppi-session-tool-output-");
    const olderTrace = join(dataDir, "older.jsonl");
    const newerTrace = join(dataDir, "newer.jsonl");
    writeJsonl(olderTrace, [
      {
        type: "message",
        id: "result-other",
        message: {
          role: "toolResult",
          toolCallId: "tc-other",
          content: [{ type: "text", text: "wrong output" }],
        },
      },
    ]);
    writeJsonl(newerTrace, [
      {
        type: "message",
        id: "result-1",
        message: {
          role: "toolResult",
          toolCallId: "tc-1",
          content: [{ type: "text", text: "complete output" }],
          isError: true,
        },
      },
    ]);
    const { service } = makeService({ dataDir });

    const result = await service.getToolOutput(
      makeSession({
        piSessionFiles: [join(dataDir, "missing.jsonl"), olderTrace],
        piSessionFile: newerTrace,
      }),
      "tc-1",
    );

    expect(result).toEqual({ toolCallId: "tc-1", output: "complete output", isError: true });
  });

  it("reads full tool output from the owning runtime path", async () => {
    const dataDir = tempDir("oppi-session-full-tool-output-");
    const outputPath = join(dataDir, "tc-1.full.txt");
    writeFileSync(outputPath, "full output text", "utf8");
    const { service, deps } = makeService({ dataDir, fullOutputPath: outputPath });

    await expect(service.getFullToolOutput("sess-1", "tc-1")).resolves.toEqual({
      toolCallId: "tc-1",
      output: "full output text",
    });
    expect(deps.sessionRuntimes.getToolFullOutputPath).toHaveBeenCalledWith("sess-1", "tc-1");
  });

  it("builds an overall diff from trace mutations and the current workspace file", async () => {
    const dataDir = tempDir("oppi-session-overall-diff-");
    const workspaceRoot = tempDir("oppi-session-overall-diff-workspace-");
    const tracePath = join(dataDir, "trace.jsonl");
    writeFileSync(join(workspaceRoot, "file.txt"), "hello\nnew\nbye", "utf8");
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: workspaceRoot },
      {
        type: "message",
        id: "assistant-1",
        timestamp: "2026-05-03T00:00:01.000Z",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-edit",
              name: "edit",
              arguments: { path: "file.txt", oldText: "old", newText: "new" },
            },
          ],
        },
      },
    ]);
    const session = makeSession({ piSessionFile: tracePath });
    const { service } = makeService({
      dataDir,
      workspace: makeWorkspace({ hostMount: workspaceRoot }),
    });

    const result = await service.getSessionOverallDiff({ session, path: "file.txt" });

    expect(result).toMatchObject({
      kind: "ok",
      diff: {
        workspaceId: "ws-1",
        path: "file.txt",
        baselineText: "hello\nold\nbye",
        currentText: "hello\nnew\nbye",
        addedLines: 1,
        removedLines: 1,
        revisionCount: 1,
        cacheKey: "sess-1:file.txt:tc-edit",
      },
    });
    expect(result.kind === "ok" ? result.diff.hunks.length : 0).toBeGreaterThan(0);
  });

  it("reports typed overall-diff misses for current files outside the workspace", async () => {
    const dataDir = tempDir("oppi-session-overall-diff-outside-");
    const workspaceRoot = tempDir("oppi-session-overall-diff-outside-workspace-");
    const outsideRoot = tempDir("oppi-session-overall-diff-outside-root-");
    const outsidePath = join(outsideRoot, "outside.txt");
    const tracePath = join(dataDir, "trace.jsonl");
    writeFileSync(outsidePath, "new", "utf8");
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: workspaceRoot },
      {
        type: "message",
        id: "assistant-1",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-edit",
              name: "edit",
              arguments: { path: outsidePath, oldText: "old", newText: "new" },
            },
          ],
        },
      },
    ]);
    const { service } = makeService({
      dataDir,
      workspace: makeWorkspace({ hostMount: workspaceRoot }),
    });

    await expect(
      service.getSessionOverallDiff({
        session: makeSession({ piSessionFile: tracePath }),
        path: outsidePath,
      }),
    ).resolves.toEqual({ kind: "current-file-outside-workspace" });
  });

  it("reports typed overall-diff misses for current files above the preview limit", async () => {
    const dataDir = tempDir("oppi-session-overall-diff-large-");
    const workspaceRoot = tempDir("oppi-session-overall-diff-large-workspace-");
    const tracePath = join(dataDir, "trace.jsonl");
    writeFileSync(join(workspaceRoot, "big.txt"), Buffer.alloc(10 * 1024 * 1024 + 1));
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: workspaceRoot },
      {
        type: "message",
        id: "assistant-1",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-edit",
              name: "edit",
              arguments: { path: "big.txt", oldText: "old", newText: "new" },
            },
          ],
        },
      },
    ]);
    const { service } = makeService({
      dataDir,
      workspace: makeWorkspace({ hostMount: workspaceRoot }),
    });

    await expect(
      service.getSessionOverallDiff({
        session: makeSession({ piSessionFile: tracePath }),
        path: "big.txt",
      }),
    ).resolves.toEqual({ kind: "current-file-too-large", maxSizeMegabytes: 10 });
  });

  it("reports unreadable current files separately from missing files", async () => {
    const dataDir = tempDir("oppi-session-overall-diff-unreadable-");
    const workspaceRoot = tempDir("oppi-session-overall-diff-unreadable-workspace-");
    const lockedDir = join(workspaceRoot, "locked");
    const tracePath = join(dataDir, "trace.jsonl");
    mkdirSync(lockedDir);
    writeFileSync(join(lockedDir, "secret.txt"), "new", "utf8");
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: workspaceRoot },
      {
        type: "message",
        id: "assistant-1",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-edit",
              name: "edit",
              arguments: { path: "locked/secret.txt", oldText: "old", newText: "new" },
            },
          ],
        },
      },
    ]);
    const { service } = makeService({
      dataDir,
      workspace: makeWorkspace({ hostMount: workspaceRoot }),
    });

    try {
      chmodSync(lockedDir, 0o000);
      await expect(
        service.getSessionOverallDiff({
          session: makeSession({ piSessionFile: tracePath }),
          path: "locked/secret.txt",
        }),
      ).resolves.toEqual({ kind: "current-file-unreadable" });
    } finally {
      chmodSync(lockedDir, 0o700);
    }
  });

  it("reports typed overall-diff misses for absent traces and files without mutations", async () => {
    const dataDir = tempDir("oppi-session-overall-diff-misses-");
    const tracePath = join(dataDir, "trace.jsonl");
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: dataDir },
      {
        type: "message",
        id: "u1",
        message: { role: "user", content: [{ type: "text", text: "hello" }] },
      },
    ]);
    const { service } = makeService({ dataDir });

    await expect(
      service.getSessionOverallDiff({ session: makeSession(), path: "file.txt" }),
    ).resolves.toEqual({ kind: "trace-not-found" });
    await expect(
      service.getSessionOverallDiff({
        session: makeSession({ piSessionFile: tracePath }),
        path: "file.txt",
      }),
    ).resolves.toEqual({ kind: "mutations-not-found" });
  });

  it("summarizes session changed files", () => {
    const dataDir = tempDir("oppi-session-changes-");
    const { service } = makeService({ dataDir });

    expect(
      service.listSessionChanges(
        makeSession({
          changeStats: {
            mutatingToolCalls: 2,
            filesChanged: 2,
            changedFiles: ["src/App.swift", "README.md"],
            changedFilesOverflow: 1,
            addedLines: 10,
            removedLines: 3,
          },
        }),
      ),
    ).toEqual({
      workspaceId: "ws-1",
      sessionId: "sess-1",
      files: [{ path: "src/App.swift" }, { path: "README.md" }],
      changedFileCount: 2,
      changedFilesOverflow: 1,
    });
  });

  it("resolves raw session file reads through workspace file policy", async () => {
    const dataDir = tempDir("oppi-session-raw-data-");
    const workspaceRoot = tempDir("oppi-session-raw-workspace-");
    mkdirSync(join(workspaceRoot, "notes"), { recursive: true });
    writeFileSync(join(workspaceRoot, "notes", "hello.txt"), "hello from session\n", "utf8");
    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const session = makeSession({
      changeStats: {
        mutatingToolCalls: 1,
        filesChanged: 1,
        changedFiles: ["notes/hello.txt"],
        addedLines: 1,
        removedLines: 0,
      },
    });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session, path: "notes/hello.txt" }),
    ).resolves.toMatchObject({
      kind: "ok",
      contentType: "text/plain; charset=utf-8",
      size: 19,
    });
  });

  it("resolves raw session file reads through data-dir worktrees", async () => {
    const dataDir = tempDir("oppi-session-raw-worktree-data-");
    const workspaceRoot = tempDir("oppi-session-raw-worktree-workspace-");
    initGitRepo(workspaceRoot);
    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const worktree = createWorkspaceWorktree(
      workspace,
      { branch: "feature/raw-worktree" },
      { dataDir },
    );
    mkdirSync(join(worktree.path, "notes"), { recursive: true });
    writeFileSync(join(worktree.path, "notes", "hello.txt"), "hello from worktree\n", "utf8");
    const session = makeSession({
      worktreeId: worktree.id,
      changeStats: {
        mutatingToolCalls: 1,
        filesChanged: 1,
        changedFiles: ["notes/hello.txt"],
        addedLines: 1,
        removedLines: 0,
      },
    });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session, path: "notes/hello.txt" }),
    ).resolves.toMatchObject({
      kind: "ok",
      contentType: "text/plain; charset=utf-8",
      size: 20,
    });
  });

  it("serves a reported workspace-relative symlink that resolves outside the workspace", async () => {
    const dataDir = tempDir("oppi-session-raw-symlink-data-");
    const workspaceRoot = tempDir("oppi-session-raw-symlink-workspace-");
    const outsideRoot = tempDir("oppi-session-raw-symlink-outside-");
    const outsideSkillRoot = join(outsideRoot, "oppi-dev");
    mkdirSync(join(workspaceRoot, ".pi", "skills"), { recursive: true });
    mkdirSync(join(outsideSkillRoot, "scripts"), { recursive: true });
    writeFileSync(join(outsideSkillRoot, "scripts", "oppi-workflow.sh"), "echo ok\n", "utf8");
    symlinkSync(outsideSkillRoot, join(workspaceRoot, ".pi", "skills", "oppi-dev"), "dir");

    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const touchedPath = ".pi/skills/oppi-dev/scripts/oppi-workflow.sh";
    const session = makeSession({
      changeStats: {
        mutatingToolCalls: 1,
        filesChanged: 1,
        changedFiles: [touchedPath],
        addedLines: 1,
        removedLines: 0,
      },
    });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session, path: touchedPath }),
    ).resolves.toMatchObject({
      kind: "ok",
      contentType: "text/plain; charset=utf-8",
      size: 8,
    });
  });

  it("serves session-reported relative paths that escape the workspace", async () => {
    const dataDir = tempDir("oppi-session-raw-escape-data-");
    const workspaceRoot = tempDir("oppi-session-raw-escape-workspace-");
    const outsideRoot = tempDir("oppi-session-raw-escape-outside-");
    const outsidePath = join(outsideRoot, "outside.txt");
    writeFileSync(outsidePath, "outside\n", "utf8");

    const escapePath = relative(workspaceRoot, outsidePath);
    expect(escapePath.startsWith("..")).toBe(true);

    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const session = makeSession({
      changeStats: {
        mutatingToolCalls: 1,
        filesChanged: 1,
        changedFiles: [escapePath],
        addedLines: 1,
        removedLines: 0,
      },
    });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session, path: escapePath }),
    ).resolves.toMatchObject({
      kind: "ok",
      contentType: "text/plain; charset=utf-8",
      size: 8,
    });
  });

  it("blocks unreported paths outside the workspace", async () => {
    const dataDir = tempDir("oppi-session-raw-unreported-data-");
    const workspaceRoot = tempDir("oppi-session-raw-unreported-workspace-");
    const outsideRoot = tempDir("oppi-session-raw-unreported-outside-");
    const outsidePath = join(outsideRoot, "outside.txt");
    writeFileSync(outsidePath, "outside\n", "utf8");
    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session: makeSession(), path: outsidePath }),
    ).resolves.toEqual({ kind: "path-outside-workspace" });
  });

  it("serves an absolute path reported in tool arguments", async () => {
    const dataDir = tempDir("oppi-session-raw-tool-path-data-");
    const workspaceRoot = tempDir("oppi-session-raw-tool-path-workspace-");
    const outsideRoot = tempDir("oppi-session-raw-tool-path-outside-");
    const outsidePath = join(outsideRoot, "image.png");
    const tracePath = join(dataDir, "trace.jsonl");
    writeFileSync(outsidePath, "image bytes", "utf8");
    writeJsonl(tracePath, [
      { type: "session", id: "pi-1", cwd: workspaceRoot },
      {
        type: "message",
        id: "assistant-1",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "tc-read",
              name: "read",
              arguments: { path: outsidePath },
            },
          ],
        },
      },
    ]);
    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const session = makeSession({ piSessionFile: tracePath });
    const { service } = makeService({ dataDir, workspace, storedSession: session });

    await expect(
      service.getSessionRawFile({ workspace, session, path: outsidePath }),
    ).resolves.toMatchObject({ kind: "ok", size: 11 });
  });

  it("reports typed raw file misses and serves workspace files regardless of name", async () => {
    const dataDir = tempDir("oppi-session-raw-misses-");
    const workspaceRoot = tempDir("oppi-session-raw-misses-workspace-");
    writeFileSync(join(workspaceRoot, ".env"), "SECRET=yes\n", "utf8");
    const workspace = makeWorkspace({ hostMount: workspaceRoot });
    const { service } = makeService({ dataDir, workspace });

    await expect(
      service.getSessionRawFile({ workspace, session: makeSession(), path: "notes/missing.txt" }),
    ).resolves.toEqual({ kind: "file-not-found" });
    await expect(
      service.getSessionRawFile({
        workspace,
        session: makeSession(),
        path: ".env",
      }),
    ).resolves.toMatchObject({
      kind: "ok",
      contentType: "application/octet-stream",
      size: 11,
    });
  });
});

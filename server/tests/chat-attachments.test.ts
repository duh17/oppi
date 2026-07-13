import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { materializeChatAttachments } from "../src/chat-attachments.js";

const cleanupPaths = new Set<string>();

afterEach(() => {
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
});

describe("chat attachment materialization boundaries", () => {
  it("rejects traversal and symlinks escaping the workspace root", async () => {
    const sandboxRoot = mkdtempSync(join(tmpdir(), "oppi-chat-attachment-boundary-"));
    const workspaceRoot = join(sandboxRoot, "workspace");
    mkdirSync(workspaceRoot);
    cleanupPaths.add(sandboxRoot);
    const outsideFile = join(sandboxRoot, "secret.txt");
    writeFileSync(outsideFile, "must stay outside", "utf8");
    symlinkSync(outsideFile, join(workspaceRoot, "escape.txt"));

    for (const workspacePath of ["../secret.txt", "escape.txt"]) {
      await expect(
        materializeChatAttachments({
          workspaceRoot,
          workspaceId: "ws-1",
          sessionId: "sess-1",
          turnId: `turn-${workspacePath.replaceAll(/[^a-z]/gi, "-")}`,
          message: "inspect",
          attachments: [
            {
              type: "attachment",
              id: "att-1",
              source: "workspace",
              name: "secret.txt",
              mimeType: "text/plain",
              sizeBytes: 17,
              workspacePath,
            },
          ],
        }),
      ).rejects.toThrow();
    }

    expect(readFileSync(outsideFile, "utf8")).toBe("must stay outside");
  });

  it("deduplicates attachment names while preserving copied bytes and stable relative paths", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-chat-attachment-dedupe-"));
    cleanupPaths.add(workspaceRoot);
    mkdirSync(join(workspaceRoot, "one"), { recursive: true });
    mkdirSync(join(workspaceRoot, "two"), { recursive: true });
    writeFileSync(join(workspaceRoot, "one", "note.txt"), "first", "utf8");
    writeFileSync(join(workspaceRoot, "two", "note.txt"), "second", "utf8");

    const result = await materializeChatAttachments({
      workspaceRoot,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      turnId: "turn-1",
      message: "inspect both",
      attachments: [
        {
          type: "attachment",
          id: "att-1",
          source: "workspace",
          name: "note.txt",
          mimeType: "text/plain",
          sizeBytes: 5,
          workspacePath: "one/note.txt",
        },
        {
          type: "attachment",
          id: "att-2",
          source: "workspace",
          name: "note.txt",
          mimeType: "text/plain",
          sizeBytes: 6,
          workspacePath: "two/note.txt",
        },
      ],
      maxTurnBytes: 11,
    });

    expect(result.materialized.map((item) => item.name)).toEqual(["note.txt", "note-2.txt"]);
    expect(result.materialized.map((item) => item.relativePath)).toEqual([
      ".pi/attachments/sess-1/turn-1/note.txt",
      ".pi/attachments/sess-1/turn-1/note-2.txt",
    ]);
    expect(
      result.materialized.map((item) =>
        readFileSync(join(workspaceRoot, item.relativePath), "utf8"),
      ),
    ).toEqual(["first", "second"]);
  });
});

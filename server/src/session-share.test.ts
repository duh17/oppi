import { randomUUID } from "node:crypto";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import type { AgentSession } from "@mariozechner/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";

import { __shareSessionTestUtils, shareSession } from "./session-share.js";

function makeSession(sessionFile: string | undefined): AgentSession {
  return {
    getSessionStats: () => ({
      sessionFile,
    }),
    exportToHtml: async () => "",
  } as unknown as AgentSession;
}

describe("shareSession", () => {
  it("fails when session has no persisted session file", async () => {
    await expect(
      shareSession(makeSession(undefined), {
        ensureGhAuthenticated: () => {},
      }),
    ).rejects.toThrow("Cannot share this session because it has no persisted session file.");
  });

  it("creates gist and returns share URLs", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      writeFileSync(outputPath, "<html><body>ok</body></html>", "utf-8");
    });

    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async () => ({
        stdout: "https://gist.github.com/demo-user/abc123\n",
        stderr: "",
        code: 0,
      }),
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
      makeTempPath: () => tempHtmlPath,
    });

    expect(result).toEqual({
      shareUrl: "https://pi.dev/session/#abc123",
      gistUrl: "https://gist.github.com/demo-user/abc123",
      gistId: "abc123",
    });
    expect(exportSessionToHtml).toHaveBeenCalledTimes(1);
    expect(existsSync(tempHtmlPath)).toBe(false);
  });
});

describe("shareSession helper parsing", () => {
  it("parses gist URL and gist ID", () => {
    expect(__shareSessionTestUtils.parseGistUrl("\nhttps://gist.github.com/user/123abc\n")).toBe(
      "https://gist.github.com/user/123abc",
    );
    expect(__shareSessionTestUtils.parseGistId("https://gist.github.com/user/123abc")).toBe(
      "123abc",
    );
    expect(__shareSessionTestUtils.parseGistId("https://gist.github.com/user/123abc.git")).toBe(
      "123abc",
    );
  });
});

import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
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

function buildExportHtmlWithSessionData(sessionData: Record<string, unknown>): string {
  const encoded = Buffer.from(JSON.stringify(sessionData), "utf-8").toString("base64");
  return `<html><body><script id="session-data" type="application/json">${encoded}</script></body></html>`;
}

function decodeExportSessionData(html: string): Record<string, unknown> {
  const match = html.match(
    /<script id="session-data" type="application\/(?:json|octet-stream)">(.*?)<\/script>/s,
  );
  if (!match) {
    throw new Error("Missing session-data payload");
  }
  return JSON.parse(Buffer.from(match[1]!.trim(), "base64").toString("utf-8"));
}

describe("shareSession", () => {
  it("fails when session has no persisted session file", async () => {
    await expect(
      shareSession(makeSession(undefined), {
        ensureGhAuthenticated: () => {},
      }),
    ).rejects.toThrow("[share:session_not_persisted]");
  });

  it("uploads the default export as session.html for the share viewer", async () => {
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      writeFileSync(outputPath, "<html><body>ok</body></html>", "utf-8");
    });

    let uploadedPath = "";
    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async (htmlPath) => {
        uploadedPath = htmlPath;
        return {
          stdout: "https://gist.github.com/demo-user/abc123\n",
          stderr: "",
          code: 0,
        };
      },
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
    });

    expect(result.phase).toBe("published");
    expect(basename(uploadedPath)).toBe("session.html");
    expect(exportSessionToHtml).toHaveBeenCalledTimes(1);
  });

  it("auto-redacts sensitive content before gist upload", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const openAiKey = `sk-${"A".repeat(24)}`;
      const html = `<html><body>${openAiKey} alice@example.com /Users/alice/workspace/oppi</body></html>`;
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async (htmlPath) => {
        uploadedHtml = readFileSync(htmlPath, "utf-8");
        return {
          stdout: "https://gist.github.com/demo-user/abc123\n",
          stderr: "",
          code: 0,
        };
      },
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
      makeTempPath: () => tempHtmlPath,
    });

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    expect(uploadedHtml).toContain("[REDACTED_OPENAI_API_KEY]");
    expect(uploadedHtml).toContain("[REDACTED_EMAIL]");
    expect(uploadedHtml).toContain("/Users/[REDACTED_USER]/workspace/oppi");
    expect(uploadedHtml).not.toContain("alice@example.com");
    expect(uploadedHtml).not.toContain("/Users/alice/workspace/oppi");

    expect(result.redaction.totalReplacements).toBeGreaterThanOrEqual(3);
    expect(result.redaction.findings.some((finding) => finding.kind === "openai_api_key")).toBe(
      true,
    );
    expect(result.redaction.findings.some((finding) => finding.kind === "email_address")).toBe(
      true,
    );
    expect(result.redaction.findings.some((finding) => finding.kind === "unix_user_path")).toBe(
      true,
    );

    expect(exportSessionToHtml).toHaveBeenCalledTimes(1);
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("removes system prompt, tool definitions, and pre-user setup from embedded share payloads", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const openAiKey = `sk-${"B".repeat(24)}`;
    const expandedSkill = `<skill name="writing" location="/Users/alice/.pi/agent/skills/writing/SKILL.md">\nUse the writing skill.\nKeep prose tight.\n</skill>\n\nemail alice@example.com key ${openAiKey}`;
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const html = buildExportHtmlWithSessionData({
        header: {
          cwd: "/Users/alice/workspace/oppi",
        },
        entries: [
          {
            id: "entry-setup-model",
            parentId: null,
            type: "model_change",
            timestamp: "2026-04-22T00:00:00.000Z",
            provider: "anthropic",
            modelId: "claude-sonnet-4-5",
          },
          {
            id: "entry-setup-thinking",
            parentId: "entry-setup-model",
            type: "thinking_level_change",
            timestamp: "2026-04-22T00:00:01.000Z",
            thinkingLevel: "high",
          },
          {
            id: "entry-user",
            parentId: "entry-setup-thinking",
            type: "message",
            timestamp: "2026-04-22T00:00:02.000Z",
            message: {
              role: "user",
              content: expandedSkill,
            },
          },
          {
            id: "entry-assistant",
            parentId: "entry-user",
            type: "message",
            timestamp: "2026-04-22T00:00:03.000Z",
            message: {
              role: "assistant",
              content: "Working from /Users/alice/private/oppi",
            },
          },
        ],
        leafId: "entry-assistant",
        systemPrompt: "You are an internal agent with hidden instructions.",
        skills: ["search", "fetch"],
        availableSkills: [{ name: "search" }, { name: "fetch" }],
        workspace: {
          id: "ws-demo",
          skills: ["search", "fetch"],
        },
        tools: [
          {
            name: "bash",
            description: "Run shell commands",
            parameters: {
              type: "object",
              properties: {
                command: {
                  type: "string",
                  description: "Shell command to execute",
                },
              },
              required: ["command"],
            },
          },
        ],
      });
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async (htmlPath) => {
        uploadedHtml = readFileSync(htmlPath, "utf-8");
        return {
          stdout: "https://gist.github.com/demo-user/abc123\n",
          stderr: "",
          code: 0,
        };
      },
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
      makeTempPath: () => tempHtmlPath,
    });

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    const payload = decodeExportSessionData(uploadedHtml);
    const payloadText = JSON.stringify(payload);
    const entries = Array.isArray(payload.entries) ? payload.entries : [];

    expect(payload.systemPrompt).toBeUndefined();
    expect(payload.tools).toBeUndefined();
    expect(payload.skills).toBeUndefined();
    expect(payload.availableSkills).toBeUndefined();
    expect(payload.workspace).toMatchObject({ id: "ws-demo" });
    expect((payload.workspace as Record<string, unknown>).skills).toBeUndefined();
    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({
      id: "entry-user",
      parentId: null,
      type: "message",
      message: { role: "user" },
    });
    expect(entries[1]).toMatchObject({
      id: "entry-assistant",
      parentId: "entry-user",
      type: "message",
      message: { role: "assistant" },
    });
    expect(payload.leafId).toBe("entry-assistant");

    expect(payloadText).toContain("[REDACTED_SKILL]");
    expect(payloadText).toContain("[REDACTED_OPENAI_API_KEY]");
    expect(payloadText).toContain("[REDACTED_EMAIL]");
    expect(payloadText).toContain("/Users/[REDACTED_USER]/workspace/oppi");
    expect(payloadText).not.toContain("internal agent with hidden instructions");
    expect(payloadText).not.toContain("Run shell commands");
    expect(payloadText).not.toContain("entry-setup-model");
    expect(payloadText).not.toContain("entry-setup-thinking");
    expect(payloadText).not.toContain("Use the writing skill.");
    expect(payloadText).not.toContain("Keep prose tight.");
    expect(payloadText).not.toContain("/Users/alice/.pi/agent/skills/writing/SKILL.md");
    expect(payloadText).not.toContain(openAiKey);
    expect(payloadText).not.toContain("alice@example.com");
    expect(payloadText).not.toContain("/Users/alice");

    expect(result.scan.findings.some((finding) => finding.kind === "openai_api_key")).toBe(true);
    expect(result.scan.residualFindings).toEqual([]);
    expect(
      result.redaction.findings.some((finding) => finding.kind === "system_prompt_removed"),
    ).toBe(true);
    expect(
      result.redaction.findings.some((finding) => finding.kind === "tool_definitions_removed"),
    ).toBe(true);
    expect(
      result.redaction.findings.some((finding) => finding.kind === "pre_user_entries_removed"),
    ).toBe(true);
    expect(
      result.redaction.findings.some((finding) => finding.kind === "skill_block_removed"),
    ).toBe(true);
    expect(result.redaction.findings.some((finding) => finding.kind === "skills_removed")).toBe(
      true,
    );
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("keeps skill metadata when skill redaction is turned off", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const html = buildExportHtmlWithSessionData({
        entries: [
          {
            id: "entry-user",
            parentId: null,
            type: "message",
            timestamp: "2026-04-22T00:00:00.000Z",
            message: {
              role: "user",
              content: "share this",
            },
          },
        ],
        leafId: "entry-user",
        skills: ["search", "fetch"],
        workspace: {
          id: "ws-demo",
          skills: ["search", "fetch"],
        },
      });
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(
      makeSession("/tmp/session.jsonl"),
      {
        ensureGhAuthenticated: () => {},
        exportSessionToHtml,
        createSecretGist: async (htmlPath) => {
          uploadedHtml = readFileSync(htmlPath, "utf-8");
          return {
            stdout: "https://gist.github.com/demo-user/abc123\n",
            stderr: "",
            code: 0,
          };
        },
        makeTempPath: () => tempHtmlPath,
      },
      {
        action: "publish",
        redactionPolicy: {
          skills: false,
        },
      },
    );

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    const payload = decodeExportSessionData(uploadedHtml);
    expect(payload.skills).toEqual(["search", "fetch"]);
    expect(payload.workspace).toMatchObject({
      id: "ws-demo",
      skills: ["search", "fetch"],
    });
    expect(result.redaction.findings.some((finding) => finding.kind === "skills_removed")).toBe(
      false,
    );
    expect(result.redaction.policy.skills).toBe(false);
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("removes all embedded entries when the session has no user message", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const html = buildExportHtmlWithSessionData({
        entries: [
          {
            id: "entry-setup",
            parentId: null,
            type: "model_change",
            timestamp: "2026-04-22T00:00:00.000Z",
            provider: "anthropic",
            modelId: "claude-sonnet-4-5",
          },
          {
            id: "entry-assistant",
            parentId: "entry-setup",
            type: "message",
            timestamp: "2026-04-22T00:00:01.000Z",
            message: {
              role: "assistant",
              content: "Ready when you are",
            },
          },
        ],
        leafId: "entry-assistant",
        systemPrompt: "Hidden system prompt",
        tools: [
          {
            name: "read",
            description: "Read files",
            parameters: { type: "object", properties: {} },
          },
        ],
      });
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async (htmlPath) => {
        uploadedHtml = readFileSync(htmlPath, "utf-8");
        return {
          stdout: "https://gist.github.com/demo-user/abc123\n",
          stderr: "",
          code: 0,
        };
      },
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
      makeTempPath: () => tempHtmlPath,
    });

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    const payload = decodeExportSessionData(uploadedHtml);
    const entries = Array.isArray(payload.entries) ? payload.entries : [];
    const preUserRemoval = result.redaction.findings.find(
      (finding) => finding.kind === "pre_user_entries_removed",
    );

    expect(payload.systemPrompt).toBeUndefined();
    expect(payload.tools).toBeUndefined();
    expect(entries).toEqual([]);
    expect(payload.leafId).toBeNull();
    expect(preUserRemoval?.count).toBe(2);
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("fails closed when embedded share payload cannot be decoded", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      writeFileSync(
        outputPath,
        '<html><body><script id="session-data" type="application/json">not-valid-json</script></body></html>',
        "utf-8",
      );
    });
    const createSecretGist = vi.fn(async () => ({
      stdout: "https://gist.github.com/demo-user/abc123\n",
      stderr: "",
      code: 0,
    }));

    await expect(
      shareSession(makeSession("/tmp/session.jsonl"), {
        ensureGhAuthenticated: () => {},
        exportSessionToHtml,
        createSecretGist,
        makeTempPath: () => tempHtmlPath,
      }),
    ).rejects.toThrow(
      /\[share:share_export_failed\] Failed to decode embedded session-data payload:/,
    );

    expect(createSecretGist).not.toHaveBeenCalled();
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("still strips share-only structure when auto-redaction is disabled", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const html = buildExportHtmlWithSessionData({
        header: {
          cwd: "/Users/alice/workspace/oppi",
        },
        entries: [
          {
            id: "entry-setup",
            parentId: null,
            type: "model_change",
            timestamp: "2026-04-22T00:00:00.000Z",
            provider: "anthropic",
            modelId: "claude-sonnet-4-5",
          },
          {
            id: "entry-user",
            parentId: "entry-setup",
            type: "message",
            timestamp: "2026-04-22T00:00:01.000Z",
            message: {
              role: "user",
              content: "hello",
            },
          },
          {
            id: "entry-assistant",
            parentId: "entry-user",
            type: "message",
            timestamp: "2026-04-22T00:00:02.000Z",
            message: {
              role: "assistant",
              content: "hi",
            },
          },
        ],
        leafId: "entry-assistant",
        systemPrompt: "Hidden system prompt",
        tools: [
          {
            name: "read",
            description: "Read files",
            parameters: {
              type: "object",
              properties: {},
            },
          },
        ],
      });
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(makeSession("/tmp/session.jsonl"), {
      ensureGhAuthenticated: () => {},
      exportSessionToHtml,
      createSecretGist: async (htmlPath) => {
        uploadedHtml = readFileSync(htmlPath, "utf-8");
        return {
          stdout: "https://gist.github.com/demo-user/abc123\n",
          stderr: "",
          code: 0,
        };
      },
      makeShareViewerUrl: (gistId) => `https://pi.dev/session/#${gistId}`,
      makeTempPath: () => tempHtmlPath,
      isAutoRedactionEnabled: () => false,
    });

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    const payload = decodeExportSessionData(uploadedHtml);
    const entries = Array.isArray(payload.entries) ? payload.entries : [];

    expect(payload.systemPrompt).toBeUndefined();
    expect(payload.tools).toBeUndefined();
    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({ id: "entry-user", parentId: null });
    expect(entries[1]).toMatchObject({ id: "entry-assistant", parentId: "entry-user" });
    expect(payload.leafId).toBe("entry-assistant");

    expect(result.redaction.enabled).toBe(false);
    expect(result.redaction.totalReplacements).toBe(0);
    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("can block publish when secrets remain after redaction and blocking is enabled", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      writeFileSync(outputPath, "<html><body>contains key</body></html>", "utf-8");
    });

    await expect(
      shareSession(makeSession("/tmp/session.jsonl"), {
        ensureGhAuthenticated: () => {},
        exportSessionToHtml,
        makeTempPath: () => tempHtmlPath,
        redactHtml: (html, _policy) => ({ html, findings: [], totalReplacements: 0 }),
        scanHtmlForSecrets: () => [{ kind: "openai_api_key", count: 1 }],
        shouldBlockOnSecrets: () => true,
      }),
    ).rejects.toThrow("[share:share_secret_detected]");

    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("respects configured deterministic redaction toggles and keeps secrets always-on", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      const openAiKey = `sk-${"A".repeat(24)}`;
      const html = `<html><body>${openAiKey} alice@example.com +1 (415) 555-0199 John Appleseed</body></html>`;
      writeFileSync(outputPath, html, "utf-8");
    });

    let uploadedHtml = "";
    const result = await shareSession(
      makeSession("/tmp/session.jsonl"),
      {
        ensureGhAuthenticated: () => {},
        exportSessionToHtml,
        createSecretGist: async (htmlPath) => {
          uploadedHtml = readFileSync(htmlPath, "utf-8");
          return {
            stdout: "https://gist.github.com/demo-user/abc123\n",
            stderr: "",
            code: 0,
          };
        },
        makeTempPath: () => tempHtmlPath,
      },
      {
        action: "publish",
        redactionPolicy: {
          secrets: false,
          emails: false,
          phones: true,
          userPaths: false,
          ipAddresses: false,
          jwtAndBearer: false,
          namesHeuristic: true,
        },
      },
    );

    expect(result.phase).toBe("published");
    if (result.phase !== "published") {
      throw new Error("Expected published result");
    }

    expect(uploadedHtml).toContain("[REDACTED_OPENAI_API_KEY]");
    expect(uploadedHtml).toContain("[REDACTED_PHONE]");
    expect(uploadedHtml).toContain("[REDACTED_PERSON]");
    expect(uploadedHtml).toContain("alice@example.com");

    expect(result.redaction.policy.secrets).toBe(true);
    expect(result.redaction.policy.emails).toBe(false);
    expect(result.redaction.policy.phones).toBe(true);
    expect(result.redaction.policy.namesHeuristic).toBe(true);

    expect(existsSync(tempHtmlPath)).toBe(false);
  });

  it("supports prepare mode without GitHub authentication and includes redaction summary", async () => {
    const tempHtmlPath = join(tmpdir(), `oppi-share-test-${randomUUID()}.html`);
    const exportSessionToHtml = vi.fn(async (_session: AgentSession, outputPath: string) => {
      writeFileSync(outputPath, "<html><body>alice@example.com</body></html>", "utf-8");
    });

    const result = await shareSession(
      makeSession("/tmp/session.jsonl"),
      {
        ensureGhAuthenticated: () => {
          throw new Error("should not authenticate for prepare mode");
        },
        exportSessionToHtml,
        makeTempPath: () => tempHtmlPath,
      },
      { action: "prepare" },
    );

    expect(result.phase).toBe("prepared");
    if (result.phase !== "prepared") {
      throw new Error("Expected prepared result");
    }

    expect(result.canPublish).toBe(true);
    expect(result.redaction.totalReplacements).toBeGreaterThanOrEqual(1);
    expect(result.redaction.findings.some((finding) => finding.kind === "email_address")).toBe(
      true,
    );

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

  it("formats share errors with a stable code prefix", () => {
    expect(__shareSessionTestUtils.formatShareErrorMessage("gh_not_installed", "Install gh")).toBe(
      "[share:gh_not_installed] Install gh",
    );
  });

  it("detects known secret patterns in exported HTML", () => {
    const dynamicToken = `sk-${"A".repeat(24)}`;
    const findings = __shareSessionTestUtils.defaultScanHtmlForSecrets(
      `<html><body>${dynamicToken}</body></html>`,
    );
    expect(findings.some((finding) => finding.kind === "openai_api_key")).toBe(true);
  });

  it("redacts personal identifiers and returns examples", () => {
    const result = __shareSessionTestUtils.defaultRedactHtmlForShare(
      "alice@example.com /Users/alice/workspace/oppi",
      __shareSessionTestUtils.normalizeRedactionPolicy(undefined),
    );

    expect(result.html).toContain("[REDACTED_EMAIL]");
    expect(result.html).toContain("/Users/[REDACTED_USER]/workspace/oppi");
    expect(result.totalReplacements).toBeGreaterThanOrEqual(2);
    expect(result.findings.some((finding) => finding.samples.length > 0)).toBe(true);
  });

  it("heuristically redacts person names when enabled", () => {
    const policy = __shareSessionTestUtils.normalizeRedactionPolicy({ namesHeuristic: true });
    const result = __shareSessionTestUtils.defaultRedactHtmlForShare(
      "Pair with John Appleseed on this patch.",
      policy,
    );

    expect(result.html).toContain("[REDACTED_PERSON]");
  });

  it("uses deterministic literal env secret redaction (pi-share-hf style)", () => {
    const envKey = "OPPI_SHARE_TEST_API_TOKEN";
    const previous = process.env[envKey];
    const secret = `tok_${"X".repeat(24)}`;
    process.env[envKey] = secret;

    try {
      const policy = __shareSessionTestUtils.normalizeRedactionPolicy(undefined);
      const payload = `tokenA=${secret} tokenB=${secret}`;
      const result = __shareSessionTestUtils.defaultRedactHtmlForShare(payload, policy);

      expect(result.html).not.toContain(secret);
      expect(result.html).toContain("[REDACTED_OPPI_SHARE_TEST_API_TOKEN]");

      const finding = result.findings.find(
        (item) => item.kind === "literal_secret_oppi_share_test_api_token",
      );
      expect(finding?.count).toBe(2);
    } finally {
      if (previous === undefined) {
        delete process.env[envKey];
      } else {
        process.env[envKey] = previous;
      }
    }
  });

  it("fuzzes mixed PII payload variants for deterministic reliability", () => {
    const policy = __shareSessionTestUtils.normalizeRedactionPolicy({
      emails: true,
      phones: true,
      userPaths: true,
      ipAddresses: true,
      jwtAndBearer: true,
      namesHeuristic: true,
    });

    for (let i = 0; i < 16; i += 1) {
      const openAiKey = `sk-${"A".repeat(20)}${i.toString(16).padStart(4, "0")}`;
      const email = `person${i}@example.com`;
      const phone = `+1 (415) 555-${String(1000 + i).padStart(4, "0")}`;
      const userPath = `/Users/user${i}/workspace/oppi`;
      const ipv4 = `10.12.${i}.${(i * 7) % 255}`;
      const jwt = `eyJ${"a".repeat(12)}.${"b".repeat(12)}.${"c".repeat(12)}`;
      const lastNames = [
        "Baker",
        "Carter",
        "Davis",
        "Evans",
        "Foster",
        "Garcia",
        "Harris",
        "Iverson",
        "Johnson",
        "Keller",
      ];
      const name = `Jane ${lastNames[i % lastNames.length]}`;

      const payload = [openAiKey, email, phone, userPath, ipv4, jwt, name].join(" | ");
      const result = __shareSessionTestUtils.defaultRedactHtmlForShare(payload, policy);

      expect(result.html).toContain("[REDACTED_OPENAI_API_KEY]");
      expect(result.html).toContain("[REDACTED_EMAIL]");
      expect(result.html).toContain("[REDACTED_PHONE]");
      expect(result.html).toContain("/Users/[REDACTED_USER]/workspace/oppi");
      expect(result.html).toContain("[REDACTED_IPV4]");
      expect(result.html).toContain("[REDACTED_JWT]");
      expect(result.html).toContain("[REDACTED_PERSON]");

      expect(result.html).not.toContain(openAiKey);
      expect(result.html).not.toContain(email);
      expect(result.html).not.toContain(phone);
      expect(result.html).not.toContain(userPath);
      expect(result.html).not.toContain(ipv4);
      expect(result.html).not.toContain(jwt);
      expect(result.totalReplacements).toBeGreaterThanOrEqual(7);
    }
  });

  it("name heuristic avoids common product phrases to reduce false positives", () => {
    const policy = __shareSessionTestUtils.normalizeRedactionPolicy({ namesHeuristic: true });
    const payload = "Session Timeline keeps Workspace Context visible.";
    const result = __shareSessionTestUtils.defaultRedactHtmlForShare(payload, policy);

    expect(result.html).toContain("Session Timeline");
    expect(result.html).toContain("Workspace Context");
    expect(result.html).not.toContain("[REDACTED_PERSON]");
  });

  it("is idempotent when run repeatedly on already-redacted output", () => {
    const policy = __shareSessionTestUtils.normalizeRedactionPolicy({
      namesHeuristic: true,
      phones: true,
      ipAddresses: true,
      jwtAndBearer: true,
    });

    const first = __shareSessionTestUtils.defaultRedactHtmlForShare(
      "John Appleseed alice@example.com +1 (415) 555-1212 10.0.0.8 /Users/alice/workspace/oppi",
      policy,
    );
    const second = __shareSessionTestUtils.defaultRedactHtmlForShare(first.html, policy);

    expect(second.totalReplacements).toBe(0);
    expect(second.html).toBe(first.html);
  });
});

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { ProjectTrustStore, type ResourceLoader } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";

import type { AgentDefinition } from "../src/agent-launch-service.js";
import * as GondolinManagerModule from "../src/gondolin-manager.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { serverResourceId } from "../src/server-resource-id.js";
import type { Session, Workspace } from "../src/types.js";

function makeSession(): Session {
  const now = Date.now();
  return {
    id: "agent-resource-session",
    workspaceId: "workspace-1",
    status: "starting",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    launch: {
      status: "launching",
      requestedAt: now,
      agentId: "agent-1",
    },
  };
}

function resourceLoader(backend: SdkBackend): ResourceLoader {
  return (
    backend as unknown as {
      runtime: { services: { resourceLoader: ResourceLoader } };
    }
  ).runtime.services.resourceLoader;
}

describe("saved Agent exact resource selection", { concurrent: false }, () => {
  it("treats explicit empty Skill and Extension arrays as none", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-no-resources-"));
    const skillDir = join(cwd, ".pi", "skills", "project-skill");
    const extensionDir = join(cwd, ".pi", "extensions");
    mkdirSync(skillDir, { recursive: true });
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: project-skill",
        "description: A normally discovered project Skill.",
        "---",
        "Project Skill instructions.",
      ].join("\n"),
    );
    writeFileSync(
      join(extensionDir, "project-command.ts"),
      [
        "import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';",
        "export default function (pi: ExtensionAPI) {",
        "  pi.registerCommand('project-command', { description: 'Project command', handler: async () => {} });",
        "}",
      ].join("\n"),
    );
    const agentDefinition: AgentDefinition = {
      name: "No Resources",
      resources: { skillPaths: [], extensionIds: [] },
    };

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Agent Resource Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const loader = resourceLoader(backend);
      expect(loader.getSkills().skills).toEqual([]);
      expect(
        loader.getExtensions().extensions.flatMap((extension) => [...extension.commands.keys()]),
      ).not.toContain("project-command");
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("loads only the selected Skill paths", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-selected-skill-"));
    const projectSkill = join(cwd, ".pi", "skills", "project-skill");
    const selectedSkill = join(cwd, "selected-skills", "selected-skill");
    for (const [dir, name] of [
      [projectSkill, "project-skill"],
      [selectedSkill, "selected-skill"],
    ] as const) {
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        join(dir, "SKILL.md"),
        [
          "---",
          `name: ${name}`,
          `description: ${name} description.`,
          "---",
          `${name} instructions.`,
        ].join("\n"),
      );
    }

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Selected Skill Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition: {
        name: "Selected Skill",
        resources: { skillPaths: [selectedSkill], extensionIds: [] },
      },
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      expect(
        resourceLoader(backend)
          .getSkills()
          .skills.map((skill) => skill.name),
      ).toEqual(["selected-skill"]);
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("keeps an exact selected Skill session coherent when the Skill disappears during reload", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-selected-skill-reload-"));
    const selectedSkill = join(cwd, "selected-skills", "selected-skill");
    mkdirSync(selectedSkill, { recursive: true });
    writeFileSync(
      join(selectedSkill, "SKILL.md"),
      [
        "---",
        "name: selected-skill",
        "description: Selected Skill description.",
        "---",
        "Selected Skill instructions.",
      ].join("\n"),
    );

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Selected Skill Reload Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition: {
        name: "Selected Skill Reload",
        resources: { skillPaths: [selectedSkill], extensionIds: [] },
      },
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const reload = vi.spyOn(backend.session, "reload");
      rmSync(selectedSkill, { recursive: true, force: true });
      await expect(backend.reloadResources()).rejects.toThrow(
        "Selected Agent Skill is unavailable",
      );
      await expect(
        backend.withModelTurnAdmission("prompt", async () => "must not run"),
      ).rejects.toThrow("restore the resource and reload");
      expect(reload).not.toHaveBeenCalled();
      expect(backend.isDisposed).toBe(false);
      reload.mockRestore();
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("blocks model turns until an invalid exact Skill is restored and reloaded", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-invalid-skill-reload-"));
    const selectedSkill = join(cwd, "selected-skills", "selected-skill");
    const skillFile = join(selectedSkill, "SKILL.md");
    mkdirSync(selectedSkill, { recursive: true });
    const validSkill = [
      "---",
      "name: selected-skill",
      "description: Selected Skill description.",
      "---",
      "Selected Skill instructions.",
    ].join("\n");
    writeFileSync(skillFile, validSkill);

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Invalid Selected Skill Reload Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition: {
        name: "Invalid Selected Skill Reload",
        resources: { skillPaths: [selectedSkill], extensionIds: [] },
      },
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      writeFileSync(skillFile, "---\nname: selected-skill\n---\nMissing description.\n");
      await expect(backend.reloadResources()).rejects.toThrow(
        "Selected Agent Skill is unavailable",
      );
      await expect(
        backend.withModelTurnAdmission("prompt", async () => "must not run"),
      ).rejects.toThrow("restore the resource and reload");
      await expect(
        backend.replaceQueuedModelTurns({
          prompt: { message: "must not start" },
          steering: [],
          followUp: [],
        }),
      ).rejects.toThrow("restore the resource and reload");

      writeFileSync(skillFile, validSkill);
      await expect(backend.reloadResources()).resolves.toEqual({ success: true });
      await expect(backend.withModelTurnAdmission("prompt", async () => "allowed")).resolves.toBe(
        "allowed",
      );
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("resolves selected server Extension IDs and excludes normal discovery", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-selected-extension-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-selected-extension-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    const extensionDir = join(agentDir, "extensions");
    const selectedExtension = join(extensionDir, "selected-command.ts");
    const projectExtensionDir = join(cwd, ".pi", "extensions");
    mkdirSync(extensionDir, { recursive: true });
    mkdirSync(projectExtensionDir, { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}");
    const selectedExtensionSource =
      "export default function (pi) { pi.registerCommand('selected-command', { description: 'Selected', handler: async () => {} }); }";
    writeFileSync(selectedExtension, selectedExtensionSource);
    writeFileSync(
      join(projectExtensionDir, "project-command.ts"),
      "export default function (pi) { pi.registerCommand('project-command', { description: 'Project', handler: async () => {} }); }",
    );
    process.env.PI_CODING_AGENT_DIR = agentDir;

    let backend: SdkBackend | undefined;
    try {
      backend = await SdkBackend.create({
        session: makeSession(),
        workspace: {
          id: "workspace-1",
          name: "Selected Extension Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Selected Extension",
          resources: {
            skillPaths: [],
            extensionIds: [serverResourceId("extension", selectedExtension)],
          },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      const commands = resourceLoader(backend)
        .getExtensions()
        .extensions.flatMap((extension) => [...extension.commands.keys()]);
      expect(commands).toContain("selected-command");
      expect(commands).not.toContain("project-command");

      writeFileSync(selectedExtension, "throw new Error('selected extension is invalid');");
      await expect(backend.reloadResources()).rejects.toThrow(
        "Selected Agent Extension could not be loaded",
      );
      await expect(
        backend.withModelTurnAdmission("prompt", async () => "must not run"),
      ).rejects.toThrow("restore the resource and reload");

      writeFileSync(selectedExtension, selectedExtensionSource);
      await expect(backend.reloadResources()).resolves.toEqual({ success: true });
      await expect(backend.withModelTurnAdmission("prompt", async () => "allowed")).resolves.toBe(
        "allowed",
      );
    } finally {
      if (backend) await backend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  });

  it("starts with a warning and drops a stale allowed tool instead of failing the launch", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-missing-tool-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-missing-tool-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    const extensionDir = join(agentDir, "extensions");
    const selectedExtension = join(extensionDir, "selected-command.ts");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}");
    writeFileSync(
      selectedExtension,
      "export default function (pi) { pi.registerTool({ name: 'other_tool', label: 'Other', description: 'Other tool', parameters: { type: 'object', properties: {} }, execute: async () => ({ content: [{ type: 'text', text: 'ok' }] }) }); }",
    );
    process.env.PI_CODING_AGENT_DIR = agentDir;

    let backend: SdkBackend | undefined;
    try {
      const session = makeSession();
      session.launch = {
        ...session.launch,
        status: "launching",
        requestedAt: session.createdAt,
        agentId: "agent-1",
        // `stale_tool` matches no registered tool; `other_tool` comes from the
        // selected Extension. The launch must keep `other_tool`, drop
        // `stale_tool`, and record exactly one session warning.
        tools: { allowed: ["stale_tool", "other_tool"], noTools: "builtin" },
      };

      backend = await SdkBackend.create({
        session,
        workspace: {
          id: "workspace-1",
          name: "Stale Agent Tool Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Stale Agent Tool",
          resources: {
            skillPaths: [],
            extensionIds: [serverResourceId("extension", selectedExtension)],
          },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      const activeToolNames = backend.session.agent.state.tools.map((tool) => tool.name);
      expect(activeToolNames).toContain("other_tool");
      expect(activeToolNames).not.toContain("stale_tool");
      expect(session.warnings).toHaveLength(1);
      expect(session.warnings?.[0]).toContain(
        "Configured Agent tool is unavailable and was dropped from this session: stale_tool",
      );
      expect(session.warnings?.[0]).toContain("Edit the Agent's Allowed Tools");
      // The requested launch policy stays untouched; only the effective runtime
      // tool set dropped the stale name.
      expect(session.launch?.tools?.allowed).toEqual(["stale_tool", "other_tool"]);
    } finally {
      if (backend) await backend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  });

  it("still starts with the reserved tools and a loud warning when every allowed tool is missing", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-all-tools-missing-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-all-tools-missing-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}");
    process.env.PI_CODING_AGENT_DIR = agentDir;

    let backend: SdkBackend | undefined;
    try {
      const session = makeSession();
      session.launch = {
        ...session.launch,
        status: "launching",
        requestedAt: session.createdAt,
        agentId: "agent-1",
        tools: { allowed: ["request_feedback"], noTools: "builtin" },
      };

      backend = await SdkBackend.create({
        session,
        workspace: {
          id: "workspace-1",
          name: "All Tools Missing Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "All Tools Missing",
          resources: { skillPaths: [], extensionIds: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      const activeToolNames = backend.session.agent.state.tools.map((tool) => tool.name);
      expect(activeToolNames).not.toContain("request_feedback");
      expect(activeToolNames).not.toContain("oppi");
      expect(session.warnings).toHaveLength(1);
      expect(session.warnings?.[0]).toContain(
        "Every configured Agent tool is unavailable and was dropped from this session: request_feedback",
      );
      expect(session.warnings?.[0]).toContain("may not work as intended");
    } finally {
      if (backend) await backend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  });

  it("does not falsely drop MCP allowlist tools before builtin:mcp connects, while still warning on real stale tools", async () => {
    const fixture = fileURLToPath(new URL("./fixtures/mcp-echo-server.mjs", import.meta.url));
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-mcp-tools-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-mcp-tools-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    mkdirSync(join(cwd, ".pi"), { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}");
    writeFileSync(
      join(cwd, ".pi", "mcp.json"),
      JSON.stringify({
        mcpServers: {
          direct_echo: {
            command: process.execPath,
            args: [fixture],
            exposure: "direct",
          },
          deferred_echo: {
            command: process.execPath,
            args: [fixture],
            exposure: "deferred",
          },
        },
      }),
    );
    new ProjectTrustStore(agentDir).set(cwd, true);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    let cleanBackend: SdkBackend | undefined;
    let staleBackend: SdkBackend | undefined;
    let disabledMcpBackend: SdkBackend | undefined;
    let omittedMcpBackend: SdkBackend | undefined;
    try {
      // 1. Inherited extension discovery loads builtin:mcp + builtin:tool-search:
      // neither direct nor deferred MCP allowlist entries (nor wildcards) warn as dropped,
      // and both servers' tools register once session_start connects them.
      const cleanSession = makeSession();
      cleanSession.launch = {
        ...cleanSession.launch,
        status: "launching",
        requestedAt: cleanSession.createdAt,
        agentId: "agent-mcp-clean",
        tools: {
          allowed: [
            "read",
            "tool_search",
            "mcp__direct_echo__echo",
            "mcp__deferred_echo__echo",
            "mcp__wildcard__*",
          ],
        },
      };

      cleanBackend = await SdkBackend.create({
        session: cleanSession,
        workspace: {
          id: "workspace-1",
          name: "Agent MCP Clean Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Agent MCP Clean",
          resources: { skillPaths: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(cleanSession.warnings).toBeUndefined();
      expect(cleanBackend.session.agent.state.tools.map((tool) => tool.name)).toContain(
        "tool_search",
      );

      // Wait for both project MCP servers to finish connecting after session_start.
      await vi.waitFor(
        () => {
          const allNames = cleanBackend!.session.getAllTools().map((tool) => tool.name);
          expect(allNames).toContain("mcp__direct_echo__echo");
          expect(allNames).toContain("mcp__deferred_echo__echo");
        },
        { timeout: 10_000 },
      );
      // Direct MCP tool becomes active; deferred stays registered for tool_search.
      expect(cleanBackend.session.agent.state.tools.map((tool) => tool.name)).toContain(
        "mcp__direct_echo__echo",
      );
      expect(cleanBackend.session.agent.state.tools.map((tool) => tool.name)).not.toContain(
        "mcp__deferred_echo__echo",
      );

      // 2. A genuine stale non-MCP tool still warns without blaming MCP tools.
      const staleSession = makeSession();
      staleSession.launch = {
        ...staleSession.launch,
        status: "launching",
        requestedAt: staleSession.createdAt,
        agentId: "agent-mcp-stale",
        tools: {
          allowed: ["read", "mcp__direct_echo__echo", "genuinely_missing_tool"],
        },
      };

      staleBackend = await SdkBackend.create({
        session: staleSession,
        workspace: {
          id: "workspace-1",
          name: "Agent MCP Stale Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Agent MCP Stale",
          resources: { skillPaths: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(staleSession.warnings).toHaveLength(1);
      expect(staleSession.warnings?.[0]).toContain("genuinely_missing_tool");
      expect(staleSession.warnings?.[0]).not.toContain("mcp__direct_echo__echo");

      // 3. When MCP is turned off (or excluded from extensionIds), MCP allowlist tools
      // really are unavailable and still warn.
      const disabledSession = makeSession();
      disabledSession.launch = {
        ...disabledSession.launch,
        status: "launching",
        requestedAt: disabledSession.createdAt,
        agentId: "agent-mcp-off",
        tools: {
          allowed: ["read", "mcp__direct_echo__echo"],
        },
      };

      disabledMcpBackend = await SdkBackend.create({
        session: disabledSession,
        workspace: {
          id: "workspace-1",
          name: "Agent MCP Off Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Agent MCP Off",
          resources: { skillPaths: [] },
        },
        mcpEnabled: () => false,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(disabledSession.warnings).toHaveLength(1);
      expect(disabledSession.warnings?.[0]).toContain("mcp__direct_echo__echo");

      // 4. An exact extensionIds selection without builtin:mcp also still warns on MCP tools.
      const omittedMcpSession = makeSession();
      omittedMcpSession.launch = {
        ...omittedMcpSession.launch,
        status: "launching",
        requestedAt: omittedMcpSession.createdAt,
        agentId: "agent-mcp-omitted",
        tools: {
          allowed: ["read", "mcp__direct_echo__echo"],
        },
      };

      omittedMcpBackend = await SdkBackend.create({
        session: omittedMcpSession,
        workspace: {
          id: "workspace-1",
          name: "Agent MCP Omitted Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Agent MCP Omitted",
          resources: { skillPaths: [], extensionIds: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(omittedMcpSession.warnings).toHaveLength(1);
      expect(omittedMcpSession.warnings?.[0]).toContain("mcp__direct_echo__echo");
    } finally {
      if (cleanBackend) await cleanBackend.dispose();
      if (staleBackend) await staleBackend.dispose();
      if (disabledMcpBackend) await disabledMcpBackend.dispose();
      if (omittedMcpBackend) await omittedMcpBackend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  }, 20_000);

  it("in a sandbox, exempts only picked sandboxConfig.mcpServers namespaces and warns on unpicked MCP servers", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-sandbox-mcp-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-sandbox-mcp-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    writeFileSync(join(agentDir, "auth.json"), "{}");
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          "picked-server": { url: "https://picked.example.com/mcp", exposure: "deferred" },
          "unpicked-server": { url: "https://unpicked.example.com/mcp", exposure: "deferred" },
        },
      }),
    );
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const qemuSpy = vi.spyOn(GondolinManagerModule, "isQemuAvailable").mockResolvedValue(true);
    const execResult = { exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0), ok: true };
    const vm = {
      fs: {
        access: vi.fn(async () => {
          throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
        }),
        mkdir: vi.fn(async () => undefined),
        readFile: vi.fn(async () => Buffer.alloc(0)),
        writeFile: vi.fn(async () => undefined),
        readdir: vi.fn(async () => []),
      },
      exec: vi.fn(() =>
        Object.assign(Promise.resolve(execResult), {
          output: async function* () {},
          write: () => {},
          end: () => {},
        }),
      ),
    };
    const sdkBackendType = SdkBackend as unknown as {
      _gondolinManager?: { ensureWorkspaceVm: () => Promise<typeof vm> };
    };
    const previousManager = sdkBackendType._gondolinManager;
    sdkBackendType._gondolinManager = { ensureWorkspaceVm: vi.fn(async () => vm) };

    let pickedBackend: SdkBackend | undefined;
    let emptyPicksBackend: SdkBackend | undefined;
    try {
      const pickedSession = makeSession();
      pickedSession.launch = {
        ...pickedSession.launch,
        status: "launching",
        requestedAt: pickedSession.createdAt,
        agentId: "agent-sandbox-mcp",
        tools: {
          allowed: [
            "read",
            "tool_search",
            "mcp__picked_server__echo",
            "mcp__picked_server__*",
            "mcp__unpicked_server__echo",
          ],
        },
      };

      pickedBackend = await SdkBackend.create({
        session: pickedSession,
        workspace: {
          id: "workspace-sandbox-mcp",
          name: "Sandbox MCP Agent Test",
          runtime: "sandbox",
          hostMount: cwd,
          sandboxConfig: {
            allowedHosts: [],
            mcpServers: ["picked-server"],
          },
        } as Workspace,
        agentDefinition: {
          name: "Sandbox MCP Agent",
          resources: { skillPaths: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(pickedSession.warnings).toHaveLength(1);
      expect(pickedSession.warnings?.[0]).toContain("mcp__unpicked_server__echo");
      expect(pickedSession.warnings?.[0]).not.toContain("mcp__picked_server__echo");
      expect(pickedSession.warnings?.[0]).not.toContain("mcp__picked_server__*");

      // With no sandboxConfig.mcpServers picked, every MCP tool warns.
      const emptyPicksSession = makeSession();
      emptyPicksSession.launch = {
        ...emptyPicksSession.launch,
        status: "launching",
        requestedAt: emptyPicksSession.createdAt,
        agentId: "agent-sandbox-mcp-none",
        tools: {
          allowed: ["read", "mcp__picked_server__echo", "list_mcp_resources"],
        },
      };

      emptyPicksBackend = await SdkBackend.create({
        session: emptyPicksSession,
        workspace: {
          id: "workspace-sandbox-mcp-none",
          name: "Sandbox MCP Empty Picks Test",
          runtime: "sandbox",
          hostMount: cwd,
          sandboxConfig: {
            allowedHosts: [],
            mcpServers: [],
          },
        } as Workspace,
        agentDefinition: {
          name: "Sandbox MCP Empty Picks",
          resources: { skillPaths: [] },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      expect(emptyPicksSession.warnings).toHaveLength(1);
      expect(emptyPicksSession.warnings?.[0]).toContain("mcp__picked_server__echo");
      expect(emptyPicksSession.warnings?.[0]).toContain("list_mcp_resources");
    } finally {
      if (pickedBackend) await pickedBackend.dispose();
      if (emptyPicksBackend) await emptyPicksBackend.dispose();
      sdkBackendType._gondolinManager = previousManager;
      qemuSpy.mockRestore();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  }, 20_000);

  it("resolves selected Extension IDs that are only available at project scope", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-project-extension-cwd-"));
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-agent-project-extension-agent-"));
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    const userExtensionDir = join(agentDir, "extensions");
    const projectExtensionDir = join(cwd, ".pi", "extensions");
    const selectedExtension = join(userExtensionDir, "selected-command.ts");
    mkdirSync(userExtensionDir, { recursive: true });
    mkdirSync(projectExtensionDir, { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}");
    // Disabled at user scope so package discovery only keeps the project enablement.
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({
        extensions: ["-extensions/selected-command.ts"],
      }),
    );
    writeFileSync(
      selectedExtension,
      "export default function (pi) { pi.registerCommand('selected-command', { description: 'Selected', handler: async () => {} }); }",
    );
    writeFileSync(
      join(cwd, ".pi", "settings.json"),
      JSON.stringify({
        extensions: [`+${selectedExtension}`],
      }),
    );
    process.env.PI_CODING_AGENT_DIR = agentDir;

    let backend: SdkBackend | undefined;
    try {
      backend = await SdkBackend.create({
        session: makeSession(),
        workspace: {
          id: "workspace-1",
          name: "Project Extension Test",
          runtime: "host",
          hostMount: cwd,
        } as Workspace,
        agentDefinition: {
          name: "Project Extension",
          resources: {
            skillPaths: [],
            extensionIds: [serverResourceId("extension", selectedExtension)],
          },
        },
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });

      const commands = resourceLoader(backend)
        .getExtensions()
        .extensions.flatMap((extension) => [...extension.commands.keys()]);
      expect(commands).toContain("selected-command");
    } finally {
      if (backend) await backend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  });

  it("treats oppi like any unavailable selected Extension ID", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-unavailable-extension-"));
    try {
      await expect(
        SdkBackend.create({
          session: makeSession(),
          workspace: {
            id: "workspace-1",
            name: "Unavailable Extension Test",
            runtime: "host",
            hostMount: cwd,
          } as Workspace,
          agentDefinition: {
            name: "Unavailable Extension",
            resources: { skillPaths: [], extensionIds: ["oppi"] },
          },
          onEvent: vi.fn(),
          onEnd: vi.fn(),
        }),
      ).rejects.toMatchObject({
        message: "Selected Agent Extension is unavailable: oppi",
        details: { unavailableExtensions: ["oppi"] },
      });
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("fails closed when a selected Extension ID is no longer discovered", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-agent-missing-extension-"));
    try {
      await expect(
        SdkBackend.create({
          session: makeSession(),
          workspace: {
            id: "workspace-1",
            name: "Missing Extension Test",
            runtime: "host",
            hostMount: cwd,
          } as Workspace,
          agentDefinition: {
            name: "Missing Extension",
            resources: {
              extensionIds: [`extension_${"0".repeat(64)}`, `extension_${"1".repeat(64)}`],
            },
          },
          onEvent: vi.fn(),
          onEnd: vi.fn(),
        }),
      ).rejects.toMatchObject({
        message: expect.stringContaining("Selected Agent Extension is unavailable"),
        details: {
          unavailableExtensions: [`extension_${"0".repeat(64)}`, `extension_${"1".repeat(64)}`],
        },
      });
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});

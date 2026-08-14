import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { ResourceLoader } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";

import type { AgentDefinition } from "../src/agent-launch-service.js";
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

describe.sequential("saved Agent exact resource selection", () => {
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

  it("fails closed when an explicit Agent tool is not registered by its selected Extensions", async () => {
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
        tools: { allowed: ["hacker_news"], noTools: "builtin" },
      };

      await expect(async () => {
        backend = await SdkBackend.create({
          session,
          workspace: {
            id: "workspace-1",
            name: "Missing Agent Tool Test",
            runtime: "host",
            hostMount: cwd,
          } as Workspace,
          agentDefinition: {
            name: "Missing Agent Tool",
            resources: {
              skillPaths: [],
              extensionIds: [serverResourceId("extension", selectedExtension)],
            },
          },
          onEvent: vi.fn(),
          onEnd: vi.fn(),
        });
      }).rejects.toThrow(
        "Configured Agent tool is unavailable: hacker_news. Update the Agent's selected Extensions or tool allowlist.",
      );
    } finally {
      if (backend) await backend.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(cwd, { recursive: true, force: true });
      rmSync(agentDir, { recursive: true, force: true });
    }
  });

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

import * as fs from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import type { ServerMessage, Session, SubagentConfig } from "../src/types.js";

export interface SubagentsContext {
  workspaceId: string;
  sessionId: string;
  spawnChild(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
  }): Promise<Session>;
  spawnDetached(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
  }): Promise<Session>;
  listChildren(): Session[];
  getSession(sessionId: string): Session | undefined;
  listWorkspaceSessions(): Session[];
  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void;
  getAvailableModelIds(): string[];
  stopSession(sessionId: string): Promise<void>;
  resumeSession(sessionId: string): Promise<Session>;
  sendMessage(sessionId: string, message: string, behavior?: "steer" | "followUp"): Promise<void>;
}

export interface SubagentsFactoryOptions {
  childMode?: boolean;
  subagentConfig?: SubagentConfig;
}

interface SubagentsModule {
  createSubagentsFactory(
    ctx: SubagentsContext,
    options?: SubagentsFactoryOptions,
  ): ExtensionFactory;
}

let subagentsModulePromise: Promise<SubagentsModule> | undefined;

async function loadSubagentsModule(): Promise<SubagentsModule> {
  if (subagentsModulePromise) {
    return subagentsModulePromise;
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    resolve(here, "..", "..", "oppi-extensions", "src", "subagents", "index.ts"),
    resolve(here, "..", "oppi-extensions", "src", "subagents", "index.js"),
  ];
  const implementationPath = candidates.find((candidate) => fs.existsSync(candidate));

  if (!implementationPath) {
    throw new Error(
      `Unable to locate subagents implementation. Checked:\n${candidates.map((candidate) => `  - ${candidate}`).join("\n")}`,
    );
  }

  subagentsModulePromise = import(
    pathToFileURL(implementationPath).href
  ) as Promise<SubagentsModule>;
  return subagentsModulePromise;
}

export function createSubagentsFactory(
  ctx: SubagentsContext,
  options?: SubagentsFactoryOptions,
): ExtensionFactory {
  return async (pi) => {
    const mod = await loadSubagentsModule();
    return mod.createSubagentsFactory(ctx, options)(pi);
  };
}

import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

import type { ServerMessage, Session, SubagentConfig } from "../src/types.js";
import { createSubagentsFactory as createSubagentsImplementationFactory } from "./subagents/index.js";

export interface SubagentsContext {
  workspaceId: string;
  sessionId: string;
  spawnChild(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
    activeTools?: string[];
    profileName?: string;
  }): Promise<Session>;
  spawnDetached(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
    activeTools?: string[];
    profileName?: string;
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

export function createSubagentsFactory(
  ctx: SubagentsContext,
  options?: SubagentsFactoryOptions,
): ExtensionFactory {
  return createSubagentsImplementationFactory(ctx, options);
}

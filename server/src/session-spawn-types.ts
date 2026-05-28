import type { Session, ServerMessage } from "./types.js";

export type SpawnSessionParams = {
  name?: string;
  model?: string;
  thinking?: string;
  prompt: string;
  activeTools?: string[];
  profileName?: string;
};

export type SpawnChildSession = (
  parentSessionId: string,
  params: SpawnSessionParams,
) => Promise<Session>;

export type SpawnDetachedSession = (
  originSessionId: string,
  params: SpawnSessionParams,
) => Promise<Session>;

export type ListChildSessions = (parentSessionId: string) => Session[];

export type SubscribeToSession = (
  sessionId: string,
  callback: (msg: ServerMessage) => void,
) => () => void;

export type SendSessionMessage = (
  sessionId: string,
  message: string,
  behavior?: "steer" | "followUp",
) => Promise<void>;

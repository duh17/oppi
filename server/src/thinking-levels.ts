import type { AgentSession } from "@earendil-works/pi-coding-agent";

// pi's own union, read from the runtime API — no new dep, no version skew.
// Deriving from AgentSession.setThinkingLevel pins the type to the pi package
// that actually runs, so a pi-level change becomes a compile error here.
export type ThinkingLevel = Parameters<AgentSession["setThinkingLevel"]>[0];

// Bidirectional: errors if pi ADDS a level we lack, and if we list a bogus one.
const THINKING_LEVEL_SET = {
  off: true,
  minimal: true,
  low: true,
  medium: true,
  high: true,
  xhigh: true,
  max: true,
} satisfies Record<ThinkingLevel, true>;

export const THINKING_LEVELS = Object.keys(THINKING_LEVEL_SET) as ThinkingLevel[]; // off→max order
// Object.hasOwn (not `in`) so prototype keys like "constructor" are rejected, matching the old Set.has behavior.
export const isThinkingLevel = (v: string): v is ThinkingLevel =>
  Object.hasOwn(THINKING_LEVEL_SET, v);

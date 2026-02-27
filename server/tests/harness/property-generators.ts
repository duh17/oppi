import type { ClientMessage } from "../../src/types.js";

export type LifecycleCommand = Extract<ClientMessage, { type: "subscribe" | "unsubscribe" }>;

export interface LifecycleProgramOptions {
  seed: number;
  sessionId: string;
  steps: number;
}

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let t = Math.imul(state ^ (state >>> 15), state | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function generateLifecycleProgram(options: LifecycleProgramOptions): LifecycleCommand[] {
  const rng = mulberry32(options.seed);
  const commands: LifecycleCommand[] = [];

  for (let index = 0; index < options.steps; index += 1) {
    const requestId = `seed-${options.seed}-cmd-${index}`;
    const roll = rng();

    if (roll < 0.35) {
      commands.push({
        type: "unsubscribe",
        sessionId: options.sessionId,
        requestId,
      });
      continue;
    }

    commands.push({
      type: "subscribe",
      sessionId: options.sessionId,
      requestId,
      level: rng() < 0.5 ? "full" : "notifications",
    });
  }

  return commands;
}

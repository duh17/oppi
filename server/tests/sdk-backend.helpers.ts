/**
 * Shared test helpers for mocking SdkBackend in session tests.
 */
import { vi } from "vitest";
import type { SdkBackend } from "../src/sdk-backend.js";

export function makeSdkBackendStub(): {
  sdkBackend: SdkBackend;
  abort: ReturnType<typeof vi.fn>;
  dispose: ReturnType<typeof vi.fn>;
  prompt: ReturnType<typeof vi.fn>;
} {
  const abort = vi.fn(async () => {});
  const shutdownCleanupListeners = new Set<() => void>();

  const steeringMessages: string[] = [];
  const followUpMessages: string[] = [];

  const prompt = vi.fn(
    async (
      text: string,
      opts?: {
        streamingBehavior?: "steer" | "followUp";
        images?: unknown[];
        onPreflightAccepted?: () => void;
      },
    ) => {
      if (opts?.streamingBehavior === "steer") {
        steeringMessages.push(text);
      } else if (opts?.streamingBehavior === "followUp") {
        followUpMessages.push(text);
      }
      opts?.onPreflightAccepted?.();
    },
  );

  const session = {
    setThinkingLevel: vi.fn(),
    setSessionName: vi.fn(),
    messages: [],
    getSessionStats: vi.fn(() => ({})),
    compact: vi.fn(async () => ({})),
    abortBash: vi.fn(),
    dispose: vi.fn(),
    steer: vi.fn(async (text: string, images?: unknown[]) => {
      void images;
      steeringMessages.push(text);
    }),
    followUp: vi.fn(async (text: string, images?: unknown[]) => {
      void images;
      followUpMessages.push(text);
    }),
    clearQueue: vi.fn(() => {
      steeringMessages.length = 0;
      followUpMessages.length = 0;
      return { steering: [], followUp: [] };
    }),
    getSteeringMessages: vi.fn(() => [...steeringMessages]),
    getFollowUpMessages: vi.fn(() => [...followUpMessages]),
  };

  const sdkBackend = {
    prompt,
    abort,
    withRuntimeLifecycleTransaction: vi.fn(
      async (_name: string, operation: (permit: { mode: "exclusive" }) => Promise<unknown>) =>
        operation({ mode: "exclusive" }),
    ),
    isRuntimeLifecycleTransactionExclusive: false,
    captureEmergencyDisposalForStop: vi.fn(() => () => {
      (sdkBackend as { isDisposed: boolean }).isDisposed = true;
      session.dispose();
      return {
        disposal: "forced" as const,
        cause: "lifecycle_timeout" as const,
        operation: "stop" as const,
        timeoutMs: 6_000,
      };
    }),
    clearQueuedModelTurns: vi.fn(() => session.clearQueue()),
    replaceQueuedModelTurns: vi.fn(
      async (batch: {
        prompt?: { message: string; images?: unknown[] };
        steering: Array<{ message: string; images?: unknown[] }>;
        followUp: Array<{ message: string; images?: unknown[] }>;
      }) => {
        session.clearQueue();
        for (const item of batch.steering) await session.steer(item.message, item.images);
        for (const item of batch.followUp) await session.followUp(item.message, item.images);
        if (batch.prompt) await prompt(batch.prompt.message, { images: batch.prompt.images });
      },
    ),
    setModel: vi.fn(async () => ({ success: true })),
    newSession: vi.fn(async () => ({ cancelled: false })),
    fork: vi.fn(async () => ({ cancelled: false })),
    getStateSnapshot: vi.fn(() => ({
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
      thinkingLevel: "medium",
      isStreaming: false,
    })),
    session,
    abortBash: session.abortBash,
    queuedMessages: () => ({
      steering: session.getSteeringMessages(),
      followUp: session.getFollowUpMessages(),
    }),
    leafId: () => null,
    sessionTree: () => undefined,
    toolDefinition: () => undefined,
    setThinkingLevel: session.setThinkingLevel,
    setSessionName: session.setSessionName,
    messages: () => session.messages,
    getSessionStats: session.getSessionStats,
    compact: session.compact,
    respondToExtensionUIRequest: vi.fn(() => true),
    onShutdownCleanupComplete: vi.fn((listener: () => void) => {
      if ((sdkBackend as { isDisposed: boolean }).isDisposed) {
        listener();
        return;
      }
      shutdownCleanupListeners.add(listener);
    }),
    isDisposed: false,
    isStreaming: false,
    hasPendingWake: vi.fn(async () => false),
    hasPendingWork: vi.fn(async () => false),
    sessionFile: undefined,
    sessionId: "pi-session-1",
    dispose: vi.fn(),
  } as unknown as SdkBackend;

  const dispose = vi.fn(async () => {
    (sdkBackend as { isDisposed: boolean }).isDisposed = true;
    for (const listener of shutdownCleanupListeners) {
      listener();
    }
    shutdownCleanupListeners.clear();
    return { disposal: "graceful" as const };
  });
  (sdkBackend as { dispose: typeof dispose }).dispose = dispose;

  return { sdkBackend, abort, dispose, prompt };
}

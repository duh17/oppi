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
  let queueAuthorityGeneration = 0;

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
        queueAuthorityGeneration += 1;
      } else if (opts?.streamingBehavior === "followUp") {
        followUpMessages.push(text);
        queueAuthorityGeneration += 1;
      }
      opts?.onPreflightAccepted?.();
    },
  );

  const session = {
    setThinkingLevel: vi.fn(),
    cycleModel: vi.fn(async () => undefined),
    cycleThinkingLevel: vi.fn(() => "high"),
    setSessionName: vi.fn(),
    messages: [],
    getSessionStats: vi.fn(() => ({})),
    compact: vi.fn(async () => ({})),
    setAutoCompactionEnabled: vi.fn(),
    setSteeringMode: vi.fn(),
    setFollowUpMode: vi.fn(),
    setAutoRetryEnabled: vi.fn(),
    abortRetry: vi.fn(),
    abortBash: vi.fn(),
    dispose: vi.fn(),
    steer: vi.fn(async (text: string, images?: unknown[]) => {
      void images;
      steeringMessages.push(text);
      queueAuthorityGeneration += 1;
    }),
    followUp: vi.fn(async (text: string, images?: unknown[]) => {
      void images;
      followUpMessages.push(text);
      queueAuthorityGeneration += 1;
    }),
    clearQueue: vi.fn(() => {
      steeringMessages.length = 0;
      followUpMessages.length = 0;
      queueAuthorityGeneration += 1;
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
    captureQueuedModelTurnsAuthority: vi.fn(() => ({
      generation: queueAuthorityGeneration,
    })),
    assertQueuedModelTurnsAuthority: vi.fn((authority: { generation: number }) => {
      if (authority.generation !== queueAuthorityGeneration) {
        throw new Error("Pi queue authority changed");
      }
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
        return { generation: queueAuthorityGeneration };
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

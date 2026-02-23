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
  const dispose = vi.fn();
  const prompt = vi.fn();

  const session = {
    setThinkingLevel: vi.fn(),
    cycleModel: vi.fn(async () => undefined),
    cycleThinkingLevel: vi.fn(() => "high"),
    setSessionName: vi.fn(),
    messages: [],
    getSessionStats: vi.fn(() => ({})),
    compact: vi.fn(async () => ({})),
    setAutoCompactionEnabled: vi.fn(),
    newSession: vi.fn(async () => true),
    fork: vi.fn(async () => ({})),
    switchSession: vi.fn(async () => true),
    setSteeringMode: vi.fn(),
    setFollowUpMode: vi.fn(),
    setAutoRetryEnabled: vi.fn(),
    abortRetry: vi.fn(),
    abortBash: vi.fn(),
  };

  const sdkBackend = {
    prompt,
    abort,
    setModel: vi.fn(async () => ({ success: true })),
    getStateSnapshot: vi.fn(() => ({
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
      thinkingLevel: "medium",
      isStreaming: false,
    })),
    session,
    respondToExtensionUIRequest: vi.fn(() => true),
    isDisposed: false,
    isStreaming: false,
    sessionFile: undefined,
    sessionId: "pi-session-1",
    dispose,
  } as unknown as SdkBackend;

  return { sdkBackend, abort, dispose, prompt };
}

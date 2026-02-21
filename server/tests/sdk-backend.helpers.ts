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
  const sdkBackend = {
    prompt,
    abort,
    setModel: vi.fn(async () => ({ success: true })),
    setThinkingLevel: vi.fn(),
    getState: vi.fn(() => ({
      model: "anthropic/claude-sonnet-4-0",
      thinkingLevel: "medium",
      isStreaming: false,
      sessionFile: undefined,
    })),
    getStateSnapshot: vi.fn(() => ({
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
      thinkingLevel: "medium",
      isStreaming: false,
    })),
    cycleModel: vi.fn(async () => undefined),
    cycleThinkingLevel: vi.fn(() => "high"),
    setSessionName: vi.fn(),
    getMessages: vi.fn(() => []),
    getSessionStats: vi.fn(() => ({})),
    compact: vi.fn(async () => ({})),
    setAutoCompaction: vi.fn(),
    newSession: vi.fn(async () => true),
    fork: vi.fn(async () => ({})),
    switchSession: vi.fn(async () => true),
    setSteeringMode: vi.fn(),
    setFollowUpMode: vi.fn(),
    setAutoRetry: vi.fn(),
    abortRetry: vi.fn(),
    abortBash: vi.fn(),
    isDisposed: false,
    isStreaming: false,
    sessionFile: undefined,
    sessionId: "pi-session-1",
    dispose,
  } as unknown as SdkBackend;
  return { sdkBackend, abort, dispose, prompt };
}

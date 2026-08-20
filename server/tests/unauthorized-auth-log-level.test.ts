import { describe, expect, it } from "vitest";

import { unauthorizedAuthLogLevel } from "../src/server.js";

describe("unauthorizedAuthLogLevel", () => {
  // First-pass choice: we do not track first vs repeat unknown_token. The Apple
  // 401-retry path is WS /app/events/stream and /dictation/stream, so those
  // unknown_token handshakes are info. Everything else stays warn.
  it.each([
    {
      name: "logs the app-event stream unknown_token handshake at info",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "unknown_token",
      level: "info",
    },
    {
      name: "logs the dictation stream unknown_token handshake at info",
      transport: "ws" as const,
      path: "/dictation/stream",
      reason: "unknown_token",
      level: "info",
    },
    {
      name: "keeps unknown_token on a focused session stream at warn",
      transport: "ws" as const,
      path: "/workspaces/ws1/sessions/s1/stream",
      reason: "unknown_token",
      level: "warn",
    },
    {
      name: "keeps HTTP unknown_token at warn even on the retry path",
      transport: "http" as const,
      path: "/app/events/stream",
      reason: "unknown_token",
      level: "warn",
    },
    {
      name: "keeps revoked on the retry path at warn",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "revoked",
      level: "warn",
    },
    {
      name: "keeps evicted on the retry path at warn",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "evicted",
      level: "warn",
    },
    {
      name: "keeps missing auth at warn",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "missing",
      level: "warn",
    },
    {
      name: "keeps malformed auth at warn",
      transport: "ws" as const,
      path: "/dictation/stream",
      reason: "malformed",
      level: "warn",
    },
    {
      name: "keeps owner_on_network at warn",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "owner_on_network",
      level: "warn",
    },
    {
      name: "keeps expired tokens at warn",
      transport: "ws" as const,
      path: "/app/events/stream",
      reason: "expired",
      level: "warn",
    },
  ])("$name", ({ transport, path, reason, level }) => {
    expect(unauthorizedAuthLogLevel({ transport, path, reason })).toBe(level);
  });
});

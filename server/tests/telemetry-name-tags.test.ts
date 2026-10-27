import { describe, expect, it } from "vitest";

import { looksLikeLocation, sanitizeNameTag } from "../src/telemetry/validate.js";

describe("name tag sanitizing", () => {
  it.each([
    "claude-opus-4@20250514",
    "qwen3:32b",
    "llama3:8",
    "meta-llama/llama-3.1-8b-instruct:free",
    "gpt-4.1",
    "mcp__github__create_issue",
    "queueSync.initial",
    "streaming",
    "xai",
    "AVAudioSessionCategoryPlayAndRecord",
    "BluetoothHFP/MicrophoneBuiltIn",
  ])("keeps the identifier %s", (value) => {
    expect(sanitizeNameTag(value)).toBe(value);
  });

  it.each([
    "http://mac-studio.tail1234.ts.net:7936",
    "https://example.com",
    "mac-studio.tail1234.ts.net",
    "Mac-Studio.local",
    "stt.build-box.internal",
    "nas.lan",
    "192.168.68.66",
    "192.168.68.66:7936",
    "stt.example.com:7936",
    "localhost",
    "localhost:7936",
    "dev@box.example.com",
    "/Users/duh/models/parakeet",
    "~/models/parakeet",
    "has space",
    "",
  ])("stores %j as unknown", (value) => {
    expect(sanitizeNameTag(value)).toBe("unknown");
  });

  it("lets only a route template start with a slash", () => {
    expect(sanitizeNameTag("/workspaces/:workspaceId", true)).toBe("/workspaces/:workspaceId");
    expect(sanitizeNameTag("/workspaces/:workspaceId")).toBe("unknown");
    expect(looksLikeLocation("/workspaces/:workspaceId", true)).toBe(false);
    // A route allowance does not excuse a host.
    expect(sanitizeNameTag("http://evil.example/x", true)).toBe("unknown");
  });
});

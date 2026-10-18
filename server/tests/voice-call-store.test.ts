import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
} from "../src/continuous-voice-call.js";
import { FileVoiceCallStore, voiceCallStorePath } from "../src/voice-call-store.js";

describe("FileVoiceCallStore", () => {
  it("reloads persisted calls from disk into a new controller", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-store-"));
    try {
      const path = voiceCallStorePath(dir);
      const first = new VoiceCallController({
        now: () => 1_000,
        nextCallId: () => "call-disk",
        persistence: new FileVoiceCallStore(path),
      });
      const frontend = new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      });
      first.startCall(
        { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
        frontend.connection,
      );
      first.commitFrontendUtterance({
        callId: "call-disk",
        controllerLeaseEpoch: 1,
        frontendConnectionId: "connection-1",
        utteranceId: "utterance-1",
        delegationId: "delegation-1",
        request: "Keep this across restart",
      });

      const raw = JSON.parse(readFileSync(path, "utf8")) as { version: number; calls: unknown[] };
      expect(raw.version).toBe(1);
      expect(raw.calls).toHaveLength(1);

      const restarted = new VoiceCallController({
        now: () => 4_000,
        nextCallId: () => "call-should-not-mint",
        persistence: new FileVoiceCallStore(path),
      });
      const restored = restarted.snapshot("call-disk");
      expect(restored.frontend).toBe("detached");
      expect(restored.delegations).toEqual([
        expect.objectContaining({
          delegationId: "delegation-1",
          request: "Keep this across restart",
        }),
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("starts empty when the store file is missing and rejects a corrupt file", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-store-missing-"));
    try {
      const path = voiceCallStorePath(dir);
      const empty = new FileVoiceCallStore(path);
      expect(empty.load()).toEqual([]);

      writeFileSync(path, "{not-json", { mode: 0o600 });
      expect(() => new FileVoiceCallStore(path).load()).toThrow("Voice call store is unreadable");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

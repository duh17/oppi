import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { VoiceCallController } from "../src/continuous-voice-call.js";
import { FileVoiceCallStore, voiceCallStorePath } from "../src/voice-call-store.js";
import { DeterministicVoiceCallFrontend } from "./helpers/deterministic-voice-call-frontend.js";

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

  it.each([
    ["is not JSON", "{not-json"],
    [
      "holds a replay event this server does not know",
      JSON.stringify({
        version: 1,
        calls: [
          {
            callId: "call-future",
            controlSessionId: "voice-session-1",
            clientCallId: "client-call-1",
            ownerDeviceId: "paired-device-a",
            lifecycle: "active",
            controllerLeaseEpoch: 1,
            controllerLeaseExpiresAt: 4_000,
            eventSeq: 1,
            startedAt: 1_000,
            updatedAt: 2_000,
            delegations: [],
            events: [{ type: "voice_from_a_newer_server", callId: "call-future" }],
          },
        ],
      }),
    ],
  ])("boots empty and sets the file aside when voice-calls.json %s", (_name, contents) => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-store-corrupt-"));
    try {
      const path = voiceCallStorePath(dir);
      writeFileSync(path, contents, { mode: 0o600 });

      const controller = new VoiceCallController({
        now: () => 1_000,
        nextCallId: () => "call-fresh",
        persistence: new FileVoiceCallStore(path),
      });

      // The bad file is kept for inspection under a timestamped name, not deleted.
      const aside = readdirSync(dir).filter((name) => name.startsWith("voice-calls.json.corrupt-"));
      expect(aside).toHaveLength(1);
      expect(readFileSync(join(dir, aside[0] as string), "utf8")).toBe(contents);

      // The controller starts empty and persists normally afterwards.
      expect(() => controller.snapshot("call-future")).toThrow("Unknown voice call");
      const frontend = new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      });
      controller.startCall(
        { controlSessionId: "voice-session-1", clientCallId: "client-call-2" },
        frontend.connection,
      );
      const raw = JSON.parse(readFileSync(path, "utf8")) as { calls: Array<{ callId: string }> };
      expect(raw.calls.map((call) => call.callId)).toEqual(["call-fresh"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("loads a call file written before spoken approval was removed", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-store-legacy-"));
    try {
      const path = voiceCallStorePath(dir);
      // The shape an older server persisted: replay events include approval messages.
      writeFileSync(
        path,
        JSON.stringify({
          version: 1,
          calls: [
            {
              callId: "call-legacy",
              controlSessionId: "voice-session-1",
              clientCallId: "client-call-1",
              ownerDeviceId: "paired-device-a",
              lifecycle: "active",
              controllerLeaseEpoch: 2,
              controllerLeaseExpiresAt: 4_000,
              eventSeq: 3,
              startedAt: 1_000,
              updatedAt: 2_000,
              delegations: [
                {
                  delegationId: "delegation-1",
                  utteranceId: "utterance-1",
                  request: "Keep this across restart",
                  state: "acknowledged",
                  createdAt: 1_000,
                },
              ],
              events: [
                {
                  type: "voice_delegation_update",
                  callId: "call-legacy",
                  controlSessionId: "voice-session-1",
                  eventSeq: 1,
                  delegationId: "delegation-1",
                  utteranceId: "utterance-1",
                  kind: "acknowledgement",
                  text: "On it",
                  createdAt: 1_000,
                },
                {
                  type: "voice_approval_required",
                  callId: "call-legacy",
                  controlSessionId: "voice-session-1",
                  eventSeq: 2,
                  challengeId: "challenge-1",
                  requestId: "request-1",
                  summary: "Allow one test command?",
                  targetRefs: [],
                  expiresAt: 9_000,
                },
                {
                  type: "voice_approval_result",
                  callId: "call-legacy",
                  controlSessionId: "voice-session-1",
                  eventSeq: 3,
                  challengeId: "challenge-1",
                  outcome: "delivered",
                },
              ],
            },
          ],
        }),
        { mode: 0o600 },
      );

      const restarted = new VoiceCallController({
        now: () => 5_000,
        nextCallId: () => "call-should-not-mint",
        persistence: new FileVoiceCallStore(path),
      });
      const restored = restarted.snapshot("call-legacy");
      expect(restored.lifecycle).toBe("active");
      expect(restored.delegations).toEqual([
        expect.objectContaining({ delegationId: "delegation-1", state: "acknowledged" }),
      ]);
      const attached = restarted.attachCall(
        { callId: "call-legacy", lastEventSeq: 0 },
        new DeterministicVoiceCallFrontend({
          connectionId: "connection-1",
          authenticatedDeviceId: "paired-device-a",
        }).connection,
      );
      expect(attached.replay).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

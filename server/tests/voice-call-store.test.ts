import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  it.skipIf(process.getuid?.() === 0)(
    "fails the boot and leaves a valid store alone when the file cannot be read",
    () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-store-unreadable-"));
      const path = voiceCallStorePath(dir);
      try {
        const writer = new VoiceCallController({
          now: () => 1_000,
          nextCallId: () => "call-kept",
          persistence: new FileVoiceCallStore(path),
        });
        writer.startCall(
          { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
          new DeterministicVoiceCallFrontend({
            connectionId: "connection-1",
            authenticatedDeviceId: "paired-device-a",
          }).connection,
        );
        const before = readFileSync(path, "utf8");
        chmodSync(path, 0o000);

        // A permission error says nothing about the contents: no quarantine, no empty boot.
        expect(
          () =>
            new VoiceCallController({
              now: () => 2_000,
              nextCallId: () => "unused",
              persistence: new FileVoiceCallStore(path),
            }),
        ).toThrow(/EACCES/);

        chmodSync(path, 0o600);
        expect(readdirSync(dir)).toEqual(["voice-calls.json"]);
        expect(readFileSync(path, "utf8")).toBe(before);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );

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

  describe("what the file keeps about a call", () => {
    const HOUR_MS = 60 * 60_000;

    function withStoreDir(run: (path: string) => void): void {
      const dir = mkdtempSync(join(tmpdir(), "oppi-voice-call-retention-"));
      try {
        run(voiceCallStorePath(dir));
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }

    function storedCallIds(path: string): string[] {
      const raw = JSON.parse(readFileSync(path, "utf8")) as { calls: Array<{ callId: string }> };
      return raw.calls.map((call) => call.callId);
    }

    function startAndSay(
      controller: VoiceCallController,
      frontend: DeterministicVoiceCallFrontend,
      input: { sessionId: string; clientCallId: string; callId: string; request: string },
    ) {
      const started = controller.startCall(
        { controlSessionId: input.sessionId, clientCallId: input.clientCallId },
        frontend.connection,
      );
      controller.commitFrontendUtterance({
        callId: input.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontendConnectionId: frontend.connection.connectionId,
        utteranceId: `utterance-${input.callId}`,
        delegationId: `delegation-${input.callId}`,
        request: input.request,
      });
      return started.state;
    }

    it("removes a deleted session's calls from memory and disk and ends its active call", () => {
      withStoreDir((path) => {
        let callSequence = 0;
        const controller = new VoiceCallController({
          now: () => 1_000,
          nextCallId: () => `call-${++callSequence}`,
          persistence: new FileVoiceCallStore(path),
        });
        const deletedFront = new DeterministicVoiceCallFrontend({
          connectionId: "connection-deleted",
          authenticatedDeviceId: "paired-device-a",
        });
        const otherFront = new DeterministicVoiceCallFrontend({
          connectionId: "connection-other",
          authenticatedDeviceId: "paired-device-a",
        });
        // The deleted session has an ended call and a live one; both carry what was said.
        const first = startAndSay(controller, deletedFront, {
          sessionId: "deleted-session",
          clientCallId: "client-1",
          callId: "call-1",
          request: "SECRET first request",
        });
        controller.endCall(
          { callId: "call-1", controllerLeaseEpoch: first.controllerLeaseEpoch },
          deletedFront.connection,
        );
        startAndSay(controller, deletedFront, {
          sessionId: "deleted-session",
          clientCallId: "client-2",
          callId: "call-2",
          request: "SECRET second request",
        });
        startAndSay(controller, otherFront, {
          sessionId: "kept-session",
          clientCallId: "client-3",
          callId: "call-3",
          request: "kept request",
        });
        expect(storedCallIds(path)).toEqual(["call-1", "call-2", "call-3"]);

        const released = controller.removeSessionCalls("deleted-session");

        // Media to release is the live call's connection, and its frontend hears the call ended.
        expect(released).toEqual(["connection-deleted"]);
        expect(deletedFront.messages.at(-1)).toMatchObject({
          type: "voice_call_state",
          callId: "call-2",
          lifecycle: "ended",
        });
        expect(() => controller.snapshot("call-1")).toThrow("Unknown voice call");
        expect(() => controller.snapshot("call-2")).toThrow("Unknown voice call");
        expect(controller.activeCallIdForControlSession("deleted-session")).toBeUndefined();
        expect(controller.snapshot("call-3").lifecycle).toBe("active");
        expect(otherFront.messages.at(-1)).not.toMatchObject({ lifecycle: "ended" });

        expect(storedCallIds(path)).toEqual(["call-3"]);
        const onDisk = readFileSync(path, "utf8");
        expect(onDisk).not.toContain("SECRET");
        expect(onDisk).toContain("kept request");
      });
    });

    it("drops an ended call 24 hours after it ended, at load and at the next save", () => {
      withStoreDir((path) => {
        let now = 1_000;
        const callIds = ["call-old", "call-young", "call-3"];
        const controller = new VoiceCallController({
          now: () => now,
          nextCallId: () => callIds.shift() as string,
          persistence: new FileVoiceCallStore(path),
        });
        const front = new DeterministicVoiceCallFrontend({
          connectionId: "connection-1",
          authenticatedDeviceId: "paired-device-a",
        });
        const endAt = (callId: string, sessionId: string, clientCallId: string, at: number) => {
          now = at;
          const state = startAndSay(controller, front, {
            sessionId,
            clientCallId,
            callId,
            request: `request of ${callId}`,
          });
          controller.endCall(
            { callId, controllerLeaseEpoch: state.controllerLeaseEpoch },
            front.connection,
          );
        };
        endAt("call-old", "session-1", "client-old", 1_000);
        endAt("call-young", "session-2", "client-young", 10 * HOUR_MS);
        expect(storedCallIds(path)).toEqual(["call-old", "call-young"]);

        // Just short of 24 hours after the old call ended: a restart keeps both.
        const keepsBoth = new VoiceCallController({
          now: () => 1_000 + 24 * HOUR_MS - 1,
          nextCallId: () => "unused",
          persistence: new FileVoiceCallStore(path),
        });
        expect(keepsBoth.snapshot("call-old").lifecycle).toBe("ended");
        expect(storedCallIds(path)).toEqual(["call-old", "call-young"]);

        // At 24 hours the old call is gone from memory and from the file; the younger stays.
        const restarted = new VoiceCallController({
          now: () => 1_000 + 24 * HOUR_MS,
          nextCallId: () => "unused",
          persistence: new FileVoiceCallStore(path),
        });
        expect(() => restarted.snapshot("call-old")).toThrow("Unknown voice call");
        expect(restarted.snapshot("call-young").lifecycle).toBe("ended");
        expect(storedCallIds(path)).toEqual(["call-young"]);
        expect(readFileSync(path, "utf8")).not.toContain("request of call-old");

        // A running server prunes on its next save too: the younger call ages out.
        now = 10 * HOUR_MS + 24 * HOUR_MS;
        startAndSay(controller, front, {
          sessionId: "session-3",
          clientCallId: "client-new",
          callId: "call-3",
          request: "fresh request",
        });
        expect(storedCallIds(path)).toEqual(["call-3"]);
      });
    });

    it("still writes the file when every stored call has aged out at load", () => {
      withStoreDir((path) => {
        let callSequence = 0;
        const controller = new VoiceCallController({
          now: () => 1_000,
          nextCallId: () => `call-${++callSequence}`,
          persistence: new FileVoiceCallStore(path),
        });
        const front = new DeterministicVoiceCallFrontend({
          connectionId: "connection-1",
          authenticatedDeviceId: "paired-device-a",
        });
        const state = startAndSay(controller, front, {
          sessionId: "session-1",
          clientCallId: "client-1",
          callId: "call-1",
          request: "SECRET only request",
        });
        controller.endCall(
          { callId: "call-1", controllerLeaseEpoch: state.controllerLeaseEpoch },
          front.connection,
        );

        new VoiceCallController({
          now: () => 1_000 + 25 * HOUR_MS,
          nextCallId: () => "unused",
          persistence: new FileVoiceCallStore(path),
        });

        expect(readFileSync(path, "utf8")).not.toContain("SECRET");
        expect(storedCallIds(path)).toEqual([]);
      });
    });
  });
});

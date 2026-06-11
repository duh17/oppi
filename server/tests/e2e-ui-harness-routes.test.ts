import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createE2EUIHarnessRoutes } from "../src/routes/e2e-ui-harness.js";
import { getSessionAttachment } from "../src/session-attachments.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const originalHarnessFlag = process.env.OPPI_E2E_UI_HARNESS;

describe("E2E UI harness routes", () => {
  afterEach(() => {
    if (originalHarnessFlag === undefined) {
      delete process.env.OPPI_E2E_UI_HARNESS;
    } else {
      process.env.OPPI_E2E_UI_HARNESS = originalHarnessFlag;
    }
  });

  it("writes workspace file fixtures under the server data dir", async () => {
    process.env.OPPI_E2E_UI_HARNESS = "1";
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-e2e-fixture-route-"));
    try {
      const dispatch = createE2EUIHarnessRoutes(makeContext(dataDir), createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/e2e/ui/fixtures/workspace-file",
        url: new URL("http://localhost/e2e/ui/fixtures/workspace-file"),
        req: makeRequest({
          directoryName: "video-fixture",
          filename: "clip.mp4",
          base64: Buffer.from("fixture bytes").toString("base64"),
        }),
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { hostMount: string; filePath: string; filename: string };
      expect(body.hostMount).toBe(join(dataDir, "e2e-fixtures", "video-fixture"));
      expect(body.filePath).toBe(join(body.hostMount, "clip.mp4"));
      expect(body.filename).toBe("clip.mp4");
      expect(readFileSync(body.filePath, "utf8")).toBe("fixture bytes");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects fixture path traversal", async () => {
    process.env.OPPI_E2E_UI_HARNESS = "1";
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-e2e-fixture-route-"));
    try {
      const dispatch = createE2EUIHarnessRoutes(makeContext(dataDir), createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: "/e2e/ui/fixtures/workspace-file",
        url: new URL("http://localhost/e2e/ui/fixtures/workspace-file"),
        req: makeRequest({
          directoryName: "..",
          filename: "clip.mp4",
          base64: Buffer.from("fixture bytes").toString("base64"),
        }),
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(existsSync(join(dataDir, "clip.mp4"))).toBe(false);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("materializes tool media before broadcasting synthetic session messages", async () => {
    process.env.OPPI_E2E_UI_HARNESS = "1";
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-e2e-media-route-"));
    const sessionId = "session-media-harness";
    const broadcasted: unknown[] = [];
    try {
      const dispatch = createE2EUIHarnessRoutes(
        makeContext(dataDir, sessionId, broadcasted),
        createRouteHelpers(),
      );
      const res = makeResponse();
      const audioBytes = Buffer.from("RIFF audio fixture");

      const handled = await dispatch({
        method: "POST",
        path: `/e2e/ui/sessions/${sessionId}/message`,
        url: new URL(`http://localhost/e2e/ui/sessions/${sessionId}/message`),
        req: makeRequest({
          type: "tool_end",
          tool: "voice_speak",
          toolCallId: "tool-audio-e2e",
          details: {
            kind: "audio_presentation",
            text: "audio reached the client",
            audio: {
              kind: "audio",
              mimeType: "audio/wav",
              fileName: "voice.wav",
              base64: audioBytes.toString("base64"),
              durationSeconds: 1,
            },
          },
        }),
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        message: { details: { audio: { id: string; base64?: string; storageKey?: string } } };
      };
      const audio = body.message.details.audio;
      expect(audio.id).toMatch(/^att_/);
      expect(audio.base64).toBeUndefined();
      expect(audio.storageKey).toBe(`${sessionId}/${audio.id}.wav`);
      expect(broadcasted).toHaveLength(1);
      expect(broadcasted[0]).toEqual(body.message);

      const attachment = await getSessionAttachment(dataDir, sessionId, audio.id);
      expect(attachment ? readFileSync(attachment.path) : null).toEqual(audioBytes);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

function makeContext(dataDir: string, sessionId = "session-1", broadcasted: unknown[] = []): RouteContext {
  return {
    storage: {
      getDataDir: () => dataDir,
    },
    sessionRuntimes: {
      getSessionSnapshot: (id: string) => (id === sessionId ? { id } : undefined),
    },
    sessions: {
      isActive: (id: string) => id === sessionId,
      broadcastSessionMessage: (_id: string, message: unknown) => {
        broadcasted.push(message);
        return 1;
      },
    },
  } as unknown as RouteContext;
}

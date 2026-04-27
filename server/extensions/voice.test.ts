import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { Storage } from "../src/storage.js";
import {
  normalizeVoiceDelivery,
  readVoicePreferences,
  resolveConfiguredDefaultVoiceId,
  saveVoicePreferences,
} from "./voice.js";

describe("voice preferences", () => {
  let tempDir: string | undefined;

  afterEach(() => {
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  it("persists and reloads the saved default voice", () => {
    tempDir = mkdtempSync(path.join(os.tmpdir(), "voice-prefs-"));
    const storage = new Storage(tempDir);

    expect(readVoicePreferences(storage)).toEqual({});

    const saved = saveVoicePreferences(storage, { defaultVoiceId: "warm-technical-teammate" });
    expect(saved.defaultVoiceId).toBe("warm-technical-teammate");
    expect(saved.updatedAt).toBeTypeOf("string");

    expect(readVoicePreferences(storage).defaultVoiceId).toBe("warm-technical-teammate");
    expect(resolveConfiguredDefaultVoiceId(storage)).toBe("warm-technical-teammate");
  });

  it("normalizes supported delivery values", () => {
    expect(normalizeVoiceDelivery("voiceMessage")).toBe("voiceMessage");
    expect(normalizeVoiceDelivery("directSpeak")).toBe("directSpeak");
    expect(normalizeVoiceDelivery("somethingElse")).toBeUndefined();
  });
});

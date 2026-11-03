import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { MEDIA_INFO_SNAPSHOT_FILE, serializeMediaInfoFixture } from "./media-info-fixtures.js";

interface Fixture {
  _meta: { exampleCount: number };
  examples: { name: string; body: Record<string, unknown> }[];
}

function committed(): Fixture {
  return JSON.parse(readFileSync(MEDIA_INFO_SNAPSHOT_FILE, "utf8")) as Fixture;
}

const TOP_LEVEL_KEYS = new Set(["durationSeconds", "format", "tags"]);
const FORMAT_KEYS = new Set(["codec", "sampleRate", "channels", "bitrate"]);
const TAG_KEYS = new Set(["title", "artist", "album"]);

describe("media-info protocol fixture", () => {
  it("matches the committed protocol/media-info.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializeMediaInfoFixture()).toBe(readFileSync(MEDIA_INFO_SNAPSHOT_FILE, "utf8"));
  });

  it("holds only keys the protocol defines", () => {
    const fixture = committed();
    expect(fixture._meta.exampleCount).toBe(fixture.examples.length);
    for (const { name, body } of fixture.examples) {
      for (const key of Object.keys(body)) {
        expect(TOP_LEVEL_KEYS.has(key), `${name}: ${key}`).toBe(true);
      }
      const format = body.format as Record<string, unknown> | undefined;
      const tags = body.tags as Record<string, unknown> | undefined;
      for (const key of Object.keys(format ?? {})) {
        expect(FORMAT_KEYS.has(key), `${name}: format.${key}`).toBe(true);
      }
      for (const key of Object.keys(tags ?? {})) {
        expect(TAG_KEYS.has(key), `${name}: tags.${key}`).toBe(true);
      }
    }
  });

  it("covers a full answer, a partial one, and an unknown file", () => {
    const bodies = committed().examples.map(({ body }) => body);
    expect(bodies).toContainEqual({
      durationSeconds: 2712.4,
      format: { codec: "aac", sampleRate: 44_100, channels: 2, bitrate: 128_000 },
      tags: { title: "Episode 12", artist: "Alex Rivera", album: "Field Notes" },
    });
    expect(bodies).toContainEqual({ durationSeconds: 12.25 });
    expect(bodies).toContainEqual({});
  });
});

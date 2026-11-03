import resolvePath from "node:path";

import type { MediaInfo } from "../src/types/workspace-files.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/media-info.json`: the shapes `GET /files/current/media-info`
 * answers, so both sides agree on the wire before anyone reads a tag.
 *
 * Only this serializer defines the bytes. The server test rebuilds it in memory
 * and compares against the committed file; `npm run protocol:fixtures:update`
 * is what writes it. Apple `MediaInfoContractTests` decodes every example.
 */

export const MEDIA_INFO_SNAPSHOT_FILE = resolvePath.join(PROTOCOL_DIR, "media-info.json");

export const MEDIA_INFO_FIXTURE_DESCRIPTION =
  "Every shape GET /files/current/media-info answers: all fields, a length with a format, a length alone, and an unknown file. Every field is optional and absent means unknown, so a client ignores keys it does not read and treats a missing key as unknown. Built by server/tests/media-info-fixtures.ts; server/tests/media-info-fixtures.test.ts fails when the committed bytes differ, and Apple MediaInfoContractTests decodes these examples.";

export interface MediaInfoExample {
  name: string;
  body: MediaInfo;
}

/** Full, partial, and empty answers, in the order the route builds its keys. */
export function buildMediaInfoExamples(): MediaInfoExample[] {
  return [
    {
      name: "every field",
      body: {
        durationSeconds: 2712.4,
        format: { codec: "aac", sampleRate: 44_100, channels: 2, bitrate: 128_000 },
        tags: { title: "Episode 12", artist: "Alex Rivera", album: "Field Notes" },
      },
    },
    {
      name: "length and format without tags",
      body: {
        durationSeconds: 184.5,
        format: { codec: "flac", sampleRate: 48_000, channels: 2, bitrate: 921_600 },
      },
    },
    {
      name: "length only, as a header states no format",
      body: { durationSeconds: 12.25 },
    },
    {
      name: "unknown, as an unparsed or malformed file answers",
      body: {},
    },
  ];
}

export function serializeMediaInfoFixture(): string {
  const examples = buildMediaInfoExamples();
  return (
    JSON.stringify(
      {
        _meta: {
          description: MEDIA_INFO_FIXTURE_DESCRIPTION,
          source: "server/src/types/workspace-files.ts",
          exampleCount: examples.length,
        },
        examples,
      },
      null,
      2,
    ) + "\n"
  );
}

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { MCP_HTTP_SNAPSHOT_FILE, serializeMcpHttpFixture } from "../tests/mcp-protocol-fixtures.js";
import {
  CONVERSATION_STREAM_SNAPSHOT_FILE,
  serializeConversationStreamFixture,
} from "../tests/conversation-stream-fixtures.js";
import {
  buildConversationStreamGolden,
  CONVERSATION_STREAM_GOLDEN_FILE,
} from "../tests/conversation-stream-golden.js";
import { ROUTES_SNAPSHOT_PATH, serializeRouteFixture } from "../tests/route-fixtures.js";
import {
  MEDIA_INFO_SNAPSHOT_FILE,
  serializeMediaInfoFixture,
} from "../tests/media-info-fixtures.js";
import {
  buildSurfaceFixtures,
  serializeSurfaceFixture,
  SURFACE_FIXTURES_DIR,
} from "../tests/surface-fixtures.js";
import {
  APP_EVENT_MESSAGES_FIXTURE_DESCRIPTION,
  APP_EVENT_MESSAGES_SNAPSHOT_FILE,
  buildCanonicalAppEventMessages,
  buildCanonicalServerMessages,
  SERVER_MESSAGES_FIXTURE_DESCRIPTION,
  SERVER_MESSAGES_SNAPSHOT_FILE,
  serializeProtocolFixture,
} from "../tests/protocol-fixtures.js";

const fixtures = [
  { path: MCP_HTTP_SNAPSHOT_FILE, content: serializeMcpHttpFixture() },
  { path: CONVERSATION_STREAM_SNAPSHOT_FILE, content: serializeConversationStreamFixture() },
  // Runs a real Harness conversation; only this script writes it, never ordinary tests.
  { path: CONVERSATION_STREAM_GOLDEN_FILE, content: await buildConversationStreamGolden() },
  {
    path: SERVER_MESSAGES_SNAPSHOT_FILE,
    content: serializeProtocolFixture(
      SERVER_MESSAGES_FIXTURE_DESCRIPTION,
      buildCanonicalServerMessages(),
    ),
  },
  {
    path: APP_EVENT_MESSAGES_SNAPSHOT_FILE,
    content: serializeProtocolFixture(
      APP_EVENT_MESSAGES_FIXTURE_DESCRIPTION,
      buildCanonicalAppEventMessages(),
    ),
  },
  // Every route the server answers, for the client's route contract test.
  { path: ROUTES_SNAPSHOT_PATH, content: serializeRouteFixture() },
  // The media-info body shape the client decodes.
  { path: MEDIA_INFO_SNAPSHOT_FILE, content: serializeMediaInfoFixture() },
  // One surface per composite, plus the action, patch, and unknown-composite messages, decoded
  // by the server's tests and the Apple Codable tests from these same bytes.
  ...Object.entries(buildSurfaceFixtures()).map(([name, value]) => ({
    path: resolve(SURFACE_FIXTURES_DIR, name),
    content: serializeSurfaceFixture(value),
  })),
];

for (const fixture of fixtures) {
  mkdirSync(dirname(fixture.path), { recursive: true });
  writeFileSync(fixture.path, fixture.content);
  console.log(`Updated ${fixture.path}`);
}

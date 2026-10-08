import { writeFileSync } from "node:fs";
import { MCP_HTTP_SNAPSHOT_FILE, serializeMcpHttpFixture } from "../tests/mcp-protocol-fixtures.js";
import {
  CONVERSATION_STREAM_SNAPSHOT_FILE,
  serializeConversationStreamFixture,
} from "../tests/conversation-stream-fixtures.js";

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
];

for (const fixture of fixtures) {
  writeFileSync(fixture.path, fixture.content);
  console.log(`Updated ${fixture.path}`);
}

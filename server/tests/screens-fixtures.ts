import { join } from "node:path";
import { diffRevisions } from "@earendil-works/chord/delta";
import type { JsonValue } from "@earendil-works/chord/json";
import {
  addPage,
  listPage,
  MCP_SIDEBAR_ENTRY,
  serverPage,
  signInPage,
} from "../plugins/mcp-screen/pages.js";
import { SCREENS_VERSION } from "../src/plugin-screens.js";
import { SERVER_FEATURE_PRESETS } from "../src/server-features.js";
import type {
  ConversationDocOp,
  ScreenPage,
  ScreensClientMessage,
  ScreensServerMessage,
} from "../src/types.js";
import { buildMcpHttpFixture } from "./mcp-protocol-fixtures.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/screens.json`: the plugin screen vocabulary and `WS /screens/stream`, drawn from the
 * MCP Servers plugin's real pages over the `mcp-http.json` catalogs. Every row kind appears.
 *
 * Only this serializer defines the bytes. `screens-fixtures.test.ts` rebuilds it in memory and
 * compares against the committed file; `npm run protocol:fixtures:update` writes it. Apple
 * `PluginScreenProtocolTests` decodes every page and message and applies `server`'s frames in order.
 */
export const SCREENS_SNAPSHOT_FILE = join(PROTOCOL_DIR, "screens.json");

export function buildScreensFixture() {
  const mcp = buildMcpHttpFixture();
  const probe = { response: mcp.catalogs[0]! };
  const page = (value: ScreenPage | { gone: true }): ScreenPage => value as ScreenPage;
  const pages = {
    loading: listPage({}),
    failed: listPage({ error: "MCP management is busy. Retry refresh when it finishes." }),
    list: listPage(probe),
    listDuringSignIn: listPage({ response: mcp.signInCatalog }),
    http: page(serverPage(probe, "remote")),
    stdio: page(serverPage(probe, "echo")),
    add: addPage(),
    signIn: signInPage(mcp.flows[1]),
    signInDone: signInPage(mcp.flows[2]),
  };
  const ops = (from: ScreenPage, to: ScreenPage): ConversationDocOp[] =>
    diffRevisions(from as unknown as JsonValue, to as unknown as JsonValue) as ConversationDocOp[];
  const client: ScreensClientMessage[] = [
    {
      type: "watch",
      watch: "w1",
      entry: MCP_SIDEBAR_ENTRY.id,
      scope: "server",
      page: "list",
      v: 1,
    },
    {
      type: "act",
      watch: "w2",
      call: "c1",
      action: "enabled",
      row: "enabled",
      values: [{ field: "enabled", value: false }],
    },
    {
      type: "act",
      watch: "w3",
      call: "c2",
      action: "add",
      values: [
        { field: "name", value: "docs" },
        { field: "transport", value: "http" },
        { field: "url", value: "https://example.test/mcp" },
      ],
    },
    { type: "unwatch", watch: "w1" },
  ];
  // One watch's life: loading, the list, a sign-in starting, then the stream's other answers.
  const server: ScreensServerMessage[] = [
    { type: "value", watch: "w1", value: pages.loading },
    { type: "ops", watch: "w1", ops: ops(pages.loading, pages.list) },
    { type: "ops", watch: "w1", ops: ops(pages.list, pages.listDuringSignIn) },
    {
      type: "failed",
      watch: "w1",
      message: 'The page was refused: row kind "chart" is not one of the seven',
    },
    { type: "result", call: "c1", ok: true },
    { type: "result", call: "c2", ok: false, message: "Enter the server's URL." },
    { type: "result", call: "c3", ok: true, nav: { kind: "pop" } },
    { type: "result", call: "c4", ok: true, nav: { kind: "present", page: "signin" } },
    { type: "ended", watch: "w2", reason: "gone" },
    { type: "ended", watch: "w3", reason: "off" },
    { type: "ended", watch: "w4", reason: "unsupported" },
  ];
  return {
    serverInfo: {
      capabilities: { screens: { v: SCREENS_VERSION } },
      features: SERVER_FEATURE_PRESETS.all,
      sidebar: [MCP_SIDEBAR_ENTRY],
    },
    pages,
    client,
    server,
  };
}

export function serializeScreensFixture(): string {
  return JSON.stringify(buildScreensFixture(), null, 2) + "\n";
}

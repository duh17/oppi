import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { GodotService } from "../src/godot/godot-service.js";
import {
  GODOT_CAPTURE_MAX_BYTES,
  GODOT_PANE_CLIENT_CAPABILITY,
} from "../src/godot/godot-protocol.js";
import { createGodotRoutes } from "../src/routes/godot.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import type { GodotLinkServerMessage } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const PROJECT = "ci-runner";

let games: GodotService;
let server: Server;
let base: string;

beforeEach(async () => {
  const dataDir = makeTempDir("oppi-godot-routes-");
  games = new GodotService({
    listWorkspaces: () => [],
    getWorkspace: () => undefined,
    getSession: () => undefined,
    getDataDir: () => dataDir,
  });
  const dispatch = createGodotRoutes(
    { godot: games } as unknown as RouteContext,
    createRouteHelpers(),
  );
  server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    void dispatch({ method: req.method ?? "GET", path: url.pathname, url, req, res }).then(
      (handled) => {
        if (!handled) res.writeHead(404).end();
      },
    );
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterEach(async () => {
  games.close();
  await new Promise((resolve) => server.close(resolve));
});

const sha = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex");

async function upload(bytes: Buffer, name = sha(bytes)) {
  return fetch(`${base}/godot/${PROJECT}/packs/${name}`, { method: "PUT", body: bytes });
}

async function publish(packs: string[], query = "") {
  return fetch(`${base}/godot/${PROJECT}/releases${query}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      v: 1,
      engine: { name: "godot", version: "4.7" },
      packs: packs.map((sha256) => ({ sha256 })),
      reload: "scripts",
      label: "fix jump",
      name: "CI build",
    }),
  });
}

describe("game routes", () => {
  it("publishes uploaded packs and serves them by hash with ETag and one range", async () => {
    const base1 = Buffer.concat([Buffer.from("GDPC"), Buffer.alloc(1_000, 7)]);
    const patch = Buffer.from("PK\x03\x04patch-bytes", "latin1");

    expect((await upload(base1)).status).toBe(201);
    const again = await upload(base1);
    expect(again.status).toBe(200);
    expect(await again.json()).toMatchObject({
      existed: true,
      pack: { size: 1_004, format: "pck" },
    });
    expect((await upload(patch)).status).toBe(201);
    // Bytes that do not hash to their name, and bytes that are not a pack, are refused.
    expect((await upload(patch, sha(base1).replace(/^./, "0"))).status).toBe(400);
    expect((await upload(Buffer.from("hello"))).status).toBe(400);

    // A release may name only uploaded packs.
    expect((await publish([sha(base1), "f".repeat(64)])).status).toBe(409);
    const published = await publish([sha(base1), sha(patch)]);
    expect(published.status).toBe(201);
    const { release } = await published.json();
    expect(release).toMatchObject({
      seq: 1,
      origin: "publish",
      reload: "scripts",
      label: "fix jump",
      packs: [{ format: "pck" }, { format: "zip" }],
    });

    const list = await (await fetch(`${base}/godot`)).json();
    expect(list.projects).toMatchObject([{ id: PROJECT, name: "CI build", release: { seq: 1 } }]);

    const url = `${base}/godot/${PROJECT}/packs/${sha(base1)}`;
    const whole = await fetch(url);
    expect(whole.status).toBe(200);
    expect(whole.headers.get("etag")).toBe(`"${sha(base1)}"`);
    expect(Buffer.from(await whole.arrayBuffer()).equals(base1)).toBe(true);

    const cached = await fetch(url, { headers: { "if-none-match": `"${sha(base1)}"` } });
    expect(cached.status).toBe(304);

    const part = await fetch(url, { headers: { range: "bytes=1000-" } });
    expect(part.status).toBe(206);
    expect(part.headers.get("content-range")).toBe("bytes 1000-1003/1004");
    expect(Buffer.from(await part.arrayBuffer()).equals(base1.subarray(1000))).toBe(true);

    // A resume against other bytes gets the whole pack, not a wrong slice.
    const stale = await fetch(url, { headers: { range: "bytes=10-", "if-range": '"other"' } });
    expect(stale.status).toBe(200);
    await stale.arrayBuffer();

    expect((await fetch(url, { headers: { range: "bytes=5000-" } })).status).toBe(416);
    const head = await fetch(url, { method: "HEAD" });
    expect(head.headers.get("content-length")).toBe("1004");
    expect((await fetch(`${base}/godot/${PROJECT}/packs/${"a".repeat(64)}`)).status).toBe(404);
  });

  it("runs a command through an attached player and serves the capture it uploads", async () => {
    const bytes = Buffer.concat([Buffer.from("GDPC"), Buffer.from("x")]);
    await upload(bytes);
    await publish([sha(bytes)]);

    // No player yet.
    const none = await fetch(`${base}/godot/${PROJECT}/commands`, {
      method: "POST",
      body: JSON.stringify({ command: { name: "capture" } }),
    });
    expect(await none.json()).toMatchObject({ ok: false, error: { code: "no_player" } });

    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(64)]);
    const handle = games.link(PROJECT, "player", {
      send: (message: GodotLinkServerMessage) => {
        if (message.type !== "command" || message.command.name !== "capture") return;
        const { captureId } = message.command;
        void fetch(`${base}/godot/${PROJECT}/captures/${captureId}`, {
          method: "PUT",
          body: png,
        }).then(() =>
          handle?.receive({
            type: "result",
            id: message.id,
            ok: true,
            output: { captureId, mimeType: "image/png", width: 8, height: 8 },
          }),
        );
      },
      close: () => {},
    });
    handle?.receive({ type: "attach", capabilities: [GODOT_PANE_CLIENT_CAPABILITY], runtimes: [] });

    const result = await (
      await fetch(`${base}/godot/${PROJECT}/commands`, {
        method: "POST",
        body: JSON.stringify({ command: { name: "capture" } }),
      })
    ).json();
    expect(result).toMatchObject({ ok: true, name: "capture", output: { width: 8 } });
    const image = await fetch(`${base}/godot/${PROJECT}/captures/${result.output.captureId}`);
    expect(image.headers.get("content-type")).toBe("image/png");
    expect(Buffer.from(await image.arrayBuffer()).equals(png)).toBe(true);

    const malformed = await fetch(`${base}/godot/${PROJECT}/commands`, {
      method: "POST",
      body: JSON.stringify({
        command: { name: "input", steps: [{ kind: "tap", at: { x: 2, y: 0 } }] },
      }),
    });
    expect(await malformed.json()).toMatchObject({ ok: false, error: { code: "invalid" } });

    // Steps that would outlast the longest wait for an answer are refused up front.
    const tooLong = await fetch(`${base}/godot/${PROJECT}/commands`, {
      method: "POST",
      body: JSON.stringify({
        command: {
          name: "input",
          steps: [
            { kind: "wait", ms: 60_000 },
            { kind: "wait", ms: 60_000 },
          ],
        },
      }),
    });
    expect(await tooLong.json()).toMatchObject({
      ok: false,
      error: { code: "invalid", message: "The steps take 120 s; at most 110 s" },
    });
  });

  it("refuses a capture over 20 MB or that is not an image", async () => {
    await upload(Buffer.from("GDPC"));
    await publish([sha(Buffer.from("GDPC"))]);
    const url = `${base}/godot/${PROJECT}/captures/cap-big`;
    const big = Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      Buffer.alloc(GODOT_CAPTURE_MAX_BYTES),
    ]);
    expect((await fetch(url, { method: "PUT", body: big })).status).toBe(413);
    expect((await fetch(url, { method: "PUT", body: Buffer.from("GIF89a") })).status).toBe(415);
    expect((await fetch(url)).status).toBe(404);
  });

  it("answers logs and detail for known games only", async () => {
    expect((await fetch(`${base}/godot/nope`)).status).toBe(404);
    expect((await fetch(`${base}/godot/nope/logs`)).status).toBe(404);
    await upload(Buffer.from("GDPC"));
    await publish([sha(Buffer.from("GDPC"))]);
    const detail = await (await fetch(`${base}/godot/${PROJECT}`)).json();
    expect(detail).toMatchObject({ id: PROJECT, releases: [{ seq: 1 }], players: [] });
    const logs = await (await fetch(`${base}/godot/${PROJECT}/logs?since=0`)).json();
    expect(logs.entries.at(-1)).toMatchObject({
      origin: "server",
      message: "Release 1: published (fix jump)",
    });
    expect(logs.next).toBe(detail.logNext);
  });
});

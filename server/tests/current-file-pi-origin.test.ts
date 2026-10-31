import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRawRequest, MockWritableResponse } from "./harness/route-test-helpers.js";

/** Pi's own agent files are the one home area the editor may write. */
interface Fixture {
  root: string;
  agentDir: string;
  dataDir: string;
}

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function seed(): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "oppi-pi-origin-")));
  roots.push(root);
  const agentDir = join(root, "home", ".pi", "agent");
  const dataDir = join(root, "data");
  mkdirSync(agentDir, { recursive: true });
  mkdirSync(dataDir, { recursive: true });
  writeFileSync(join(agentDir, "SYSTEM.md"), "# Pi system prompt\n");
  writeFileSync(join(agentDir, "settings.json"), '{"defaultTools":[]}\n');
  // A file beside the agent directory, so a symlink out of it has a target.
  writeFileSync(join(agentDir, "..", "settings.md"), "beside the agent dir\n");
  return { root, agentDir, dataDir };
}

async function call(
  fixture: Fixture,
  method: "GET" | "PUT",
  path: string,
  body?: Buffer,
  headers: Record<string, string> = {},
  query: Record<string, string> = {},
): Promise<MockWritableResponse> {
  const dispatch = createHostFileRoutes(
    {
      storage: { getDataDir: () => fixture.dataDir },
    } as unknown as RouteContext,
    createRouteHelpers(),
    { piAgentDir: fixture.agentDir },
  );
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const params = new URLSearchParams({ origin: "pi", path, ...query });
  const url = new URL(`https://localhost/files/current?${params}`);
  const req = body ? makeRawRequest(body) : ({} as IncomingMessage);
  req.headers = body ? { "content-length": String(body.length), ...headers } : headers;
  const handled = await dispatch({
    method,
    path: url.pathname,
    url,
    req,
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

function tag(bytes: Buffer | string): string {
  return `"sha256-${createHash("sha256").update(bytes).digest("hex")}"`;
}

describe("/files/current?origin=pi", () => {
  it("reads and writes SYSTEM.md with the editor's tag contract", async () => {
    const fixture = seed();
    const systemPrompt = join(fixture.agentDir, "SYSTEM.md");

    const read = await call(fixture, "GET", "SYSTEM.md");
    expect(read.statusCode).toBe(200);
    const original = readFileSync(systemPrompt);
    expect(read.body.equals(original)).toBe(true);
    expect(read.headers.ETag).toBeDefined();

    const missingTag = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("x"));
    expect(missingTag.statusCode).toBe(428);

    const edited = Buffer.from("# Pi system prompt, edited\n");
    const saved = await call(fixture, "PUT", "SYSTEM.md", edited, {
      "if-match": read.headers.ETag,
    });
    expect(saved.statusCode).toBe(200);
    const savedEtag = (JSON.parse(saved.body.toString("utf8")) as { etag: string }).etag;
    expect(JSON.parse(saved.body.toString("utf8"))).toMatchObject({ size: edited.length });
    expect(readFileSync(systemPrompt).equals(edited)).toBe(true);
    // The save's tag is the next read's tag: the editor never needs the scheme.
    expect((await call(fixture, "GET", "SYSTEM.md")).headers.ETag).toBe(savedEtag);

    // The tag the read answered with no longer matches: a stale write is 412
    // and leaves the file alone, exactly like a workspace file.
    const stale = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("lost\n"), {
      "if-match": read.headers.ETag,
    });
    expect(stale.statusCode).toBe(412);
    expect(readFileSync(systemPrompt).equals(edited)).toBe(true);
  });

  it("never creates a file, and refuses a path the allowlist does not name", async () => {
    const fixture = seed();
    mkdirSync(join(fixture.agentDir, "prompts"));
    const anyTag = `"sha256-${"a".repeat(64)}"`;

    for (const path of ["prompts/new.md", "prompts/.git/config.md", "prompts/sub/new.md"]) {
      const res = await call(fixture, "PUT", path, Buffer.from("created\n"), { "if-match": anyTag });
      expect(res.statusCode).toBe(404);
      expect(existsSync(join(fixture.agentDir, path))).toBe(false);
    }
    // The allowlist names Markdown prompt templates, not every file under prompts/.
    writeFileSync(join(fixture.agentDir, "prompts", "notes.json"), "{}\n");
    expect((await call(fixture, "GET", "prompts/notes.json")).statusCode).toBe(404);
  });

  it("refuses an allowlisted path that a symlink leads to another agent file", async () => {
    const fixture = seed();
    const auth = join(fixture.agentDir, "auth.json");
    const secret = '{"k":"secret"}\n';
    writeFileSync(auth, secret);
    mkdirSync(join(fixture.agentDir, "prompts"));
    // `prompts/up -> ..`, so `prompts/up/auth.json` is the agent dir's own auth.json.
    symlinkSync("..", join(fixture.agentDir, "prompts", "up"));

    const read = await call(fixture, "GET", "prompts/up/auth.json");
    expect(read.headers.ETag).toBeUndefined();
    const write = await call(fixture, "PUT", "prompts/up/auth.json", Buffer.from("{}\n"), {
      "if-match": tag(secret),
    });
    expect(write.statusCode).toBe(404);
    expect(readFileSync(auth, "utf8")).toBe(secret);
  });

  it("refuses a prompts directory that is a symlink to the agent directory", async () => {
    const fixture = seed();
    // `prompts -> .` makes every sibling agent file look allowlisted.
    symlinkSync(".", join(fixture.agentDir, "prompts"));

    const read = await call(fixture, "GET", "prompts/settings.json");
    expect(read.headers.ETag).toBeUndefined();
    const write = await call(fixture, "PUT", "prompts/settings.json", Buffer.from("{}\n"), {
      "if-match": tag('{"defaultTools":[]}\n'),
    });
    expect(write.statusCode).toBe(404);
    expect(readFileSync(join(fixture.agentDir, "settings.json"), "utf8")).toBe(
      '{"defaultTools":[]}\n',
    );
  });

  it("edits Pi's prompt templates under prompts/", async () => {
    const fixture = seed();
    mkdirSync(join(fixture.agentDir, "prompts"));
    writeFileSync(join(fixture.agentDir, "prompts", "review.md"), "review the diff\n");

    const read = await call(fixture, "GET", "prompts/review.md");
    expect(read.statusCode).toBe(200);
    expect(read.headers.ETag).toBeDefined();

    const saved = await call(
      fixture,
      "PUT",
      "prompts/review.md",
      Buffer.from("review it twice\n"),
      {
        "if-match": read.headers.ETag,
      },
    );
    expect(saved.statusCode).toBe(200);
    expect(readFileSync(join(fixture.agentDir, "prompts", "review.md"), "utf8")).toBe(
      "review it twice\n",
    );
  });

  it("refuses every file outside Pi's agent files, read and write alike", async () => {
    const fixture = seed();
    const anyTag = tag("anything\n");
    for (const path of ["settings.json", "SYSTEM.md.bak", "prompts", "../settings.md"]) {
      expect((await call(fixture, "GET", path)).statusCode).toBe(404);
      const write = await call(fixture, "PUT", path, Buffer.from("owned\n"), {
        "if-match": anyTag,
      });
      expect(write.statusCode).toBe(404);
    }
    expect(readFileSync(join(fixture.agentDir, "settings.json"), "utf8")).toBe(
      '{"defaultTools":[]}\n',
    );
    expect(readFileSync(join(fixture.agentDir, "..", "settings.md"), "utf8")).toBe(
      "beside the agent dir\n",
    );
  });

  it("refuses traversal and symlink escapes out of the agent directory", async () => {
    const fixture = seed();
    const outside = join(fixture.root, "outside.md");
    writeFileSync(outside, "outside\n");
    const anyTag = tag("outside\n");

    for (const path of ["prompts/../../outside.md", "/etc/hosts", "~/outside.md"]) {
      expect((await call(fixture, "GET", path)).statusCode).toBe(404);
      expect(
        (await call(fixture, "PUT", path, Buffer.from("owned\n"), { "if-match": anyTag }))
          .statusCode,
      ).toBe(404);
    }

    // A symlinked prompt template resolves outside the agent directory: readable
    // as a host file, untagged here, and never writable through this origin.
    mkdirSync(join(fixture.agentDir, "prompts"));
    symlinkSync(outside, join(fixture.agentDir, "prompts", "link.md"));
    const linked = await call(fixture, "GET", "prompts/link.md");
    expect(linked.headers.ETag).toBeUndefined();
    const linkedWrite = await call(fixture, "PUT", "prompts/link.md", Buffer.from("owned\n"), {
      "if-match": anyTag,
    });
    expect(linkedWrite.statusCode).toBe(404);
    expect(readFileSync(outside, "utf8")).toBe("outside\n");
  });

  it("keeps conflicting origin parameters a 400", async () => {
    const fixture = seed();
    const read = await call(fixture, "GET", "SYSTEM.md", undefined, {}, { workspaceId: "w1" });
    expect(read.statusCode).toBe(400);
  });
});

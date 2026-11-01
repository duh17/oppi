import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

/// The create path writes a temp beside the target and then stats the handle it
/// opened. `failTempStat` makes that stat throw, so the cleanup that removes the
/// name it opened is exercised: without it a failed create would leave a temp
/// file in Pi's agent directory.
const fsControl = vi.hoisted(() => ({ failTempStat: false }));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (...args: Parameters<typeof actual.open>) => {
      const handle = await actual.open(...args);
      const target = String(args[0]);
      if (!fsControl.failTempStat || !target.includes(".oppi-edit-")) return handle;
      return {
        stat: async () => {
          throw Object.assign(new Error("EIO"), { code: "EIO" });
        },
        close: () => handle.close(),
      } as unknown as typeof handle;
    },
  };
});

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

  it("answers an empty creatable base for a missing allowlisted file", async () => {
    const fixture = seed();
    rmSync(join(fixture.agentDir, "SYSTEM.md"));

    const read = await call(fixture, "GET", "SYSTEM.md");
    expect(read.statusCode).toBe(200);
    expect(read.body.length).toBe(0);
    // No tag: there is no version to overwrite, and the first save creates it.
    expect(read.headers.ETag).toBeUndefined();
    expect(read.headers["X-Oppi-Creatable"]).toBe("1");
    expect(existsSync(join(fixture.agentDir, "SYSTEM.md"))).toBe(false);

    // A missing template is creatable with the directory it goes in.
    const prompt = await call(fixture, "GET", "prompts/review.md");
    expect(prompt.statusCode).toBe(200);
    expect(prompt.headers["X-Oppi-Creatable"]).toBe("1");
    expect(existsSync(join(fixture.agentDir, "prompts"))).toBe(false);
  });

  it("creates a missing file once, on If-None-Match: *", async () => {
    const fixture = seed();
    rmSync(join(fixture.agentDir, "SYSTEM.md"));
    const systemPrompt = join(fixture.agentDir, "SYSTEM.md");

    // A tag precondition cannot create: there is no version to match.
    const withTag = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("mine\n"), {
      "if-match": tag("nothing\n"),
    });
    expect(withTag.statusCode).toBe(404);
    expect(existsSync(systemPrompt)).toBe(false);

    const created = Buffer.from("# Pi system prompt, written here\n");
    const first = await call(fixture, "PUT", "SYSTEM.md", created, { "if-none-match": "*" });
    expect(first.statusCode).toBe(200);
    expect(readFileSync(systemPrompt).equals(created)).toBe(true);
    const createdTag = (JSON.parse(first.body.toString("utf8")) as { etag: string }).etag;
    expect(JSON.parse(first.body.toString("utf8"))).toMatchObject({ size: created.length });

    // The file is there now: the same create is a stale conflict, and the
    // bytes on disk stay the ones the first save wrote.
    const second = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("again\n"), {
      "if-none-match": "*",
    });
    expect(second.statusCode).toBe(412);
    expect(readFileSync(systemPrompt).equals(created)).toBe(true);

    // The read is an ordinary tagged read again, with the tag the save answered.
    const read = await call(fixture, "GET", "SYSTEM.md");
    expect(read.headers["X-Oppi-Creatable"]).toBeUndefined();
    expect(read.headers.ETag).toBe(createdTag);
    expect(read.body.equals(created)).toBe(true);
  });

  it("removes a create's temp when its own stat fails", async () => {
    const fixture = seed();
    rmSync(join(fixture.agentDir, "SYSTEM.md"));

    fsControl.failTempStat = true;
    try {
      const res = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("mine\n"), {
        "if-none-match": "*",
      });
      expect(res.statusCode).toBe(500);
    } finally {
      fsControl.failTempStat = false;
    }

    // The name it opened was ours (O_EXCL) and nothing else can prove it: it is
    // removed here rather than left in Pi's agent directory.
    expect(existsSync(join(fixture.agentDir, "SYSTEM.md"))).toBe(false);
    expect(readdirSync(fixture.agentDir).filter((name) => name.startsWith(".oppi-edit-"))).toEqual([]);
  });

  it("creates a prompt template and its prompts directory", async () => {
    const fixture = seed();
    const prompts = join(fixture.agentDir, "prompts");

    const created = Buffer.from("review the diff twice\n");
    const res = await call(fixture, "PUT", "prompts/review.md", created, {
      "if-none-match": "*",
    });
    expect(res.statusCode).toBe(200);
    expect(lstatSync(prompts).isDirectory()).toBe(true);
    expect(lstatSync(prompts).isSymbolicLink()).toBe(false);
    expect(readFileSync(join(prompts, "review.md")).equals(created)).toBe(true);
    // The bytes went through a temp and a link, so the directory holds the file
    // and nothing else: a reader never sees a half-written prompt.
    expect(readdirSync(prompts)).toEqual(["review.md"]);
  });

  it("never creates through a linked parent directory", async () => {
    const fixture = seed();
    const outside = join(fixture.root, "outside-prompts");
    mkdirSync(outside);
    // `prompts` is a link to a real directory outside the agent directory.
    symlinkSync(outside, join(fixture.agentDir, "prompts"));

    const read = await call(fixture, "GET", "prompts/new.md");
    expect(read.statusCode).toBe(404);
    expect(read.headers["X-Oppi-Creatable"]).toBeUndefined();
    const write = await call(fixture, "PUT", "prompts/new.md", Buffer.from("owned\n"), {
      "if-none-match": "*",
    });
    expect(write.statusCode).toBe(404);
    expect(existsSync(join(outside, "new.md"))).toBe(false);

    // A link to the agent directory itself is the same refusal: `prompts/x.md`
    // would otherwise create a file in the agent directory.
    rmSync(join(fixture.agentDir, "prompts"));
    symlinkSync(".", join(fixture.agentDir, "prompts"));
    expect((await call(fixture, "GET", "prompts/new.md")).statusCode).toBe(404);
    expect(
      (
        await call(fixture, "PUT", "prompts/new.md", Buffer.from("owned\n"), {
          "if-none-match": "*",
        })
      ).statusCode,
    ).toBe(404);
    expect(existsSync(join(fixture.agentDir, "new.md"))).toBe(false);
  });

  it("refuses to create a name the allowlist does not name", async () => {
    const fixture = seed();
    mkdirSync(join(fixture.agentDir, "prompts"));
    for (const path of ["prompts/notes.json", "prompts/sub/new.md", "notes.md"]) {
      const read = await call(fixture, "GET", path);
      expect(read.statusCode).toBe(404);
      const write = await call(fixture, "PUT", path, Buffer.from("owned\n"), {
        "if-none-match": "*",
      });
      expect(write.statusCode).toBe(404);
      expect(existsSync(join(fixture.agentDir, path))).toBe(false);
    }
  });

  it("keeps a linked SYSTEM.md read-only, and creates nothing in its place", async () => {
    const fixture = seed();
    const shared = join(fixture.root, "shared.md");
    const secret = "a shared prompt\n";
    writeFileSync(shared, secret);
    rmSync(join(fixture.agentDir, "SYSTEM.md"));
    symlinkSync(shared, join(fixture.agentDir, "SYSTEM.md"));

    // One decision point: the read is untagged and not creatable, so the editor
    // offers nothing, and the write answers the same refusal.
    const read = await call(fixture, "GET", "SYSTEM.md");
    expect(read.headers.ETag).toBeUndefined();
    expect(read.headers["X-Oppi-Creatable"]).toBeUndefined();
    const write = await call(fixture, "PUT", "SYSTEM.md", Buffer.from("owned\n"), {
      "if-none-match": "*",
    });
    expect(write.statusCode).toBe(404);
    expect(readFileSync(shared, "utf8")).toBe(secret);
    expect(lstatSync(join(fixture.agentDir, "SYSTEM.md")).isSymbolicLink()).toBe(true);
  });

  it("refuses a path the allowlist does not name, and never creates on a tag", async () => {
    const fixture = seed();
    mkdirSync(join(fixture.agentDir, "prompts"));
    const anyTag = `"sha256-${"a".repeat(64)}"`;

    for (const path of ["prompts/.git/config.md", "prompts/sub/new.md"]) {
      const res = await call(fixture, "PUT", path, Buffer.from("created\n"), { "if-match": anyTag });
      expect(res.statusCode).toBe(404);
      expect(existsSync(join(fixture.agentDir, path))).toBe(false);
    }
    // The allowlist names Markdown prompt templates, not every file under prompts/.
    writeFileSync(join(fixture.agentDir, "prompts", "notes.json"), "{}\n");
    expect((await call(fixture, "GET", "prompts/notes.json")).statusCode).toBe(404);
  });

  // `prompts/up -> ..`, so `prompts/up/APPEND_SYSTEM.md` is the agent directory's
  // own APPEND_SYSTEM.md. The requested name passes the lexical allowlist, so
  // only the canonical check can refuse it.
  it("refuses an allowlisted name a symlink leads to another agent file", async () => {
    const fixture = seed();
    const appendSystem = join(fixture.agentDir, "APPEND_SYSTEM.md");
    const secret = "appended by a symlink\n";
    writeFileSync(appendSystem, secret);
    mkdirSync(join(fixture.agentDir, "prompts"));
    symlinkSync("..", join(fixture.agentDir, "prompts", "up"));

    const read = await call(fixture, "GET", "prompts/up/APPEND_SYSTEM.md");
    expect(read.headers.ETag).toBeUndefined();
    const write = await call(
      fixture,
      "PUT",
      "prompts/up/APPEND_SYSTEM.md",
      Buffer.from("owned\n"),
      { "if-match": tag(secret) },
    );
    expect(write.statusCode).toBe(404);
    expect(readFileSync(appendSystem, "utf8")).toBe(secret);
  });

  it("refuses a prompts directory that is a symlink to the agent directory", async () => {
    const fixture = seed();
    // `prompts -> .` makes every sibling agent file look allowlisted; the name
    // `prompts/notes.md` passes the lexical allowlist, so only the canonical
    // check refuses it.
    symlinkSync(".", join(fixture.agentDir, "prompts"));
    const notes = join(fixture.agentDir, "notes.md");
    const secret = "agent notes\n";
    writeFileSync(notes, secret);

    const read = await call(fixture, "GET", "prompts/notes.md");
    expect(read.headers.ETag).toBeUndefined();
    const write = await call(fixture, "PUT", "prompts/notes.md", Buffer.from("owned\n"), {
      "if-match": tag(secret),
    });
    expect(write.statusCode).toBe(404);
    expect(readFileSync(notes, "utf8")).toBe(secret);
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

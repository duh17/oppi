import { createHash, randomBytes } from "node:crypto";
import { request, type IncomingMessage } from "node:http";
import {
  closeSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { Workspace } from "../src/types.js";

/**
 * File reads, downloads, and listings through the running server: its auth
 * gate, its routes, and the bytes on its socket.
 */
describe("file transfer through the running server", () => {
  let dataDir = "";
  let outside = "";
  let server: Server;
  let token = "";
  let hostWorkspace: Workspace;
  let sandboxWorkspace: Workspace;
  let bigPath = "";
  const BIG_SIZE = 800 * 1024 * 1024;
  const MARK = randomBytes(1024 * 1024);
  /** The 10k-entry folder's names, in the order a listing pages them. */
  const MANY: string[] = [];
  for (let i = 0; i < 10_000; i++) MANY.push(`file-${String(i).padStart(5, "0")}.txt`);
  for (let i = 0; i < 50; i++) MANY.push(`folder-${String(i).padStart(2, "0")}`);

  beforeAll(async () => {
    dataDir = realpathSync(mkdtempSync(join(tmpdir(), "oppi-file-transfer-")));
    outside = join(dataDir, "outside");
    mkdirSync(outside);
    writeFileSync(join(outside, "secret.txt"), "outside secret\n");

    const hostRoot = join(dataDir, "host-ws");
    mkdirSync(hostRoot);
    writeFileSync(join(hostRoot, "inside.txt"), "inside\n");
    // A large file, sparse but with distinct bytes at the start, middle, and
    // end, so a resume that spliced at the wrong offset changes its digest.
    bigPath = join(hostRoot, "big.bin");
    const fd = openSync(bigPath, "w");
    for (const offset of [0, BIG_SIZE / 2, BIG_SIZE - MARK.length])
      writeSync(fd, MARK, 0, MARK.length, offset);
    closeSync(fd);

    // A sandbox mount a guest controls: symlinks it planted point out of it.
    const sandboxRoot = join(dataDir, "sandbox-ws");
    mkdirSync(sandboxRoot);
    writeFileSync(join(sandboxRoot, "inside.txt"), "inside\n");
    symlinkSync(outside, join(sandboxRoot, "escape-dir"));
    symlinkSync(join(outside, "secret.txt"), join(sandboxRoot, "escape.txt"));

    // Made before the server starts: it shares this process, and seconds of synchronous
    // writes while it runs outlast its keep-alive timeout, so the next request goes out on a
    // pooled socket the server is closing ("socket hang up").
    const many = join(hostRoot, "many");
    mkdirSync(many);
    for (const name of MANY) {
      if (name.startsWith("folder-")) mkdirSync(join(many, name));
      else writeFileSync(join(many, name), "x");
    }

    const storage = new Storage(join(dataDir, "data"));
    token = storage.ensurePaired();
    storage.mutateConfig(() => ({ host: "127.0.0.1", port: 0, tls: { mode: "tailscale" } }));
    hostWorkspace = storage.createWorkspace({ name: "Host", hostMount: hostRoot });
    sandboxWorkspace = storage.createWorkspace({
      name: "Sandbox",
      hostMount: sandboxRoot,
      runtime: "sandbox",
    });
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    server = new Server(storage);
    try {
      await server.start();
    } finally {
      process.env.PATH = originalPath;
    }
    // The 10k-entry folder takes seconds on a busy machine.
  }, 60_000);

  afterAll(async () => {
    await server?.stop().catch(() => {});
    rmSync(dataDir, { recursive: true, force: true });
  });

  function get(
    path: string,
    headers: Record<string, string> = { Authorization: `Bearer ${token}` },
  ): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      const req = request(
        { socketPath: server.socketPath, method: "GET", path, headers },
        (res) => {
          let body = "";
          res.setEncoding("utf8");
          res.on("data", (chunk: string) => (body += chunk));
          res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
        },
      );
      req.on("error", reject);
      req.end();
    });
  }

  interface Transfer {
    status: number;
    headers: IncomingMessage["headers"];
    received: number;
    /** Every byte of this response, hashed as it arrived. */
    hash: ReturnType<typeof createHash>;
    /** Bytes so far, each time a chunk arrived. */
    progress: number[];
  }

  /**
   * GET `path`, hashing the body into `hash` as it streams. With `dropAfter`,
   * the socket is destroyed once that many bytes arrived, as a lost
   * connection or a cancel does.
   */
  function stream(
    path: string,
    headers: Record<string, string>,
    options: { dropAfter?: number; hash?: ReturnType<typeof createHash> } = {},
  ): Promise<Transfer> {
    const hash = options.hash ?? createHash("sha256");
    return new Promise((resolve, reject) => {
      const req = request(
        {
          socketPath: server.socketPath,
          method: "GET",
          path,
          headers: { Authorization: `Bearer ${token}`, ...headers },
        },
        (res) => {
          const transfer: Transfer = {
            status: res.statusCode ?? 0,
            headers: res.headers,
            received: 0,
            hash,
            progress: [],
          };
          res.on("data", (chunk: Buffer) => {
            const keep =
              options.dropAfter === undefined
                ? chunk
                : chunk.subarray(0, Math.max(0, options.dropAfter - transfer.received));
            hash.update(keep);
            transfer.received += keep.length;
            transfer.progress.push(transfer.received);
            if (options.dropAfter !== undefined && transfer.received >= options.dropAfter) {
              req.destroy();
              resolve(transfer);
            }
          });
          res.on("end", () => resolve(transfer));
          res.on("error", () => resolve(transfer));
        },
      );
      req.on("error", (error) => {
        if (options.dropAfter === undefined) reject(error);
      });
      req.end();
    });
  }

  /** File descriptors this process holds: the server runs in it. */
  function openDescriptors(): number {
    return readdirSync("/dev/fd").length;
  }

  async function settle(check: () => boolean): Promise<void> {
    for (let i = 0; i < 100 && !check(); i++) await new Promise((r) => setTimeout(r, 20));
  }

  function currentFile(workspace: Workspace, path: string): string {
    return `/files/current?${new URLSearchParams({ origin: "workspace", workspaceId: workspace.id, path })}`;
  }

  describe("large downloads", () => {
    const WANT = { Range: "bytes=0-", "X-Oppi-Want-File-Digest": "sha-256" };

    it(
      "streams an 800 MB file in pieces with its size and digest, without holding it",
      { timeout: 120_000 },
      async () => {
        const rssBefore = process.memoryUsage().rss;
        let rssPeak = rssBefore;
        const sampler = setInterval(() => {
          rssPeak = Math.max(rssPeak, process.memoryUsage().rss);
        }, 25);
        let whole: Transfer;
        try {
          whole = await stream(currentFile(hostWorkspace, "big.bin"), WANT);
        } finally {
          clearInterval(sampler);
        }

        expect(whole.status).toBe(206);
        expect(whole.headers["content-range"]).toBe(`bytes 0-${BIG_SIZE - 1}/${BIG_SIZE}`);
        expect(whole.headers["content-length"]).toBe(String(BIG_SIZE));
        expect(whole.headers.etag).toMatch(/^"[0-9a-f-]+"$/);
        expect(whole.received).toBe(BIG_SIZE);
        expect(whole.headers["x-oppi-file-digest"]).toBe(
          `sha-256=:${whole.hash.digest("base64")}:`,
        );
        // Progress: many steps, each further than the last.
        expect(whole.progress.length).toBeGreaterThan(100);
        expect(whole.progress.every((value, i) => i === 0 || value > whole.progress[i - 1])).toBe(
          true,
        );
        // Neither end held the file: the process grew by well under its size
        // (chunks awaiting collection account for the growth there is).
        expect(rssPeak - rssBefore).toBeLessThan(BIG_SIZE / 2);
      },
    );

    it(
      "stops reading and lets the file go when the client cancels",
      { timeout: 60_000 },
      async () => {
        const before = openDescriptors();
        const cancelled = await stream(currentFile(hostWorkspace, "big.bin"), WANT, {
          dropAfter: 64 * 1024 * 1024,
        });
        expect(cancelled.status).toBe(206);
        expect(cancelled.received).toBe(64 * 1024 * 1024);
        // The server closed its handle on the file and its socket.
        await settle(() => openDescriptors() <= before);
        expect(openDescriptors()).toBeLessThanOrEqual(before);
        // And still answers.
        expect((await get(currentFile(hostWorkspace, "inside.txt"))).body).toBe("inside\n");
      },
    );

    it(
      "resumes a dropped download where it stopped while the file is unchanged, and restarts once it changed",
      { timeout: 120_000 },
      async () => {
        const hash = createHash("sha256");
        const dropAt = 300 * 1024 * 1024 + 17;
        const first = await stream(currentFile(hostWorkspace, "big.bin"), WANT, {
          dropAfter: dropAt,
          hash,
        });
        expect(first.received).toBe(dropAt);
        const etag = String(first.headers.etag);
        const digest = String(first.headers["x-oppi-file-digest"]);

        const rest = await stream(
          currentFile(hostWorkspace, "big.bin"),
          { Range: `bytes=${dropAt}-`, "If-Range": etag, "X-Oppi-Want-File-Digest": "sha-256" },
          { hash },
        );
        expect(rest.status).toBe(206);
        expect(rest.headers["content-range"]).toBe(`bytes ${dropAt}-${BIG_SIZE - 1}/${BIG_SIZE}`);
        expect(rest.headers.etag).toBe(etag);
        expect(dropAt + rest.received).toBe(BIG_SIZE);
        // The two pieces are the file, byte for byte.
        expect(`sha-256=:${hash.digest("base64")}:`).toBe(digest);

        // The file changes before the next resume: the old version's
        // If-Range no longer holds, so the whole new file comes back.
        const later = new Date(Date.now() + 5_000);
        utimesSync(bigPath, later, later);
        const restarted = await stream(
          currentFile(hostWorkspace, "big.bin"),
          { Range: `bytes=${dropAt}-`, "If-Range": etag },
          { dropAfter: 1024 },
        );
        expect(restarted.status).toBe(200);
        expect(restarted.headers["content-length"]).toBe(String(BIG_SIZE));
        expect(restarted.headers["content-range"]).toBeUndefined();
      },
    );

    it("names what is wrong when a download cannot start", async () => {
      expect(await get(currentFile(hostWorkspace, "missing.bin"))).toEqual({
        status: 404,
        body: JSON.stringify({ error: "File not found" }),
      });
      const past = await stream(currentFile(hostWorkspace, "big.bin"), {
        Range: `bytes=${BIG_SIZE}-`,
      });
      expect(past.status).toBe(416);
      expect(past.headers["content-range"]).toBe(`bytes */${BIG_SIZE}`);
    });
  });

  describe("listings", () => {
    it(
      "pages a 10k-entry folder: every entry once, in name order",
      { timeout: 60_000 },
      async () => {
        const names: string[] = [];
        const pageSizes: number[] = [];
        let after: string | null = null;
        do {
          const query: string = after === null ? "" : `?after=${encodeURIComponent(after)}`;
          const res = await get(`/workspaces/${hostWorkspace.id}/contents/many/${query}`);
          expect(res.status).toBe(200);
          const page = JSON.parse(res.body) as {
            path: string;
            entries: Array<{ name: string; type: string }>;
            truncated: boolean;
            next: string | null;
          };
          expect(page.path).toBe("many/");
          expect(page.truncated).toBe(page.next !== null);
          pageSizes.push(page.entries.length);
          names.push(...page.entries.map((entry) => entry.name));
          after = page.next;
        } while (after !== null);

        expect(pageSizes).toEqual([...Array<number>(10).fill(1000), 50]);
        expect(names).toEqual(MANY);
        // The cursor travels as an ordinary query value whatever the name holds.
        const odd = "a&b=c d#e";
        writeFileSync(join(dataDir, "host-ws", "many", odd), "");
        const res = await get(
          `/workspaces/${hostWorkspace.id}/contents/many/?after=${encodeURIComponent("a")}`,
        );
        expect(
          (JSON.parse(res.body) as { entries: Array<{ name: string }> }).entries[0]?.name,
        ).toBe(odd);
      },
    );
  });

  describe("path containment", () => {
    it("refuses listings that leave the workspace or home, in any encoding", async () => {
      const escapes = [
        `/workspaces/${hostWorkspace.id}/contents/..%2F`,
        `/workspaces/${hostWorkspace.id}/contents/%2e%2e%2F%2e%2e%2F`,
        `/workspaces/${hostWorkspace.id}/contents/sub%2F..%2F..%2Foutside`,
        `/workspaces/${hostWorkspace.id}/contents/${encodeURIComponent(outside)}`,
        `/workspaces/${sandboxWorkspace.id}/contents/..%2Foutside`,
        `/workspaces/${sandboxWorkspace.id}/contents/${encodeURIComponent(outside)}`,
        // A symlinked directory the guest planted: lexically inside, really outside.
        `/workspaces/${sandboxWorkspace.id}/contents/escape-dir`,
        "/host/contents/..%2F",
        "/host/contents/%2e%2e%2F%2e%2e",
        "/host/contents/%2Fetc",
      ];
      for (const path of escapes) {
        const res = await get(path);
        expect(res.status, path).toBe(403);
        // Says what is wrong without naming any host path.
        expect(res.body, path).not.toContain(dataDir);
        expect(res.body, path).not.toContain("secret");
      }
    });

    it("leaves a double-encoded `..` a literal name, not a parent", async () => {
      const res = await get(`/workspaces/${hostWorkspace.id}/contents/%252e%252e%252F`);
      expect(res).toEqual({ status: 404, body: JSON.stringify({ error: "Directory not found" }) });
    });

    it("keeps a sandbox listing and its reads inside the mount, through symlinks too", async () => {
      const listing = await get(`/workspaces/${sandboxWorkspace.id}/contents`);
      expect(listing.status).toBe(200);
      const names = (JSON.parse(listing.body) as { entries: Array<{ name: string }> }).entries.map(
        (entry) => entry.name,
      );
      expect(names).toEqual(["inside.txt"]);

      for (const path of [
        "escape.txt",
        "escape-dir/secret.txt",
        "../outside/secret.txt",
        join(outside, "secret.txt"),
      ]) {
        const res = await get(currentFile(sandboxWorkspace, path));
        expect(res.status, path).toBe(403);
        expect(res.body, path).toBe(JSON.stringify({ error: "Path outside sandbox workspace" }));
      }
      expect(await get(currentFile(sandboxWorkspace, "inside.txt"))).toEqual({
        status: 200,
        body: "inside\n",
      });
    });

    it("asks for credentials on every file route before it resolves a path", async () => {
      for (const path of [
        `/workspaces/${hostWorkspace.id}/contents`,
        `/workspaces/${hostWorkspace.id}/contents/..%2F`,
        "/host/contents/%2Fetc",
        currentFile(hostWorkspace, "inside.txt"),
        `/files/current?${new URLSearchParams({ origin: "host", path: join(outside, "secret.txt") })}`,
      ]) {
        for (const headers of [{}, { Authorization: "Bearer wrong" }]) {
          const res = await get(path, headers);
          expect(res.status, path).toBe(401);
          expect(res.body, path).not.toContain("secret");
        }
      }
    });
  });
});

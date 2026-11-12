import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  PINNED_BUN_VERSION,
  SERVER_WORKER_IDENTIFIER,
  assertPinnedBunMatchesServer,
  bundledBunPath,
  bunReleaseZipUrl,
  codesignArgs,
  downloadVerifiedZip,
  machOSigningOrder,
  pruneToArm64,
  readMachO,
  serverBunEntitlementsPlist,
  sha256Hex,
  stageBundledBun,
} from "./bundle-mac-server-bun";

const ARM64 = 0x0100000c;
const X86_64 = 0x01000007;

function thinMachO(cpuType: number): Buffer {
  const bytes = Buffer.alloc(32);
  bytes.writeUInt32LE(0xfeedfacf, 0);
  bytes.writeUInt32LE(cpuType, 4);
  return bytes;
}

function fatMachO(cpuTypes: number[]): Buffer {
  const bytes = Buffer.alloc(8 + cpuTypes.length * 20);
  bytes.writeUInt32BE(0xcafebabe, 0);
  bytes.writeUInt32BE(cpuTypes.length, 4);
  cpuTypes.forEach((cpuType, i) => bytes.writeUInt32BE(cpuType, 8 + i * 20));
  return bytes;
}

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "oppi-bun-bundle-test-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function put(path: string, bytes: Buffer | string): string {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
  return path;
}

describe("signing", () => {
  test("only bun carries the worker identifier and entitlements, never Oppi's DR", () => {
    expect(SERVER_WORKER_IDENTIFIER).toBe("dev.chenda.Oppi.server");
    const worker = codesignArgs({
      identity: "Developer ID Application: Example (TEAMID)",
      path: "/tmp/Oppi.app/Contents/Helpers/bun",
      entitlementsPath: "/tmp/Oppi.server.entitlements",
    });
    expect(worker.slice(0, 5)).toEqual(["codesign", "--force", "--options", "runtime", "--timestamp"]);
    expect(worker[worker.indexOf("--identifier") + 1]).toBe("dev.chenda.Oppi.server");
    expect(worker[worker.indexOf("--entitlements") + 1]).toBe("/tmp/Oppi.server.entitlements");
    expect(worker.at(-1)).toBe("/tmp/Oppi.app/Contents/Helpers/bun");
    expect(worker).not.toContain("--requirements");

    const addon = codesignArgs({ identity: "X", path: "/tmp/a.node" });
    expect(addon).not.toContain("--identifier");
    expect(addon).not.toContain("--entitlements");
    expect(addon).toContain("runtime");
  });

  test("worker entitlements allow the JIT and are not Oppi's GUI entitlements", () => {
    const xml = serverBunEntitlementsPlist();
    expect(xml).toContain("com.apple.security.cs.allow-jit");
    expect(xml).not.toContain("com.apple.security.device.audio-input");
    expect(xml).not.toContain("com.apple.security.app-sandbox");
  });

  test("lists every Mach-O under Contents/Helpers inside-out, bun last", () => {
    const app = join(dir, "Oppi.app");
    const helpers = join(app, "Contents/Helpers");
    const bun = put(join(helpers, "bun"), thinMachO(ARM64));
    const addon = put(join(helpers, "server/node_modules/a/build/Release/a.node"), thinMachO(ARM64));
    const tool = put(join(helpers, "server/node_modules/b/bin/tool"), thinMachO(ARM64));
    put(join(helpers, "server/dist/src/cli.js"), "#!/usr/bin/env node\n");

    expect(machOSigningOrder(app)).toEqual([addon, tool, bun]);
  });
});

describe("arm64 pruning", () => {
  test("keeps arm64, drops other architectures and other platforms' addons", () => {
    const root = join(dir, "server");
    const arm = put(join(root, "darwin-arm64/addon.node"), thinMachO(ARM64));
    const intel = put(join(root, "darwin-x64/addon.node"), thinMachO(X86_64));
    const fatIntel = put(join(root, "old/addon.node"), fatMachO([X86_64, 7]));
    const linux = put(join(root, "linux-x64/addon.node"), "\x7fELF");
    const script = put(join(root, "index.js"), "module.exports = 1;\n");

    const removed = pruneToArm64(root);

    expect(removed.sort()).toEqual([intel, fatIntel, linux].sort());
    expect([arm, script].every(existsSync)).toBe(true);
  });

  test("reads fat headers and does not mistake a Java class file for one", () => {
    expect(readMachO(put(join(dir, "fat"), fatMachO([ARM64, X86_64])))).toEqual({
      fat: true,
      cpuTypes: [ARM64, X86_64],
    });
    const javaClass = Buffer.from([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x34]);
    expect(readMachO(put(join(dir, "A.class"), javaClass))).toBeNull();
  });
});

// Local fixtures only: these tests never touch the network.
describe("pinned Bun download integrity", () => {
  function responder(bytes: Uint8Array, finalUrl?: string): typeof fetch {
    return (async (input: string | URL | Request) => {
      const response = new Response(bytes);
      Object.defineProperty(response, "url", { value: finalUrl ?? String(input) });
      return response;
    }) as typeof fetch;
  }

  const url = bunReleaseZipUrl(PINNED_BUN_VERSION);
  const bytes = new Uint8Array(Buffer.from("not really a zip"));

  test("returns the bytes only when the SHA-256 matches", async () => {
    const got = await downloadVerifiedZip({
      url,
      expectedSha256: sha256Hex(bytes),
      fetchImpl: responder(bytes),
    });
    expect(sha256Hex(got)).toBe(sha256Hex(bytes));
  });

  test("fails closed on a digest mismatch", async () => {
    await expect(
      downloadVerifiedZip({ url, expectedSha256: "0".repeat(64), fetchImpl: responder(bytes) }),
    ).rejects.toThrow(/SHA-256 mismatch/);
  });

  test("fails closed when the download leaves GitHub's release hosts", async () => {
    await expect(
      downloadVerifiedZip({
        url,
        expectedSha256: sha256Hex(bytes),
        fetchImpl: responder(bytes, "https://evil.example/bun.zip"),
      }),
    ).rejects.toThrow(/left GitHub's release hosts/);
  });

  test("staging aborts on a digest mismatch: no bun written, temp dir removed", async () => {
    const app = join(dir, "Oppi.app");
    const before = new Set(readdirSync(tmpdir()).filter((n) => n.startsWith("oppi-bun-1")));
    await expect(stageBundledBun(app, { fetchImpl: responder(bytes) })).rejects.toThrow(
      /SHA-256 mismatch/,
    );
    expect(existsSync(bundledBunPath(app))).toBe(false);
    const leaked = readdirSync(tmpdir()).filter((n) => n.startsWith("oppi-bun-1") && !before.has(n));
    expect(leaked).toEqual([]);
  });

  test("refuses to bundle a Bun other than the one server/.bun-version pins", () => {
    const serverDir = join(dir, "server");
    put(join(serverDir, ".bun-version"), "9.9.9\n");
    expect(() => assertPinnedBunMatchesServer(serverDir)).toThrow(/pins Bun 9\.9\.9/);
    assertPinnedBunMatchesServer();
  });
});

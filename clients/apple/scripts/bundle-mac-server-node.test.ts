import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  PINNED_NODE_VERSION,
  SERVER_WORKER_IDENTIFIER,
  bundledNodePath,
  downloadVerifiedTarball,
  nodeBinaryPathInsideTarball,
  officialNodeTarballUrl,
  serverNodeCodesignArgs,
  serverNodeEntitlementsPlist,
  sha256Hex,
  stageBundledNode,
} from "./bundle-mac-server-node";

describe("bundle-mac-server-node", () => {
  test("signs the worker as dev.chenda.OppiMac.server without copying Oppi's DR", () => {
    expect(SERVER_WORKER_IDENTIFIER).toBe("dev.chenda.OppiMac.server");
    const args = serverNodeCodesignArgs({
      identity: "Developer ID Application: Example (TEAMID)",
      nodePath: "/tmp/Oppi.app/Contents/Resources/Helpers/node",
      entitlementsPath: "/tmp/OppiMac.server.entitlements",
    });
    // release-mac.sh runs exactly these args (step 1b).
    expect(args[0]).toBe("codesign");
    expect(args.slice(args.indexOf("--options"), args.indexOf("--options") + 2)).toEqual([
      "--options",
      "runtime",
    ]);
    expect(args).toContain("--timestamp");
    expect(args[args.indexOf("--entitlements") + 1]).toBe("/tmp/OppiMac.server.entitlements");
    expect(args[args.indexOf("--identifier") + 1]).toBe("dev.chenda.OppiMac.server");
    expect(args.at(-1)).toBe("/tmp/Oppi.app/Contents/Resources/Helpers/node");
    expect(args).not.toContain("--requirements");
    expect(args).not.toContain("dev.chenda.OppiMac");
    expect(args.join(" ")).not.toContain("OppiMac.entitlements");
  });

  test("worker entitlements are Node-specific and not Oppi's GUI entitlements", () => {
    const xml = serverNodeEntitlementsPlist();
    expect(xml).toContain("com.apple.security.cs.allow-jit");
    expect(xml).not.toContain("com.apple.security.device.audio-input");
    expect(xml).not.toContain("com.apple.security.app-sandbox");
  });
});

// Local fixtures only: these tests never touch the network.
describe("pinned Node download integrity", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-node-test-"));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  /** A tarball shaped like nodejs.org's, whose "node" is a script printing `version`. */
  function fixtureTarball(version: string): Uint8Array {
    const root = join(dir, `tar-src-${version}`);
    for (const arch of ["arm64", "x64"] as const) {
      const bin = join(root, nodeBinaryPathInsideTarball(PINNED_NODE_VERSION, arch));
      mkdirSync(join(bin, ".."), { recursive: true });
      writeFileSync(bin, `#!/bin/sh\necho v${version}\n`, { mode: 0o755 });
    }
    const out = join(dir, `fixture-${version}.tar.gz`);
    const tar = spawnSync("tar", ["-czf", out, "-C", root, "."]);
    expect(tar.status).toBe(0);
    return new Uint8Array(readFileSync(out));
  }

  function responder(bytes: Uint8Array, finalUrl?: string): typeof fetch {
    return (async (input: string | URL | Request) => {
      const response = new Response(bytes);
      Object.defineProperty(response, "url", { value: finalUrl ?? String(input) });
      return response;
    }) as typeof fetch;
  }

  const url = officialNodeTarballUrl(PINNED_NODE_VERSION, "arm64");

  test("returns the bytes only when the SHA-256 matches", async () => {
    const bytes = fixtureTarball(PINNED_NODE_VERSION);
    const got = await downloadVerifiedTarball({
      url,
      expectedSha256: sha256Hex(bytes),
      fetchImpl: responder(bytes),
    });
    expect(sha256Hex(got)).toBe(sha256Hex(bytes));
  });

  test("fails closed on a digest mismatch", async () => {
    const bytes = fixtureTarball(PINNED_NODE_VERSION);
    await expect(
      downloadVerifiedTarball({
        url,
        expectedSha256: "0".repeat(64),
        fetchImpl: responder(bytes),
      }),
    ).rejects.toThrow(/SHA-256 mismatch/);
  });

  test("fails closed when the download leaves https://nodejs.org", async () => {
    const bytes = fixtureTarball(PINNED_NODE_VERSION);
    await expect(
      downloadVerifiedTarball({
        url,
        expectedSha256: sha256Hex(bytes),
        fetchImpl: responder(bytes, "https://evil.example/node.tar.gz"),
      }),
    ).rejects.toThrow(/left https:\/\/nodejs\.org/);
  });

  test("staging aborts on a digest mismatch: no helper written, temp dir removed", async () => {
    const app = join(dir, "Oppi.app");
    const before = new Set(readdirSync(tmpdir()).filter((n) => n.startsWith("oppi-node-2")));
    await expect(
      // The fixture's digest differs from the pinned official digests.
      stageBundledNode(app, { fetchImpl: responder(fixtureTarball(PINNED_NODE_VERSION)) }),
    ).rejects.toThrow(/SHA-256 mismatch/);
    expect(existsSync(bundledNodePath(app))).toBe(false);
    const leaked = readdirSync(tmpdir()).filter(
      (n) => n.startsWith("oppi-node-2") && !before.has(n),
    );
    expect(leaked).toEqual([]);
  });

  test("staging aborts when the extracted node is not the pinned version", async () => {
    const app = join(dir, "Oppi.app");
    const bytes = fixtureTarball("24.11.0");
    const digest = sha256Hex(bytes);
    await expect(
      stageBundledNode(app, {
        fetchImpl: responder(bytes),
        sha256: { arm64: digest, x64: digest },
      }),
    ).rejects.toThrow(/reports v24\.11\.0, expected v24\.11\.1/);
    expect(existsSync(bundledNodePath(app))).toBe(false);
  });
});

import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { readPackagedOppiDoc, resolveDocsReadPath } from "../src/default-agent-docs-read.js";

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function makeDocsRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-docs-read-"));
  dirs.push(root);
  writeFileSync(join(root, "server-configuration.md"), "# Server configuration\nASR and TTS.\n");
  writeFileSync(join(root, "extensions.md"), "# Extensions\n");
  return root;
}

describe("docs-only control read", () => {
  it("reads packaged docs by relative and absolute path", async () => {
    const root = makeDocsRoot();
    const relative = await readPackagedOppiDoc("server-configuration.md", { docsRoot: root });
    expect(relative.text).toContain("ASR and TTS");

    const absolute = await readPackagedOppiDoc(join(root, "extensions.md"), { docsRoot: root });
    expect(absolute.text).toContain("# Extensions");
  });

  it("rejects config, credentials, and escaped paths", async () => {
    const root = makeDocsRoot();
    const outside = mkdtempSync(join(tmpdir(), "oppi-docs-outside-"));
    dirs.push(outside);
    writeFileSync(join(outside, "config.json"), JSON.stringify({ token: "secret-token" }));
    writeFileSync(join(outside, "auth.json"), JSON.stringify({ key: "provider-secret" }));

    await expect(resolveDocsReadPath(join(outside, "config.json"), root)).rejects.toThrow(
      /limited to packaged Oppi docs|File not found/,
    );
    await expect(resolveDocsReadPath(join(outside, "auth.json"), root)).rejects.toThrow(
      /limited to packaged Oppi docs|File not found/,
    );
    await expect(resolveDocsReadPath("../config.json", root)).rejects.toThrow(
      /limited to packaged Oppi docs|File not found/,
    );

    const link = join(root, "escape.md");
    symlinkSync(join(outside, "config.json"), link);
    await expect(resolveDocsReadPath("escape.md", root)).rejects.toThrow(
      /limited to packaged Oppi docs/,
    );
  });

  it("validates offset and limit and truncates within the byte cap", async () => {
    const root = makeDocsRoot();
    const big = join(root, "big.md");
    writeFileSync(big, Array.from({ length: 3000 }, (_, i) => `line ${i}`).join("\n"));

    await expect(readPackagedOppiDoc("big.md", { docsRoot: root, offset: 0 })).rejects.toThrow(
      /positive integer/,
    );
    await expect(readPackagedOppiDoc("big.md", { docsRoot: root, limit: -1 })).rejects.toThrow(
      /positive integer/,
    );
    await expect(readPackagedOppiDoc("big.md", { docsRoot: root, limit: 1.5 })).rejects.toThrow(
      /positive integer/,
    );
    await expect(
      readPackagedOppiDoc("big.md", { docsRoot: root, offset: Number.NaN }),
    ).rejects.toThrow(/positive integer/);

    const offset = await readPackagedOppiDoc("big.md", { docsRoot: root, offset: 2, limit: 1 });
    expect(offset.text).toContain("line 1");
    expect(offset.text).not.toContain("line 0");
    expect(offset.truncated).toBe(false);

    const truncated = await readPackagedOppiDoc("big.md", { docsRoot: root });
    expect(truncated.truncated).toBe(true);
    expect(truncated.text).toContain("[Truncated packaged doc read]");
    expect(Buffer.byteLength(truncated.text, "utf8")).toBeLessThanOrEqual(50 * 1024);
  });
});

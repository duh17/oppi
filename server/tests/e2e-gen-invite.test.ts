import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("e2e invite generation", () => {
  it("keeps src invite helpers limited to generateInvite", () => {
    const srcNames = readdirSync(join(serverRoot, "src"));
    expect(srcNames.filter((name) => name.includes("invite"))).toEqual(["invite.ts"]);
  });

  it("keeps the official helper on generateInvite and storage only", () => {
    const helper = readFileSync(join(serverRoot, "scripts/e2e-gen-invite.mjs"), "utf8");
    expect(helper).toContain("generateInvite");
    const importedFiles = [...helper.matchAll(/dist\/src\/([A-Za-z0-9.-]+\.js)/g)].map(
      (match) => match[1],
    );
    expect(importedFiles.sort()).toEqual(["invite.js", "storage.js"]);
  });
});

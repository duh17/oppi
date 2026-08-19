import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("e2e invite generation", () => {
  it("does not ship the removed Iroh invite-state module", () => {
    expect(existsSync(join(serverRoot, "src/iroh-invite-state.ts"))).toBe(false);
  });

  it("keeps the official helper on generateInvite without Iroh imports", () => {
    const helper = readFileSync(join(serverRoot, "scripts/e2e-gen-invite.mjs"), "utf8");
    expect(helper).toContain("generateInvite");
    expect(helper).not.toMatch(/iroh-invite-state/);
    expect(helper).not.toMatch(/irohOnly/);
    expect(helper).not.toMatch(/OPPI_E2E_IROH_PAIRING/);
    expect(helper).not.toMatch(/iroh\/invite\.json/);
  });
});

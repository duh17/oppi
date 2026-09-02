import { describe, expect, it } from "vitest";

import { formatAuthMigrationCopy } from "../src/cli.js";

describe("formatAuthMigrationCopy", () => {
  it("states that compat only permits /auth/migrate and ordinary HTTP/WS rejects dt_", () => {
    expect(formatAuthMigrationCopy({ kind: "status", finalized: false })).toEqual({
      headline:
        "  Legacy device-token migration: compat (/auth/migrate only; ordinary HTTP/WS always rejects dt_)",
    });
  });

  it("states that finalized disables migration without claiming a new ordinary-auth rejection", () => {
    expect(formatAuthMigrationCopy({ kind: "status", finalized: true })).toEqual({
      headline:
        "  Legacy device-token migration: finalized (migration disabled; ordinary HTTP/WS always rejects dt_)",
    });
  });

  it("describes finalize as disabling migrate, with a dt_ update-or-re-pair warning", () => {
    expect(formatAuthMigrationCopy({ kind: "updated", finalized: true })).toEqual({
      headline: "  ✓ Finalized device-key migration. /auth/migrate is now disabled.",
      warning:
        "  Devices still holding dt_ need to update and migrate before finalization, or re-pair after.",
    });
  });

  it("describes compat restore as migrate-only", () => {
    expect(formatAuthMigrationCopy({ kind: "updated", finalized: false })).toEqual({
      headline:
        "  ✓ Restored dt_ compatibility for /auth/migrate only. Ordinary HTTP/WS still rejects dt_.",
    });
  });
});

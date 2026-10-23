import { afterEach, describe, expect, it, vi } from "vitest";

import {
  callerSessionIdFromEnvironment,
  OPPI_CALLER_SESSION_ID_ENV,
} from "../src/session-caller-identity.js";

const inheritedCaller = process.env[OPPI_CALLER_SESSION_ID_ENV];

afterEach(() => {
  if (inheritedCaller === undefined) delete process.env[OPPI_CALLER_SESSION_ID_ENV];
  else process.env[OPPI_CALLER_SESSION_ID_ENV] = inheritedCaller;
  vi.resetModules();
});

// Loading the whole CLI entry graph is a few seconds cold, so the describe carries its own
// timeout rather than the suite default.
describe("oppi CLI startup", { timeout: 30_000 }, () => {
  it("keeps the caller identity of the session bash that ran it", async () => {
    // `oppi session create` run from a session's bash inherits that session's id, and
    // `cli/commands/session.ts` reads it from the environment to parent the launch and to refuse
    // targeting the caller. Loading the CLI entry module must not drop it on the way in.
    process.env[OPPI_CALLER_SESSION_ID_ENV] = "sess-caller";
    vi.resetModules();

    // Import only: no command runs (`import.meta.main` is false here), so nothing else can
    // consume the id first.
    await import("../src/cli.js");

    expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("sess-caller");
    expect(callerSessionIdFromEnvironment()).toBe("sess-caller");
  });
});

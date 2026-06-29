import { describe, expect, it, vi } from "vitest";

import { cmdWait } from "../src/cli/commands/wait.js";
import type { Storage } from "../src/storage.js";

describe("cmdWait", () => {
  it("rejects a zero poll interval before calling the local API", async () => {
    const getToken = vi.fn(() => {
      throw new Error("should not poll");
    });
    const storage = { getToken } as unknown as Storage;
    const previousExitCode = process.exitCode;
    const write = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    try {
      process.exitCode = undefined;
      await cmdWait(storage, "session", ["sess-1"], { poll: "0ms", json: "true" });

      expect(getToken).not.toHaveBeenCalled();
      expect(process.exitCode).toBe(1);
      expect(JSON.parse(write.mock.calls.map((call) => String(call[0])).join(""))).toEqual({
        ok: false,
        error: { message: "--poll must be a positive duration" },
      });
    } finally {
      write.mockRestore();
      process.exitCode = previousExitCode;
    }
  });
});

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("node:child_process", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    execSync: vi.fn(),
  };
});

vi.mock("node:fs", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    existsSync: vi.fn(),
  };
});

import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolvePiExecutable } from "../src/session-spawn.js";

const mockedExecSync = vi.mocked(execSync);
const mockedExistsSync = vi.mocked(existsSync);

describe("session-spawn resolvePiExecutable", () => {
  const originalEnv = process.env.OPPI_PI_BIN;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    if (originalEnv === undefined) {
      delete process.env.OPPI_PI_BIN;
    } else {
      process.env.OPPI_PI_BIN = originalEnv;
    }
  });

  it("prefers OPPI_PI_BIN when it exists", () => {
    process.env.OPPI_PI_BIN = "/custom/pi";
    mockedExistsSync.mockImplementation((path) => path === "/custom/pi");

    expect(resolvePiExecutable()).toBe("/custom/pi");
    expect(mockedExecSync).not.toHaveBeenCalled();
  });

  it("uses `which pi` discovery when env override is absent", () => {
    delete process.env.OPPI_PI_BIN;
    mockedExistsSync.mockReturnValue(false);
    mockedExecSync.mockReturnValue("/usr/local/bin/pi\n" as never);

    expect(resolvePiExecutable()).toBe("/usr/local/bin/pi");
  });

  it("falls back to known install path when which fails", () => {
    delete process.env.OPPI_PI_BIN;
    mockedExecSync.mockImplementation(() => {
      throw new Error("not found");
    });
    mockedExistsSync.mockImplementation((path) => path === "/opt/homebrew/bin/pi");

    expect(resolvePiExecutable()).toBe("/opt/homebrew/bin/pi");
  });

  it("returns plain `pi` when nothing is discoverable", () => {
    delete process.env.OPPI_PI_BIN;
    mockedExecSync.mockImplementation(() => {
      throw new Error("not found");
    });
    mockedExistsSync.mockReturnValue(false);

    expect(resolvePiExecutable()).toBe("pi");
  });
});

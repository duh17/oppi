import { homedir } from "node:os";
import { resolve as resolvePath } from "node:path";
import { describe, expect, it } from "vitest";

import { resolveSdkSessionCwd } from "../src/sdk-backend.js";
import type { Workspace } from "../src/types.js";

describe("resolveSdkSessionCwd", () => {
  it("defaults to home dir when workspace is missing", () => {
    expect(resolveSdkSessionCwd(undefined)).toBe(homedir());
  });

  it("expands tilde hostMount to an absolute path", () => {
    const workspace = { hostMount: "~/workspace/oppi" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(resolvePath(homedir(), "workspace", "oppi"));
  });

  it("expands bare tilde hostMount", () => {
    const workspace = { hostMount: "~" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(homedir());
  });

  it("keeps absolute hostMount unchanged", () => {
    const mount = resolvePath(homedir(), "workspace", "oppi");
    const workspace = { hostMount: mount } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(mount);
  });
});

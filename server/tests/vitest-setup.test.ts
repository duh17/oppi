import { describe, expect, it } from "vitest";

import { sanitizeGitLocalEnvironment } from "../vitest.setup.ts";

describe("Vitest Git environment isolation", () => {
  it("removes repository routing without discarding unrelated Git identity", () => {
    const environment: NodeJS.ProcessEnv = {
      PATH: "/usr/bin",
      GIT_DIR: "/developer/repository/.git",
      GIT_WORK_TREE: "/developer/repository",
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "user.name",
      GIT_CONFIG_VALUE_0: "Oppi Test",
      GIT_AUTHOR_NAME: "Expected Committer",
    };

    sanitizeGitLocalEnvironment(environment, ["GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT"]);

    expect(environment).toEqual({
      PATH: "/usr/bin",
      GIT_AUTHOR_NAME: "Expected Committer",
    });
  });
});

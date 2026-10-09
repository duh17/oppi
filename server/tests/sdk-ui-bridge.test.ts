import { describe, expect, it } from "vitest";

import { extensionScopeFromPath } from "../src/sdk-ui-bridge.js";

describe("extensionScopeFromPath", () => {
  it("attributes npm packages from node_modules", () => {
    expect(
      extensionScopeFromPath("/Users/me/.pi/agent/npm/node_modules/@acme/search-web/dist/index.js"),
    ).toEqual({
      extensionScopeId: "npm:@acme/search-web",
      extensionDisplayName: "Search Web",
    });
  });

  it("attributes repo pi-extensions directories", () => {
    expect(extensionScopeFromPath("/Users/me/oppi/pi-extensions/ask/index.ts")).toEqual({
      extensionScopeId: "repo:ask",
      extensionDisplayName: "Ask",
    });
  });

  it("attributes Pi auto-discovered user extension files", () => {
    expect(extensionScopeFromPath("/Users/me/.pi/agent/extensions/searxng.ts")).toEqual({
      extensionScopeId: "ext:searxng",
      extensionDisplayName: "Searxng",
    });
  });

  it("attributes Pi auto-discovered user extension directories", () => {
    expect(extensionScopeFromPath("/Users/me/.pi/agent/extensions/hello/index.ts")).toEqual({
      extensionScopeId: "ext:hello",
      extensionDisplayName: "Hello",
    });
  });

  it("attributes helper files under a user extension directory", () => {
    expect(
      extensionScopeFromPath("/Users/me/.pi/agent/extensions/review-helper/session.ts"),
    ).toEqual({
      extensionScopeId: "ext:review-helper",
      extensionDisplayName: "Review Helper",
    });
  });

  it("attributes nested helpers under a user extension directory", () => {
    expect(
      extensionScopeFromPath("/Users/me/.pi/agent/extensions/review-helper/src/run.ts"),
    ).toEqual({
      extensionScopeId: "ext:review-helper",
      extensionDisplayName: "Review Helper",
    });
  });

  it("attributes project .pi/extensions entries", () => {
    expect(extensionScopeFromPath("/tmp/workspace/.pi/extensions/review-helper/index.js")).toEqual({
      extensionScopeId: "ext:review-helper",
      extensionDisplayName: "Review Helper",
    });
  });

  it("attributes nested helpers under project .pi/extensions", () => {
    expect(
      extensionScopeFromPath("/tmp/workspace/.pi/extensions/review-helper/src/run.ts"),
    ).toEqual({
      extensionScopeId: "ext:review-helper",
      extensionDisplayName: "Review Helper",
    });
  });

  it("attributes Pi git-installed packages by repo name", () => {
    expect(
      extensionScopeFromPath(
        "/Users/me/.pi/agent/git/github.com/acme/web-search/extensions/index.ts",
      ),
    ).toEqual({
      extensionScopeId: "git:web-search",
      extensionDisplayName: "Web Search",
    });
  });

  it("attributes project git-installed packages by repo name", () => {
    expect(
      extensionScopeFromPath("/tmp/workspace/.pi/git/gitlab.com/team/pi-tools/src/index.ts"),
    ).toEqual({
      extensionScopeId: "git:pi-tools",
      extensionDisplayName: "Tools",
    });
  });

  it("prefers node_modules over a surrounding git checkout", () => {
    expect(
      extensionScopeFromPath(
        "/Users/me/.pi/agent/git/github.com/acme/web-search/node_modules/lodash/index.js",
      ),
    ).toEqual({
      extensionScopeId: "npm:lodash",
      extensionDisplayName: "Lodash",
    });
  });

  it("decodes file URLs", () => {
    expect(extensionScopeFromPath("file:///Users/me/.pi/agent/extensions/hello.ts")).toEqual({
      extensionScopeId: "ext:hello",
      extensionDisplayName: "Hello",
    });
  });

  it("returns undefined for unrecognized paths", () => {
    expect(extensionScopeFromPath("/tmp/one-off-extension.ts")).toBeUndefined();
  });

  it("does not attribute unanchored server/extensions paths", () => {
    expect(extensionScopeFromPath("/Users/me/oppi/server/extensions/voice.ts")).toBeUndefined();
  });

  it("does not attribute unanchored git paths", () => {
    expect(extensionScopeFromPath("/tmp/src/git/github.com/acme/lib/index.ts")).toBeUndefined();
  });

  it("attributes helper files inside a git package by repo name", () => {
    expect(
      extensionScopeFromPath(
        "/Users/me/.pi/agent/git/github.com/acme/web-search/src/run.ts",
      ),
    ).toEqual({
      extensionScopeId: "git:web-search",
      extensionDisplayName: "Web Search",
    });
  });

  it("attributes files under PI_CODING_AGENT_DIR", () => {
    const previous = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = "/data/pi-agent";
    try {
      expect(extensionScopeFromPath("/data/pi-agent/extensions/hello/session.ts")).toEqual({
        extensionScopeId: "ext:hello",
        extensionDisplayName: "Hello",
      });
      expect(
        extensionScopeFromPath("/data/pi-agent/git/github.com/acme/web-search/src/run.ts"),
      ).toEqual({
        extensionScopeId: "git:web-search",
        extensionDisplayName: "Web Search",
      });
    } finally {
      if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previous;
    }
  });
});

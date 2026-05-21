import { describe, expect, it } from "vitest";

import { isQueryTokenAllowed } from "./http-auth.js";

describe("isQueryTokenAllowed", () => {
  const allowed = (method: string, rawUrl: string): boolean => {
    const url = new URL(rawUrl, "https://localhost");
    return isQueryTokenAllowed(method, url.pathname, url);
  };

  it("allows GET workspace raw file routes", () => {
    expect(allowed("GET", "/workspaces/ws-1/raw/video%20clip.mp4?token=secret")).toBe(true);
    expect(allowed("get", "/workspaces/ws-1/raw/nested/slide deck.pdf?token=secret")).toBe(true);
  });

  it("allows GET session attachment routes", () => {
    expect(
      allowed("GET", "/workspaces/ws-1/sessions/sess-1/attachments/att_123?token=secret"),
    ).toBe(true);
  });

  it("rejects non-GET methods", () => {
    expect(allowed("POST", "/workspaces/ws-1/raw/image.png?token=secret")).toBe(false);
    expect(
      allowed("DELETE", "/workspaces/ws-1/sessions/sess-1/attachments/att_123?token=secret"),
    ).toBe(false);
  });

  it("rejects legacy workspace file routes", () => {
    expect(allowed("GET", "/workspaces/ws-1/files/image.png")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/files/image.png?mode=browse")).toBe(false);
  });

  it("rejects workspace directory listing and index routes", () => {
    expect(allowed("GET", "/workspaces/ws-1/raw/folder/?token=secret")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/raw/folder%2F?token=secret")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/contents")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/contents/folder/")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/paths")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/file-index")).toBe(false);
  });

  it("rejects JSON and control routes", () => {
    expect(allowed("GET", "/workspaces/ws-1/uploads/upl_123")).toBe(false);
    expect(allowed("POST", "/workspaces/ws-1/uploads")).toBe(false);
    expect(allowed("GET", "/provider-auth/status")).toBe(false);
    expect(allowed("GET", "/policy/rules")).toBe(false);
    expect(allowed("GET", "/server/stats")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/sessions/sess-1/files?path=.env")).toBe(false);
    expect(allowed("GET", "/workspaces/ws-1/sessions/sess-1/touched-file?path=movie.mp4")).toBe(
      false,
    );
  });
});

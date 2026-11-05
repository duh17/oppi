import { describe, expect, it } from "vitest";

import { parseRelayOrigin } from "../src/push/relay-origin.js";

describe("parseRelayOrigin", () => {
  it("accepts https on any host", () => {
    expect(parseRelayOrigin("https://relay.example.com")).toEqual({
      ok: true,
      value: "https://relay.example.com",
    });
  });

  it.each(["http://localhost:8787", "http://127.0.0.1:8787", "http://[::1]:8787"])(
    "allows plain http on loopback: %s",
    (origin) => {
      expect(parseRelayOrigin(origin)).toEqual({ ok: true, value: origin });
    },
  );

  it("rejects plain http off loopback", () => {
    expect(parseRelayOrigin("http://relay.example.com")).toMatchObject({ ok: false });
    expect(parseRelayOrigin("http://[::2]:8787")).toMatchObject({ ok: false });
  });
});

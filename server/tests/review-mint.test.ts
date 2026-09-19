import { describe, expect, it } from "vitest";
import { InviteMintCoordinator, isPreviewUserAgent, redactMintPath } from "../src/review-mint.js";

describe("review mint coordinator", () => {
  it("does not mint for HEAD or preview user agents", async () => {
    let calls = 0;
    const coordinator = new InviteMintCoordinator(async () => {
      calls += 1;
      return { inviteURL: "oppi://connect?invite=secret", expiresAt: Date.now() + 90_000 };
    });

    expect(await coordinator.connect({ method: "HEAD", userAgent: "Mozilla/5.0" })).toEqual({
      status: "method_not_allowed",
    });
    expect(
      await coordinator.connect({
        method: "GET",
        userAgent: "facebookexternalhit/1.1",
      }),
    ).toEqual({ status: "preview" });
    expect(calls).toBe(0);
  });

  it("reuses one outstanding invite across overlapping opens", async () => {
    let calls = 0;
    const coordinator = new InviteMintCoordinator(async () => {
      calls += 1;
      await new Promise((resolve) => setTimeout(resolve, 20));
      return { inviteURL: `oppi://connect?invite=${calls}`, expiresAt: Date.now() + 90_000 };
    });

    const [first, second] = await Promise.all([
      coordinator.connect({ method: "GET", userAgent: "Mozilla/5.0" }),
      coordinator.connect({ method: "GET", userAgent: "Mozilla/5.0" }),
    ]);

    expect(first.status).toBe("minted");
    expect(second.status).toBe("reused");
    if (first.status === "minted" && second.status === "reused") {
      expect(second.invite.inviteURL).toBe(first.invite.inviteURL);
    }
    expect(calls).toBe(1);
  });

  it("mints a replacement on retry after revoke or explicit retry", async () => {
    let calls = 0;
    const coordinator = new InviteMintCoordinator(() => {
      calls += 1;
      return { inviteURL: `oppi://connect?invite=${calls}`, expiresAt: Date.now() + 90_000 };
    });

    const first = await coordinator.connect({ method: "GET" });
    coordinator.revokeOutstanding();
    const afterRevoke = await coordinator.connect({ method: "GET" });
    const retried = await coordinator.connect({ method: "GET", retry: true });

    expect(first.status).toBe("minted");
    expect(afterRevoke.status).toBe("minted");
    expect(retried.status).toBe("minted");
    expect(calls).toBe(3);
  });

  it("treats expired invites as spent", async () => {
    const now = 1_000_000;
    let calls = 0;
    const coordinator = new InviteMintCoordinator(() => {
      calls += 1;
      return { inviteURL: `oppi://connect?invite=${calls}`, expiresAt: now + 90_000 };
    });

    await coordinator.connect({ method: "GET", now });
    const expired = await coordinator.connect({ method: "GET", now: now + 91_000 });
    expect(expired.status).toBe("minted");
    expect(calls).toBe(2);
  });

  it("redacts the stable secret from paths and detects preview UAs", () => {
    expect(redactMintPath("/r/super-secret-value", "super-secret-value")).toBe("/r/<redacted>");
    expect(isPreviewUserAgent("Slackbot-LinkExpanding 1.0")).toBe(true);
    expect(isPreviewUserAgent("Mozilla/5.0 (iPhone; Oppi)")).toBe(false);
  });
});

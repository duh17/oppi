import { describe, expect, it } from "vitest";
import { request as httpRequest } from "node:http";
import {
  InviteMintCoordinator,
  isPreviewUserAgent,
  redactMintPath,
  type MintedInvite,
} from "../src/review-mint.js";
import { createReviewMintServer } from "../src/review-mint-server.js";

function minted(n: number, expiresAt = Date.now() + 90_000): MintedInvite {
  return {
    inviteURL: `oppi://connect?invite=${n}`,
    expiresAt,
    pairingToken: `pt_${n}`,
  };
}

describe("review mint coordinator", () => {
  it("does not mint for HEAD or preview user agents", async () => {
    let calls = 0;
    const coordinator = new InviteMintCoordinator(async () => {
      calls += 1;
      return minted(calls);
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
    let live: string | undefined;
    const coordinator = new InviteMintCoordinator(
      async () => {
        calls += 1;
        await new Promise((resolve) => setTimeout(resolve, 20));
        const invite = minted(calls);
        live = invite.pairingToken;
        return invite;
      },
      undefined,
      (token) => token === live,
    );

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
    let live: string | undefined;
    const coordinator = new InviteMintCoordinator(
      () => {
        calls += 1;
        const invite = minted(calls);
        live = invite.pairingToken;
        return invite;
      },
      () => {
        live = undefined;
      },
      (token) => token === live,
    );

    const first = await coordinator.connect({ method: "GET" });
    await coordinator.invalidateOutstanding();
    const afterRevoke = await coordinator.connect({ method: "GET" });
    const retried = await coordinator.connect({ method: "GET", retry: true });

    expect(first.status).toBe("minted");
    expect(afterRevoke.status).toBe("minted");
    expect(retried.status).toBe("minted");
    expect(calls).toBe(3);
  });

  it("remints after the outstanding pairing token is consumed", async () => {
    let calls = 0;
    let live: string | undefined;
    const coordinator = new InviteMintCoordinator(
      () => {
        calls += 1;
        const invite = minted(calls);
        live = invite.pairingToken;
        return invite;
      },
      undefined,
      (token) => token === live,
    );

    const first = await coordinator.connect({ method: "GET" });
    live = undefined;
    const afterConsume = await coordinator.connect({ method: "GET" });

    expect(first.status).toBe("minted");
    expect(afterConsume.status).toBe("minted");
    if (first.status === "minted" && afterConsume.status === "minted") {
      expect(afterConsume.invite.inviteURL).not.toBe(first.invite.inviteURL);
      expect(afterConsume.invite.pairingToken).not.toBe(first.invite.pairingToken);
    }
    expect(calls).toBe(2);
  });

  it("remints when an external pair replaces the persisted token", async () => {
    let calls = 0;
    let live: string | undefined;
    const coordinator = new InviteMintCoordinator(
      () => {
        calls += 1;
        const invite = minted(calls);
        live = invite.pairingToken;
        return invite;
      },
      undefined,
      (token) => token === live,
    );

    const first = await coordinator.connect({ method: "GET" });
    live = "pt_external_replacement";
    const afterReplace = await coordinator.connect({ method: "GET" });

    expect(first.status).toBe("minted");
    expect(afterReplace.status).toBe("minted");
    expect(calls).toBe(2);
  });

  it("invalidates outstanding invite without minting a discarded live invite", async () => {
    let mintCalls = 0;
    let invalidateCalls = 0;
    const coordinator = new InviteMintCoordinator(
      () => {
        mintCalls += 1;
        return minted(mintCalls);
      },
      () => {
        invalidateCalls += 1;
      },
    );

    await coordinator.connect({ method: "GET" });
    await coordinator.invalidateOutstanding();
    expect(mintCalls).toBe(1);
    expect(invalidateCalls).toBe(1);
  });

  it("treats expired invites as spent", async () => {
    const now = 1_000_000;
    let calls = 0;
    const coordinator = new InviteMintCoordinator(() => {
      calls += 1;
      return minted(calls, now + 90_000);
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

describe("review mint HTTP server", () => {
  const secret = "rp39-review-secret-value";

  it("refuses a non-loopback bind unless explicitly allowed", () => {
    expect(() =>
      createReviewMintServer({
        secret,
        listenHost: "0.0.0.0",
        mint: () => minted(1),
      }),
    ).toThrow(/non-loopback bind 0.0.0.0/);
    expect(() =>
      createReviewMintServer({
        secret,
        listenHost: "127.0.0.1",
        mint: () => minted(1),
      }),
    ).not.toThrow();
  });

  it("invalidates the outstanding invite without minting a replacement", async () => {
    let mintCalls = 0;
    let invalidateCalls = 0;
    const mintedServer = createReviewMintServer({
      secret,
      mint: () => {
        mintCalls += 1;
        return minted(mintCalls);
      },
      invalidate: () => {
        invalidateCalls += 1;
      },
    });
    const bound = await mintedServer.listen();
    try {
      const first = await mintRequest(bound.port, `/r/${secret}`);
      expect(first.status).toBe(302);
      expect(first.location).toBe("oppi://connect?invite=1");
      const revoked = await mintRequest(bound.port, `/r/${secret}/invalidate-invite`, { method: "POST" });
      expect(revoked.status).toBe(204);
      expect(mintCalls).toBe(1);
      expect(invalidateCalls).toBe(1);
    } finally {
      await mintedServer.close();
    }
  });

  it("remints after consume and keeps listening after a mint failure", async () => {
    let mintCalls = 0;
    let live: string | undefined;
    let failNext = true;
    const mintedServer = createReviewMintServer({
      secret,
      mint: () => {
        if (failNext) {
          failNext = false;
          throw new Error("forced mint failure");
        }
        mintCalls += 1;
        const invite = minted(mintCalls);
        live = invite.pairingToken;
        return invite;
      },
      isLiveToken: (token) => token === live,
    });
    const bound = await mintedServer.listen();
    try {
      const failed = await mintRequest(bound.port, `/r/${secret}`);
      expect(failed.status).toBe(503);
      expect(failed.cacheControl).toBe("no-store");
      expect(failed.location).toBeUndefined();
      expect(failed.body).toBe("");
      expect(failed.body).not.toContain("forced mint failure");
      expect(failed.body).not.toContain("pt_");
      expect(failed.body).not.toContain("oppi://");

      const first = await mintRequest(bound.port, `/r/${secret}`);
      expect(first.status).toBe(302);
      expect(first.location).toBe("oppi://connect?invite=1");
      expect(first.cacheControl).toBe("no-store");

      const reused = await mintRequest(bound.port, `/r/${secret}`);
      expect(reused.status).toBe(302);
      expect(reused.location).toBe(first.location);

      live = undefined;
      const afterConsume = await mintRequest(bound.port, `/r/${secret}`);
      expect(afterConsume.status).toBe(302);
      expect(afterConsume.location).toBe("oppi://connect?invite=2");

      const retried = await mintRequest(bound.port, `/r/${secret}?retry=1`);
      expect(retried.status).toBe(302);
      expect(retried.location).toBe("oppi://connect?invite=3");
      expect(mintCalls).toBe(3);
    } finally {
      await mintedServer.close();
    }
  });
});

function mintRequest(
  port: number,
  path: string,
  options: { method?: string } = {},
): Promise<{ status: number; location?: string; cacheControl?: string; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method: options.method ?? "GET",
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(chunk as Buffer));
        res.on("end", () => {
          resolve({
            status: res.statusCode ?? 0,
            location: typeof res.headers.location === "string" ? res.headers.location : undefined,
            cacheControl:
              typeof res.headers["cache-control"] === "string"
                ? res.headers["cache-control"]
                : undefined,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

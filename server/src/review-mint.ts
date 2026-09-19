/**
 * App Review mint coordinator: one outstanding signed invite, reuse during its
 * TTL, no preview mint, and a serialized retry path.
 *
 * The HTTP sidecar calls this. It never logs invite URLs or secret path suffixes.
 */

export type MintedInvite = {
  inviteURL: string;
  expiresAt: number;
  /** Outstanding pairing token. Never log this value. */
  pairingToken: string;
};

export type MintConnectInput = {
  method: string;
  userAgent?: string;
  retry?: boolean;
  now?: number;
  enabled?: boolean;
};

export type MintConnectResult =
  | { status: "minted" | "reused"; invite: MintedInvite }
  | { status: "preview" | "disabled" | "method_not_allowed" };

const PREVIEW_UA =
  /facebookexternalhit|twitterbot|slackbot|linkedinbot|whatsapp|telegrambot|discordbot|applebot|bingpreview|googlebot|preview/i;

export function isPreviewUserAgent(userAgent: string | undefined): boolean {
  if (!userAgent) return false;
  return PREVIEW_UA.test(userAgent);
}

export function redactMintPath(pathname: string, secret: string): string {
  if (!secret) return pathname;
  return pathname.split(secret).join("<redacted>");
}

export class InviteMintCoordinator {
  private outstanding: MintedInvite | null = null;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly mint: () => Promise<MintedInvite> | MintedInvite,
    private readonly invalidate?: () => Promise<void> | void,
    /** True when this pairing token is still the persisted outstanding token. */
    private readonly isLiveToken?: (pairingToken: string) => boolean | Promise<boolean>,
  ) {}

  async connect(input: MintConnectInput): Promise<MintConnectResult> {
    return this.serialized(() => this.connectLocked(input));
  }

  /** Drop a cached invite without minting a replacement. Next GET remints. */
  async invalidateOutstanding(): Promise<void> {
    await this.serialized(async () => {
      this.outstanding = null;
      await this.invalidate?.();
    });
  }

  private async connectLocked(input: MintConnectInput): Promise<MintConnectResult> {
    const method = input.method.toUpperCase();
    if (method === "HEAD" || method === "OPTIONS") {
      return { status: "method_not_allowed" };
    }
    if (method !== "GET") {
      return { status: "method_not_allowed" };
    }
    if (input.enabled === false) {
      return { status: "disabled" };
    }
    if (isPreviewUserAgent(input.userAgent)) {
      return { status: "preview" };
    }

    const now = input.now ?? Date.now();
    if (!input.retry && this.outstanding && this.outstanding.expiresAt > now) {
      const live = this.isLiveToken ? await this.isLiveToken(this.outstanding.pairingToken) : true;
      if (live) {
        return { status: "reused", invite: this.outstanding };
      }
    }

    const minted = await this.mint();
    this.outstanding = minted;
    return { status: "minted", invite: minted };
  }

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const run = this.chain.then(work, work);
    this.chain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }
}

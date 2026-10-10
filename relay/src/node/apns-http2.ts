/** APNs senders for the Node adapter: HTTP/2 to Apple (or a mock), or capture to a file. */

import { appendFileSync } from "node:fs";
import { connect, type ClientHttp2Session } from "node:http2";
import {
  APNS_ORIGINS,
  ApnsProviderToken,
  type ApnsCredentials,
  type ApnsRequest,
  type ApnsResult,
  type ApnsSender,
} from "../core/apns.js";
import type { ApnsEnvironment } from "../core/store.js";

const REQUEST_TIMEOUT_MS = 10_000;

/**
 * One persistent HTTP/2 connection per environment. `origins` overrides Apple's hosts, for
 * example an h2c mock at `http://127.0.0.1:port` in tests.
 */
export class Http2ApnsSender implements ApnsSender {
  private readonly sessions = new Map<ApnsEnvironment, ClientHttp2Session>();
  private readonly providerToken: ApnsProviderToken;

  constructor(
    credentials: ApnsCredentials,
    private readonly origins: Record<ApnsEnvironment, string> = APNS_ORIGINS,
  ) {
    this.providerToken = new ApnsProviderToken(credentials);
  }

  private session(environment: ApnsEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = connect(this.origins[environment]);
    const forget = (): void => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on("error", forget);
    session.on("goaway", forget);
    session.on("close", forget);
    session.unref();
    this.sessions.set(environment, session);
    return session;
  }

  async send(request: ApnsRequest): Promise<ApnsResult> {
    const authorization = `bearer ${await this.providerToken.get()}`;
    const session = this.session(request.environment);
    return new Promise<ApnsResult>((resolve, reject) => {
      const stream = session.request({
        ":method": "POST",
        ":path": `/3/device/${request.deviceToken}`,
        authorization,
        "content-type": "application/json",
        ...request.headers,
      });
      stream.setTimeout(REQUEST_TIMEOUT_MS, () => stream.close());
      let status = 0;
      let body = "";
      stream.on("response", (headers) => {
        status = Number(headers[":status"] ?? 0);
      });
      stream.setEncoding("utf8");
      stream.on("data", (chunk: string) => {
        body += chunk;
      });
      stream.on("end", () => {
        if (status === 0) {
          reject(new Error("apns: no response"));
          return;
        }
        let reason: string | undefined;
        try {
          const parsed = JSON.parse(body) as { reason?: unknown };
          if (typeof parsed.reason === "string") reason = parsed.reason;
        } catch {
          // An empty body is a success.
        }
        resolve(reason === undefined ? { status } : { status, reason });
      });
      stream.on("error", reject);
      stream.end(request.payload);
    });
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }
}

/**
 * Capture mode: write each exact APNs request (path, `apns-*` headers, payload) as one JSON
 * line instead of contacting Apple, and answer as APNs `200`. Shows what a relay would send.
 */
export class CaptureApnsSender implements ApnsSender {
  constructor(private readonly capturePath: string) {}

  async send(request: ApnsRequest): Promise<ApnsResult> {
    const line = JSON.stringify({
      host: new URL(APNS_ORIGINS[request.environment]).host,
      path: `/3/device/${request.deviceToken}`,
      headers: request.headers,
      payload: request.payload,
    });
    appendFileSync(this.capturePath, `${line}\n`, { mode: 0o600 });
    return { status: 200 };
  }
}

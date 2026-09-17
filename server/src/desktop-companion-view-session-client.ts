/**
 * Fetch companion view-session metadata over the companion-owned Unix socket.
 * JSON only. Never starts a capture or reads PNG stills.
 */

import { request as httpRequest, type IncomingHttpHeaders, type IncomingMessage } from "node:http";

import { desktopCompanionOwnerSocketPath } from "./desktop-companion-still-client.js";

const VIEW_SESSION_CAPTION = "View session\u2014not live delivery";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIMESTAMP_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

export const DESKTOP_COMPANION_VIEW_SESSION_TIMEOUT_MS = 5_000;
export const DESKTOP_COMPANION_VIEW_SESSION_MAX_BYTES = 16 * 1024;
export const DESKTOP_COMPANION_VIEW_SESSION_PATH = "/view/session";
export const DESKTOP_COMPANION_VIEW_DEVICE_ID_HEADER = "X-Oppi-Device-ID";
export const DESKTOP_COMPANION_VIEW_DEVICE_NAME_HEADER = "X-Oppi-Device-Name";

export type DesktopCompanionViewSessionErrorCode =
  | "missing_device_id"
  | "unavailable"
  | "not_bound"
  | "companion_unavailable"
  | "malformed_session";

export class DesktopCompanionViewSessionError extends Error {
  constructor(
    message: string,
    readonly code: DesktopCompanionViewSessionErrorCode,
  ) {
    super(message);
    this.name = "DesktopCompanionViewSessionError";
  }
}

export type DesktopCompanionViewSession = {
  grantId: string;
  capability: "view";
  deviceId: string;
  expiresAt: string;
  caption: string;
};

export type DesktopCompanionViewSessionClientOptions = {
  runtimeRoot?: string;
  timeoutMs?: number;
  maxBytes?: number;
};

export class DesktopCompanionViewSessionClient {
  readonly socketPath: string;
  private readonly timeoutMs: number;
  private readonly maxBytes: number;

  constructor(options: DesktopCompanionViewSessionClientOptions = {}) {
    this.socketPath = desktopCompanionOwnerSocketPath(options.runtimeRoot);
    this.timeoutMs =
      typeof options.timeoutMs === "number" &&
      Number.isFinite(options.timeoutMs) &&
      options.timeoutMs > 0
        ? options.timeoutMs
        : DESKTOP_COMPANION_VIEW_SESSION_TIMEOUT_MS;
    this.maxBytes =
      typeof options.maxBytes === "number" &&
      Number.isFinite(options.maxBytes) &&
      options.maxBytes > 0
        ? options.maxBytes
        : DESKTOP_COMPANION_VIEW_SESSION_MAX_BYTES;
  }

  async fetchViewSession(input: {
    deviceId: string;
    deviceName?: string;
    signal?: AbortSignal;
  }): Promise<DesktopCompanionViewSession> {
    const deviceId = input.deviceId.trim();
    if (!deviceId) {
      throw new DesktopCompanionViewSessionError(
        "Desktop view session device ID is required",
        "missing_device_id",
      );
    }
    const deviceName = sanitizeDeviceName(input.deviceName);
    const timeoutSignal = AbortSignal.timeout(this.timeoutMs);
    const signal = input.signal ? AbortSignal.any([input.signal, timeoutSignal]) : timeoutSignal;

    return new Promise<DesktopCompanionViewSession>((resolve, reject) => {
      let settled = false;
      let req: ReturnType<typeof httpRequest> | undefined;

      const succeed = (session: DesktopCompanionViewSession): void => {
        if (settled) return;
        settled = true;
        resolve(session);
      };

      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        req?.destroy();
        reject(error);
      };

      try {
        if (input.signal?.aborted) {
          fail(createAbortError(input.signal));
          return;
        }
        const headers: Record<string, string> = {
          [DESKTOP_COMPANION_VIEW_DEVICE_ID_HEADER]: deviceId,
        };
        if (deviceName) {
          headers[DESKTOP_COMPANION_VIEW_DEVICE_NAME_HEADER] = deviceName;
        }
        req = httpRequest(
          {
            socketPath: this.socketPath,
            path: DESKTOP_COMPANION_VIEW_SESSION_PATH,
            method: "GET",
            agent: false as const,
            signal,
            headers,
          },
          (res) => this.handleResponse(res, deviceId, input.signal, succeed, fail),
        );
        req.on("error", (error: unknown) => {
          if (input.signal?.aborted) {
            fail(createAbortError(input.signal));
            return;
          }
          if (timeoutSignal.aborted || isAbortError(error)) {
            fail(
              new DesktopCompanionViewSessionError(
                "Desktop companion did not answer",
                "companion_unavailable",
              ),
            );
            return;
          }
          fail(
            new DesktopCompanionViewSessionError(
              "Desktop companion is unavailable",
              "companion_unavailable",
            ),
          );
        });
        req.end();
      } catch {
        fail(
          new DesktopCompanionViewSessionError(
            "Desktop companion is unavailable",
            "companion_unavailable",
          ),
        );
      }
    });
  }

  private handleResponse(
    res: IncomingMessage,
    expectedDeviceId: string,
    callerSignal: AbortSignal | undefined,
    succeed: (session: DesktopCompanionViewSession) => void,
    fail: (error: Error) => void,
  ): void {
    const status = res.statusCode ?? 0;
    const chunks: Buffer[] = [];
    let total = 0;
    let oversized = false;

    res.on("data", (chunk: Buffer | string) => {
      if (oversized) return;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > this.maxBytes) {
        oversized = true;
        fail(
          new DesktopCompanionViewSessionError(
            "Desktop view session response is malformed",
            "malformed_session",
          ),
        );
        res.destroy();
        return;
      }
      chunks.push(buf);
    });

    res.on("aborted", () => {
      if (callerSignal?.aborted) {
        fail(createAbortError(callerSignal));
        return;
      }
      fail(
        new DesktopCompanionViewSessionError(
          "Desktop view session response is malformed",
          "malformed_session",
        ),
      );
    });

    res.on("error", () => {
      fail(
        new DesktopCompanionViewSessionError(
          "Desktop view session response is malformed",
          "malformed_session",
        ),
      );
    });

    res.on("end", () => {
      if (oversized) return;
      const body = Buffer.concat(chunks, total);
      if (status === 400) {
        fail(
          new DesktopCompanionViewSessionError(
            "Desktop view session device ID is required",
            "missing_device_id",
          ),
        );
        return;
      }
      if (status === 403) {
        const text = body.toString("utf8").trim();
        if (text === "view session not granted") {
          fail(
            new DesktopCompanionViewSessionError(
              "Desktop view session is not granted to this device",
              "not_bound",
            ),
          );
          return;
        }
        fail(
          new DesktopCompanionViewSessionError(
            "Desktop view session is not available",
            "unavailable",
          ),
        );
        return;
      }
      if (status !== 200) {
        fail(
          new DesktopCompanionViewSessionError(
            "Desktop companion is unavailable",
            "companion_unavailable",
          ),
        );
        return;
      }
      try {
        succeed(parseViewSession(expectedDeviceId, res.headers, body));
      } catch (error: unknown) {
        fail(
          error instanceof DesktopCompanionViewSessionError
            ? error
            : new DesktopCompanionViewSessionError(
                "Desktop view session response is malformed",
                "malformed_session",
              ),
        );
      }
    });
  }
}

function parseViewSession(
  expectedDeviceId: string,
  headers: IncomingHttpHeaders,
  body: Buffer,
): DesktopCompanionViewSession {
  const contentType = mediaType(readHeader(headers, "content-type"));
  const cacheControl = readHeader(headers, "cache-control")?.toLowerCase();
  if (contentType !== "application/json" || cacheControl !== "no-store") {
    throw new DesktopCompanionViewSessionError(
      "Desktop view session response is malformed",
      "malformed_session",
    );
  }
  if (body.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    throw new DesktopCompanionViewSessionError(
      "Desktop view session response is malformed",
      "malformed_session",
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch {
    throw new DesktopCompanionViewSessionError(
      "Desktop view session response is malformed",
      "malformed_session",
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new DesktopCompanionViewSessionError(
      "Desktop view session response is malformed",
      "malformed_session",
    );
  }
  const record = parsed as Record<string, unknown>;
  const grantId = typeof record.grantId === "string" ? record.grantId : undefined;
  const capability = record.capability;
  const deviceId = typeof record.deviceId === "string" ? record.deviceId : undefined;
  const expiresAt = typeof record.expiresAt === "string" ? record.expiresAt : undefined;
  const caption = typeof record.caption === "string" ? record.caption : undefined;
  if (
    !grantId ||
    !UUID_RE.test(grantId) ||
    capability !== "view" ||
    !deviceId ||
    deviceId !== expectedDeviceId ||
    !expiresAt ||
    !ISO_TIMESTAMP_RE.test(expiresAt) ||
    !Number.isFinite(Date.parse(expiresAt)) ||
    caption !== VIEW_SESSION_CAPTION
  ) {
    throw new DesktopCompanionViewSessionError(
      "Desktop view session response is malformed",
      "malformed_session",
    );
  }
  return {
    grantId,
    capability: "view",
    deviceId,
    expiresAt,
    caption: VIEW_SESSION_CAPTION,
  };
}

function sanitizeDeviceName(name: string | undefined): string | undefined {
  if (typeof name !== "string") return undefined;
  const collapsed = name.replace(/[\r\n]/g, " ").trim();
  if (!collapsed) return undefined;
  for (let index = 0; index < collapsed.length; index += 1) {
    // Node writes headers as Latin-1; companion UTF-8-decodes the request, so é (0xE9) breaks parse.
    if (collapsed.charCodeAt(index) > 127) return undefined;
  }
  return collapsed.length <= 120 ? collapsed : collapsed.slice(0, 120);
}

function mediaType(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return value.split(";", 1)[0]?.trim().toLowerCase();
}

function readHeader(headers: IncomingHttpHeaders, name: string): string | undefined {
  const value = headers[name];
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function createAbortError(signal?: AbortSignal): Error {
  const reason = signal?.reason;
  if (reason instanceof Error && reason.name === "AbortError") return reason;
  const error = new Error("Operation aborted");
  error.name = "AbortError";
  return error;
}

function isAbortError(error: unknown): boolean {
  return (
    (error instanceof Error && error.name === "AbortError") ||
    (typeof error === "object" &&
      error !== null &&
      "name" in error &&
      (error as { name?: unknown }).name === "AbortError")
  );
}

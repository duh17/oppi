/**
 * Fetch one shared companion still over the companion-owned Unix socket.
 * Companion remains capture authority. This client never starts a capture.
 */

import { request as httpRequest, type IncomingHttpHeaders, type IncomingMessage } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

const MAX_PORTABLE_UNIX_SOCKET_PATH_BYTES = 100;
const RUNTIME_DIRECTORY_NAME = "run";
const SOCKET_NAME = "companion.sock";
const APP_SUPPORT_DIRECTORY_NAME = "OppiDesktopCompanion";
const STILL_CAPTION = "Still\u2014not live";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIMESTAMP_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export const DESKTOP_COMPANION_STILL_TIMEOUT_MS = 5_000;
export const DESKTOP_COMPANION_STILL_MAX_BYTES = 16 * 1024 * 1024;
export const DESKTOP_COMPANION_STILL_MAX_CONCURRENT = 2;

export type DesktopCompanionStillErrorCode =
  | "invalid_capture_id"
  | "sharing_disabled"
  | "stale_capture"
  | "companion_unavailable"
  | "malformed_still"
  | "oversized_still"
  | "truncated_still";

export class DesktopCompanionStillError extends Error {
  constructor(
    message: string,
    readonly code: DesktopCompanionStillErrorCode,
  ) {
    super(message);
    this.name = "DesktopCompanionStillError";
  }
}

export type DesktopCompanionStill = {
  captureId: string;
  surface: { windowId: number; title: string };
  capturedAt: string;
  width: number;
  height: number;
  caption: string;
  png: Buffer;
};

export type DesktopCompanionStillClientOptions = {
  runtimeRoot?: string;
  timeoutMs?: number;
  maxBytes?: number;
  maxConcurrent?: number;
};

export function desktopCompanionOwnerSocketPath(runtimeRoot?: string): string {
  const root =
    typeof runtimeRoot === "string" && runtimeRoot.length > 0
      ? runtimeRoot
      : join(homedir(), "Library", "Application Support", APP_SUPPORT_DIRECTORY_NAME);
  const preferred = join(root, RUNTIME_DIRECTORY_NAME, SOCKET_NAME);
  if (Buffer.byteLength(preferred) <= MAX_PORTABLE_UNIX_SOCKET_PATH_BYTES) {
    return preferred;
  }
  const uid = process.getuid?.() ?? "user";
  return join("/tmp", `oppi-desktop-${uid}`, SOCKET_NAME);
}

export class DesktopCompanionStillClient {
  readonly socketPath: string;
  private readonly timeoutMs: number;
  private readonly maxBytes: number;
  private readonly maxConcurrent: number;
  private inFlight = 0;

  constructor(options: DesktopCompanionStillClientOptions = {}) {
    this.socketPath = desktopCompanionOwnerSocketPath(options.runtimeRoot);
    this.timeoutMs = positiveBound(options.timeoutMs, DESKTOP_COMPANION_STILL_TIMEOUT_MS);
    this.maxBytes = positiveBound(options.maxBytes, DESKTOP_COMPANION_STILL_MAX_BYTES);
    this.maxConcurrent = positiveBound(
      options.maxConcurrent,
      DESKTOP_COMPANION_STILL_MAX_CONCURRENT,
    );
  }

  async fetchStill(
    captureId: string,
    options: { signal?: AbortSignal } = {},
  ): Promise<DesktopCompanionStill> {
    if (!isUuid(captureId)) {
      throw new DesktopCompanionStillError(
        "Desktop still capture ID is invalid",
        "invalid_capture_id",
      );
    }
    return this.fetchFromCompanion(`/still/${captureId}`, captureId, options.signal);
  }

  async fetchCurrentStill(options: { signal?: AbortSignal } = {}): Promise<DesktopCompanionStill> {
    return this.fetchFromCompanion("/still/current", undefined, options.signal);
  }

  private async fetchFromCompanion(
    path: string,
    expectedCaptureId: string | undefined,
    signal: AbortSignal | undefined,
  ): Promise<DesktopCompanionStill> {
    throwIfAborted(signal);
    if (this.inFlight >= this.maxConcurrent) {
      throw new DesktopCompanionStillError(
        "Desktop still fetch is already in flight",
        "companion_unavailable",
      );
    }
    this.inFlight += 1;
    try {
      throwIfAborted(signal);
      return await this.requestStill(path, expectedCaptureId, signal);
    } finally {
      this.inFlight -= 1;
    }
  }

  private requestStill(
    path: string,
    expectedCaptureId: string | undefined,
    callerSignal: AbortSignal | undefined,
  ): Promise<DesktopCompanionStill> {
    const timeoutSignal = AbortSignal.timeout(this.timeoutMs);
    const signal = callerSignal ? AbortSignal.any([callerSignal, timeoutSignal]) : timeoutSignal;

    return new Promise<DesktopCompanionStill>((resolve, reject) => {
      let settled = false;
      let sawResponse = false;
      let req: ReturnType<typeof httpRequest> | undefined;

      const succeed = (still: DesktopCompanionStill): void => {
        if (settled) return;
        settled = true;
        resolve(still);
      };

      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        req?.destroy();
        reject(error);
      };

      const mapTransportError = (error: unknown): Error => {
        if (callerSignal?.aborted) return createAbortError(callerSignal);
        if (timeoutSignal.aborted || isAbortError(error)) {
          return new DesktopCompanionStillError(
            "Desktop companion did not answer",
            "companion_unavailable",
          );
        }
        if (sawResponse) {
          return new DesktopCompanionStillError(
            "Desktop still response was truncated",
            "truncated_still",
          );
        }
        return new DesktopCompanionStillError(
          "Desktop companion is unavailable",
          "companion_unavailable",
        );
      };

      try {
        throwIfAborted(callerSignal);
        req = httpRequest(
          {
            socketPath: this.socketPath,
            path,
            method: "GET",
            agent: false as const,
            signal,
          },
          (res) =>
            this.handleResponse(res, expectedCaptureId, callerSignal, succeed, fail, () => {
              sawResponse = true;
            }),
        );
        req.on("error", (error: unknown) => fail(mapTransportError(error)));
        req.end();
      } catch (error: unknown) {
        fail(mapTransportError(error));
      }
    });
  }

  private handleResponse(
    res: IncomingMessage,
    expectedCaptureId: string | undefined,
    callerSignal: AbortSignal | undefined,
    succeed: (still: DesktopCompanionStill) => void,
    fail: (error: Error) => void,
    markSawResponse: () => void,
  ): void {
    markSawResponse();
    const status = res.statusCode ?? 0;
    if (status === 403) {
      res.resume();
      fail(new DesktopCompanionStillError("Desktop still sharing is disabled", "sharing_disabled"));
      return;
    }
    if (status === 404) {
      res.resume();
      fail(new DesktopCompanionStillError("Desktop still capture ID is stale", "stale_capture"));
      return;
    }
    if (status !== 200) {
      res.resume();
      fail(
        status >= 500
          ? new DesktopCompanionStillError(
              "Desktop companion is unavailable",
              "companion_unavailable",
            )
          : new DesktopCompanionStillError(
              "Desktop still response is malformed",
              "malformed_still",
            ),
      );
      return;
    }

    const declaredLength = parseNonNegativeInteger(readHeader(res.headers, "content-length"));
    if (declaredLength === undefined) {
      res.resume();
      fail(
        new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still"),
      );
      return;
    }
    if (declaredLength > this.maxBytes) {
      res.resume();
      fail(new DesktopCompanionStillError("Desktop still is oversized", "oversized_still"));
      return;
    }

    const chunks: Buffer[] = [];
    let total = 0;
    let oversized = false;

    res.on("data", (chunk: Buffer | string) => {
      if (oversized) return;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > this.maxBytes) {
        oversized = true;
        fail(new DesktopCompanionStillError("Desktop still is oversized", "oversized_still"));
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
        new DesktopCompanionStillError("Desktop still response was truncated", "truncated_still"),
      );
    });

    res.on("error", (error: unknown) => {
      fail(
        new DesktopCompanionStillError(
          error instanceof Error ? error.message : "Desktop still response was truncated",
          "truncated_still",
        ),
      );
    });

    res.on("end", () => {
      if (oversized) return;
      if (total < declaredLength) {
        fail(
          new DesktopCompanionStillError("Desktop still response was truncated", "truncated_still"),
        );
        return;
      }
      try {
        succeed(
          parseStill(expectedCaptureId, res.headers, Buffer.concat(chunks, total), this.maxBytes),
        );
      } catch (error: unknown) {
        fail(
          error instanceof DesktopCompanionStillError
            ? error
            : new DesktopCompanionStillError(
                "Desktop still response is malformed",
                "malformed_still",
              ),
        );
      }
    });
  }
}

function parseStill(
  requestedCaptureId: string | undefined,
  headers: IncomingHttpHeaders,
  png: Buffer,
  maxBytes: number,
): DesktopCompanionStill {
  if (png.length > maxBytes) {
    throw new DesktopCompanionStillError("Desktop still is oversized", "oversized_still");
  }

  const contentType = mediaType(readHeader(headers, "content-type"));
  const cacheControl = readHeader(headers, "cache-control")?.toLowerCase();
  const captureId = readHeader(headers, "x-oppi-capture-id");
  const windowIdRaw = readHeader(headers, "x-oppi-surface-window-id");
  const title = readHeader(headers, "x-oppi-surface-title");
  const capturedAt = readHeader(headers, "x-oppi-captured-at");
  const widthRaw = readHeader(headers, "x-oppi-width");
  const heightRaw = readHeader(headers, "x-oppi-height");
  const caption = readHeader(headers, "x-oppi-caption");

  if (contentType !== "image/png" || cacheControl !== "no-store") {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }
  if (
    !captureId ||
    !isUuid(captureId) ||
    (requestedCaptureId !== undefined &&
      captureId.toLowerCase() !== requestedCaptureId.toLowerCase())
  ) {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }
  const windowId = parseWindowId(windowIdRaw);
  const headerWidth = parseDimension(widthRaw);
  const headerHeight = parseDimension(heightRaw);
  if (
    windowId === undefined ||
    !title ||
    !capturedAt ||
    !isIsoTimestamp(capturedAt) ||
    headerWidth === undefined ||
    headerHeight === undefined ||
    caption !== STILL_CAPTION
  ) {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }

  const dimensions = inspectPng(png);
  if (dimensions.width !== headerWidth || dimensions.height !== headerHeight) {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }

  return {
    captureId,
    surface: { windowId, title },
    capturedAt,
    width: dimensions.width,
    height: dimensions.height,
    caption: STILL_CAPTION,
    png,
  };
}

function inspectPng(bytes: Buffer): { width: number; height: number } {
  if (bytes.length < 8 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }

  let offset = 8;
  let width = 0;
  let height = 0;
  let sawIHDR = false;
  let sawIEND = false;

  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString("ascii", offset + 4, offset + 8);
    const dataStart = offset + 8;
    const next = dataStart + length + 4;
    if (!Number.isSafeInteger(length) || length < 0 || next > bytes.length) {
      throw new DesktopCompanionStillError(
        "Desktop still response was truncated",
        "truncated_still",
      );
    }
    if (type === "IHDR") {
      if (length !== 13) {
        throw new DesktopCompanionStillError(
          "Desktop still response is malformed",
          "malformed_still",
        );
      }
      width = bytes.readUInt32BE(dataStart);
      height = bytes.readUInt32BE(dataStart + 4);
      sawIHDR = true;
    }
    if (type === "IEND") {
      sawIEND = true;
      break;
    }
    offset = next;
  }

  if (!sawIEND) {
    throw new DesktopCompanionStillError("Desktop still response was truncated", "truncated_still");
  }
  if (!sawIHDR || width < 1 || height < 1) {
    throw new DesktopCompanionStillError("Desktop still response is malformed", "malformed_still");
  }
  return { width, height };
}

function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

function isIsoTimestamp(value: string): boolean {
  return ISO_TIMESTAMP_RE.test(value) && Number.isFinite(Date.parse(value));
}

function mediaType(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return value.split(";", 1)[0]?.trim().toLowerCase();
}

function readHeader(headers: IncomingHttpHeaders, name: string): string | undefined {
  const value = headers[name];
  if (typeof value !== "string") return undefined;
  // Companion writes UTF-8 header bytes; Node exposes them as latin1.
  const trimmed = Buffer.from(value, "latin1").toString("utf8").trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function parseNonNegativeInteger(raw: string | undefined): number | undefined {
  if (raw === undefined || !/^\d+$/.test(raw)) return undefined;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : undefined;
}

function parseDimension(raw: string | undefined): number | undefined {
  const value = parseNonNegativeInteger(raw);
  return value !== undefined && value >= 1 ? value : undefined;
}

function parseWindowId(raw: string | undefined): number | undefined {
  const value = parseNonNegativeInteger(raw);
  return value !== undefined && value <= 0xffffffff ? value : undefined;
}

function positiveBound(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw createAbortError(signal);
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

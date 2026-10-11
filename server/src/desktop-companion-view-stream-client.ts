/**
 * Companion `/view/stream` HTTP upgrade. Bidirectional length-prefixed frames.
 * JSON control stays on this hop; media payloads are phone-wire bytes.
 */

import { request as httpRequest } from "node:http";
import type { Socket } from "node:net";

import { desktopCompanionOwnerSocketPath } from "./desktop-companion-still-client.js";
import { DESKTOP_COMPANION_VIEW_DEVICE_ID_HEADER } from "./desktop-companion-view-session-client.js";
import {
  DESKTOP_VIEW_COMPANION_PATH,
  DESKTOP_VIEW_COMPANION_UPGRADE,
  DESKTOP_VIEW_ERROR,
} from "./types/protocol.js";

export class DesktopCompanionViewStreamError extends Error {
  constructor(
    message: string,
    readonly code: number,
  ) {
    super(message);
    this.name = "DesktopCompanionViewStreamError";
  }
}

export type DesktopCompanionViewStream = {
  socket: Socket;
  leftover: Buffer;
};

export type DesktopCompanionViewStreamConnectInput = {
  deviceId: string;
  signal?: AbortSignal;
};

export class DesktopCompanionViewStreamClient {
  readonly socketPath: string;

  constructor(options: { runtimeRoot?: string } = {}) {
    this.socketPath = desktopCompanionOwnerSocketPath(options.runtimeRoot);
  }

  connect(input: DesktopCompanionViewStreamConnectInput): Promise<DesktopCompanionViewStream> {
    const deviceId = input.deviceId.trim();
    if (!deviceId) {
      return Promise.reject(
        new DesktopCompanionViewStreamError(
          "Desktop view stream device ID is required",
          DESKTOP_VIEW_ERROR.protocolFatal,
        ),
      );
    }

    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        reject(error);
      };
      const succeed = (stream: DesktopCompanionViewStream): void => {
        if (settled) return;
        settled = true;
        resolve(stream);
      };

      if (input.signal?.aborted) {
        fail(createAbortError(input.signal));
        return;
      }

      const headers: Record<string, string> = {
        Connection: "Upgrade",
        Upgrade: DESKTOP_VIEW_COMPANION_UPGRADE,
        [DESKTOP_COMPANION_VIEW_DEVICE_ID_HEADER]: deviceId,
      };

      const req = httpRequest({
        socketPath: this.socketPath,
        path: DESKTOP_VIEW_COMPANION_PATH,
        method: "GET",
        agent: false as const,
        signal: input.signal,
        headers,
      });

      req.on("upgrade", (res, socket, head) => {
        if (res.statusCode !== 101) {
          socket.destroy();
          fail(
            new DesktopCompanionViewStreamError(
              "Desktop companion stream upgrade failed",
              DESKTOP_VIEW_ERROR.companionUnavailable,
            ),
          );
          return;
        }
        succeed({
          socket,
          leftover: Buffer.isBuffer(head) ? head : Buffer.alloc(0),
        });
      });

      req.on("response", (res) => {
        const status = res.statusCode ?? 0;
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer | string) => {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        });
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          fail(mapCompanionHttpError(status, body));
        });
        res.on("error", () => {
          fail(
            new DesktopCompanionViewStreamError(
              "Desktop companion is unavailable",
              DESKTOP_VIEW_ERROR.companionUnavailable,
            ),
          );
        });
      });

      req.on("error", (error: unknown) => {
        if (input.signal?.aborted) {
          fail(createAbortError(input.signal));
          return;
        }
        fail(
          new DesktopCompanionViewStreamError(
            error instanceof Error ? error.message : "Desktop companion is unavailable",
            DESKTOP_VIEW_ERROR.companionUnavailable,
          ),
        );
      });

      req.end();
    });
  }
}

function mapCompanionHttpError(status: number, body: string): DesktopCompanionViewStreamError {
  const text = body.trim();
  if (status === 400) {
    return new DesktopCompanionViewStreamError(
      "Desktop view stream device ID is required",
      DESKTOP_VIEW_ERROR.protocolFatal,
    );
  }
  if (status === 409) {
    return new DesktopCompanionViewStreamError(
      "Desktop view stream is already active",
      DESKTOP_VIEW_ERROR.alreadyStreaming,
    );
  }
  if (status === 403) {
    if (text === "view session not granted") {
      return new DesktopCompanionViewStreamError(
        "Desktop view session is not granted to this device",
        DESKTOP_VIEW_ERROR.grantNotBound,
      );
    }
    return new DesktopCompanionViewStreamError(
      "Desktop view session is not available",
      DESKTOP_VIEW_ERROR.grantUnavailable,
    );
  }
  return new DesktopCompanionViewStreamError(
    "Desktop companion is unavailable",
    DESKTOP_VIEW_ERROR.companionUnavailable,
  );
}

function createAbortError(signal?: AbortSignal): Error {
  const reason = signal?.reason;
  if (reason instanceof Error && reason.name === "AbortError") return reason;
  const error = new Error("Operation aborted");
  error.name = "AbortError";
  return error;
}

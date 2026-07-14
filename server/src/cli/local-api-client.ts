import { request as httpRequest, type IncomingMessage } from "node:http";

import { localApiSocketPath } from "../local-api-socket.js";
import type { ServerConfig } from "../types.js";

export type LocalApiRequestOptions = {
  method?: string;
  body?: Record<string, unknown>;
};

export interface LocalApiConnection {
  getConfig(): ServerConfig;
  getToken(): string | undefined;
  getDataDir(): string;
}

export async function localApiRequest<T>(
  storage: LocalApiConnection,
  path: string,
  options: LocalApiRequestOptions = {},
): Promise<T> {
  const token = storage.getToken();
  if (!token) {
    throw new Error("No owner bearer token configured. Run 'oppi init' or 'oppi pair' first.");
  }

  const socketPath = localApiSocketPath(storage.getDataDir());
  const body = options.body ? JSON.stringify(options.body) : undefined;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
    ...(body
      ? { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(body)) }
      : {}),
  };

  const response = await new Promise<{ statusCode: number; body: string }>((resolve, reject) => {
    const requestOptions = { method: options.method ?? "GET", headers, agent: false as const };
    const handleResponse = (res: IncomingMessage): void => {
      let responseBody = "";
      res.setEncoding("utf-8");
      res.on("data", (chunk) => {
        responseBody += String(chunk);
      });
      res.on("end", () => resolve({ statusCode: res.statusCode ?? 0, body: responseBody }));
    };

    const req = httpRequest(
      {
        ...requestOptions,
        socketPath,
        path,
      },
      handleResponse,
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });

  let payload: unknown;
  try {
    payload = parseJsonPayload(response.body);
  } catch (error) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      throw error;
    }
    payload = {};
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    const message =
      isRecord(payload) && typeof payload.error === "string"
        ? payload.error
        : `HTTP ${response.statusCode}`;
    const error = new Error(message) as Error & { status?: number };
    error.status = response.statusCode;
    throw error;
  }
  return payload as T;
}

function parseJsonPayload(raw: string): unknown {
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    throw new Error("Invalid JSON response from local API");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

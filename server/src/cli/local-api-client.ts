import { AsyncLocalStorage } from "node:async_hooks";
import { request as httpRequest, type IncomingMessage } from "node:http";

import { localApiSocketPath } from "../local-api-socket.js";
import { OPPI_CALLER_SESSION_HEADER } from "../session-caller-identity.js";
import type { ServerConfig } from "../types.js";

export type LocalApiRequestOptions = {
  method?: string;
  body?: Record<string, unknown>;
  signal?: AbortSignal;
  /** Oppi session issuing this request; the server records cross-session primitives. */
  callerSessionId?: string;
};

/** One request, as the interceptor sees it. A copy: the interceptor cannot rewrite the request. */
export type LocalApiInterceptedRequest = Readonly<{
  /** Upper-case; GET when the command did not set one. */
  method: string;
  /** Path and query, as sent. */
  path: string;
  body?: Readonly<Record<string, unknown>>;
  callerSessionId?: string;
  signal?: AbortSignal;
}>;

/**
 * Called before each request in its scope is sent. Resolving lets the request proceed; throwing
 * denies it, and the error becomes the command's own failure. May await (for an approval).
 */
export type LocalApiInterceptor = (request: LocalApiInterceptedRequest) => void | Promise<void>;

const localApiInterceptor = new AsyncLocalStorage<LocalApiInterceptor>();

/**
 * Run `fn` with `interceptor` seeing every `localApiRequest` it starts, however deep in the CLI
 * command. Scoped by async context, so concurrent scopes do not see each other's requests.
 */
export function withLocalApiInterceptor<T>(interceptor: LocalApiInterceptor, fn: () => T): T {
  return localApiInterceptor.run(interceptor, fn);
}

export interface LocalApiError extends Error {
  status?: number;
  code?: string;
  expectedVersion?: number;
  currentVersion?: number;
}

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
  throwIfAborted(options.signal);
  const interceptor = localApiInterceptor.getStore();
  if (interceptor) {
    await interceptor(
      Object.freeze({
        method: (options.method ?? "GET").toUpperCase(),
        path,
        ...(options.body ? { body: Object.freeze(structuredClone(options.body)) } : {}),
        ...(options.callerSessionId ? { callerSessionId: options.callerSessionId } : {}),
        ...(options.signal ? { signal: options.signal } : {}),
      }),
    );
    throwIfAborted(options.signal);
  }
  const token = storage.getToken();
  if (!token) {
    throw new Error("No owner bearer token configured. Run 'oppi init' or 'oppi pair' first.");
  }

  const socketPath = localApiSocketPath(storage.getDataDir());
  const body = options.body ? JSON.stringify(options.body) : undefined;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
    ...(options.callerSessionId ? { [OPPI_CALLER_SESSION_HEADER]: options.callerSessionId } : {}),
    ...(body
      ? { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(body)) }
      : {}),
  };

  const response = await new Promise<{ statusCode: number; body: string }>((resolve, reject) => {
    const requestOptions = {
      method: options.method ?? "GET",
      headers,
      agent: false as const,
      ...(options.signal ? { signal: options.signal } : {}),
    };
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

  throwIfAborted(options.signal);

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
    const error = new Error(message) as LocalApiError;
    error.status = response.statusCode;
    Object.assign(error, validatedApiErrorFields(payload));
    throw error;
  }
  return payload as T;
}

export function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw createAbortError(signal);
}

export function createAbortError(signal?: AbortSignal): Error {
  const reason = signal?.reason;
  if (reason instanceof Error && reason.name === "AbortError") return reason;
  const error = new Error("Operation aborted");
  error.name = "AbortError";
  return error;
}

function parseJsonPayload(raw: string): unknown {
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    throw new Error("Invalid JSON response from local API");
  }
}

function validatedApiErrorFields(value: unknown): {
  code?: string;
  expectedVersion?: number;
  currentVersion?: number;
} {
  if (!isRecord(value)) return {};
  const code =
    typeof value.code === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(value.code)
      ? value.code
      : undefined;
  const expectedVersion = positiveVersion(value.expectedVersion);
  const currentVersion = positiveVersion(value.currentVersion);
  return {
    ...(code ? { code } : {}),
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    ...(currentVersion !== undefined ? { currentVersion } : {}),
  };
}

function positiveVersion(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

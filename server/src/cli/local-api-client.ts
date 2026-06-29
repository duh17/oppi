import { existsSync, readFileSync } from "node:fs";
import { request as httpRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";

import type { Storage } from "../storage.js";
import { resolveTlsConfig, tlsSchemeForConfig } from "../tls.js";

export type LocalApiHostResolvers = {
  tailscaleHostname?: () => string | null;
  tailscaleIp?: () => string | null;
};

export type LocalApiRequestOptions = {
  method?: string;
  body?: Record<string, unknown>;
};

export async function localApiRequest<T>(
  storage: Storage,
  path: string,
  options: LocalApiRequestOptions = {},
  hostResolvers: LocalApiHostResolvers = {},
): Promise<T> {
  const token = storage.getToken();
  if (!token) {
    throw new Error("No owner bearer token configured. Run 'oppi init' or 'oppi pair' first.");
  }

  const url = new URL(`${localApiBaseUrl(storage, hostResolvers)}${path}`);
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

    const req =
      url.protocol === "https:"
        ? httpsRequest(
            url,
            {
              ...requestOptions,
              ...localApiTlsOptions(storage),
            },
            handleResponse,
          )
        : httpRequest(url, requestOptions, handleResponse);
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

function localApiBaseUrl(storage: Storage, hostResolvers: LocalApiHostResolvers): string {
  const config = storage.getConfig();
  const wildcardHost = config.host === "0.0.0.0" || config.host === "::";
  const host = wildcardHost
    ? config.tls?.mode === "tailscale"
      ? (hostResolvers.tailscaleHostname?.() ?? hostResolvers.tailscaleIp?.() ?? "127.0.0.1")
      : "127.0.0.1"
    : config.host;
  return `${tlsSchemeForConfig(config)}://${host}:${config.port}`;
}

function localApiTlsOptions(storage: Storage): { ca?: Buffer } {
  const resolved = resolveTlsConfig(storage.getConfig(), storage.getDataDir());
  if (resolved.enabled && resolved.caPath && existsSync(resolved.caPath)) {
    return { ca: readFileSync(resolved.caPath) };
  }
  return {};
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

import { lookup as dnsLookup } from "node:dns";
import { existsSync, readFileSync } from "node:fs";
import { request as httpRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest, type RequestOptions as HttpsRequestOptions } from "node:https";
import { isIP, type LookupFunction } from "node:net";

import { readValidTailnetDnsName, resolveTlsConfig, tlsSchemeForConfig } from "../tls.js";
import type { ServerConfig } from "../types.js";

export type LocalApiHostResolvers = {
  /** Retained for command-dispatch compatibility; local TLS identity comes from the leaf SAN. */
  tailscaleHostname?: () => string | null;
};

export type LocalApiRequestOptions = {
  method?: string;
  body?: Record<string, unknown>;
};

export interface LocalApiConnection {
  getConfig(): ServerConfig;
  getToken(): string | undefined;
  getDataDir(): string;
}

type LocalApiTarget = {
  url: URL;
  tlsOptions?: HttpsRequestOptions;
};

function dialHostForBind(bindHost: string): string {
  const normalizedHost =
    bindHost.startsWith("[") && bindHost.endsWith("]") ? bindHost.slice(1, -1) : bindHost;
  return normalizedHost === "0.0.0.0"
    ? "127.0.0.1"
    : normalizedHost === "::"
      ? "::1"
      : normalizedHost;
}

function lookupForBindHost(bindHost: string): LookupFunction {
  const dialHost = dialHostForBind(bindHost);
  const family = isIP(dialHost);

  return (_hostname, options, callback) => {
    if (family !== 0) {
      if (options.all) {
        callback(null, [{ address: dialHost, family }]);
        return;
      }
      callback(null, dialHost, family);
      return;
    }
    dnsLookup(dialHost, options, callback);
  };
}

export async function localApiRequest<T>(
  storage: LocalApiConnection,
  path: string,
  options: LocalApiRequestOptions = {},
  _hostResolvers: LocalApiHostResolvers = {},
): Promise<T> {
  // Resolve and validate the TLS identity before constructing an authenticated
  // request. A malformed/expired Tailscale leaf therefore cannot receive the
  // bearer token, even on loopback.
  const target = localApiTarget(storage, path);
  const token = storage.getToken();
  if (!token) {
    throw new Error("No owner bearer token configured. Run 'oppi init' or 'oppi pair' first.");
  }

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
      target.url.protocol === "https:"
        ? httpsRequest(
            target.url,
            {
              ...requestOptions,
              ...target.tlsOptions,
            },
            handleResponse,
          )
        : httpRequest(target.url, requestOptions, handleResponse);
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

function localApiTarget(storage: LocalApiConnection, path: string): LocalApiTarget {
  const config = storage.getConfig();
  const resolved = resolveTlsConfig(config, storage.getDataDir());

  if (resolved.mode === "tailscale") {
    if (!resolved.certPath) {
      throw new Error("Tailscale TLS mode requires a certificate path for local API requests");
    }

    const tlsIdentity = readValidTailnetDnsName(resolved.certPath);
    return {
      url: new URL(`https://${tlsIdentity}:${config.port}${path}`),
      tlsOptions: {
        ...localApiTlsOptions(resolved.caPath),
        lookup: lookupForBindHost(config.host),
        servername: tlsIdentity,
      },
    };
  }

  const dialHost = dialHostForBind(config.host);
  const urlHost = isIP(dialHost) === 6 ? `[${dialHost}]` : dialHost;
  return {
    url: new URL(`${tlsSchemeForConfig(config)}://${urlHost}:${config.port}${path}`),
    tlsOptions: resolved.enabled ? localApiTlsOptions(resolved.caPath) : undefined,
  };
}

function localApiTlsOptions(caPath: string | undefined): { ca?: Buffer } {
  if (caPath && existsSync(caPath)) {
    return { ca: readFileSync(caPath) };
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

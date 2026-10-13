/**
 * Optional owner auth module (`auth.module`): an ES module that can approve custom pairings
 * (`approvePairing`) and admit or refuse every network request (`gate`). Loaded once at
 * startup. A configured module that cannot load fails closed: every network request answers
 * 503 until a restart loads a working module. The owner Unix socket never consults it.
 *
 * Device keys, tokens, refresh, revocation, and owner auth are not pluggable.
 */

import type { IncomingHttpHeaders } from "node:http";
import { isAbsolute } from "node:path";
import { pathToFileURL } from "node:url";

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { DevicePublicKey } from "./types.js";

const log = createLogger({ base: { component: "auth_module" } });

export interface CustomPairingRequest {
  method: "custom";
  deviceName: string;
  devicePublicKey: DevicePublicKey;
  /** RFC 7638 SHA-256 thumbprint of `devicePublicKey`, base64url. */
  keyThumbprint: string;
  /** `credential` from the `POST /pair` body, unparsed. */
  credential: unknown;
  clientIp?: string;
  headers: IncomingHttpHeaders;
}

export type CustomPairingDecision =
  { allow: true; source?: string } | { allow: false; reason?: string };

export interface AuthGateRequest {
  transport: "http" | "ws";
  method: string;
  path: string;
  headers: IncomingHttpHeaders;
  clientIp?: string;
}

export type AuthGateResult = { allow: true } | { allow: false; status: number; error: string };

type ModuleFunction = (request: never) => unknown;

type AuthModuleState =
  | { kind: "none" }
  | { kind: "unavailable"; path: string }
  | { kind: "loaded"; path: string; approvePairing?: ModuleFunction; gate?: ModuleFunction };

const UNAVAILABLE: AuthGateResult = { allow: false, status: 503, error: "auth_module_unavailable" };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export class AuthModule {
  private state: AuthModuleState;

  /** Refuses network requests until `load()` succeeds when a module is configured. */
  constructor(private readonly path: string | undefined) {
    this.state = path === undefined ? { kind: "none" } : { kind: "unavailable", path };
  }

  /** Import the configured module. Never throws: a failure leaves the module unavailable. */
  async load(): Promise<void> {
    const path = this.path;
    if (path === undefined) return;
    try {
      if (!isAbsolute(path)) throw new Error("auth.module must be an absolute path");
      const exports = (await import(pathToFileURL(path).href)) as Record<string, unknown>;
      const approvePairing = exports.approvePairing;
      const gate = exports.gate;
      for (const [name, value] of [
        ["approvePairing", approvePairing],
        ["gate", gate],
      ] as const) {
        if (value !== undefined && typeof value !== "function") {
          throw new Error(`export ${name} is not a function`);
        }
      }
      if (approvePairing === undefined && gate === undefined) {
        throw new Error("module exports neither approvePairing nor gate");
      }
      this.state = {
        kind: "loaded",
        path,
        ...(approvePairing ? { approvePairing: approvePairing as ModuleFunction } : {}),
        ...(gate ? { gate: gate as ModuleFunction } : {}),
      };
      log.info("auth.module_loaded", {
        path,
        approvePairing: approvePairing !== undefined,
        gate: gate !== undefined,
      });
    } catch (error: unknown) {
      this.state = { kind: "unavailable", path };
      log.error("auth.module_load_failed", { path, error: safeErrorMessage(error) });
    }
  }

  get pairingApproverAvailable(): boolean {
    return this.state.kind === "loaded" && this.state.approvePairing !== undefined;
  }

  /** Admit or refuse one network HTTP request or WebSocket upgrade, before device-token auth. */
  async gate(request: AuthGateRequest): Promise<AuthGateResult> {
    const state = this.state;
    if (state.kind === "none") return { allow: true };
    if (state.kind === "unavailable") return UNAVAILABLE;
    if (!state.gate) return { allow: true };
    let decision: unknown;
    try {
      decision = await (state.gate as (request: AuthGateRequest) => unknown)(request);
    } catch (error: unknown) {
      log.warn("auth.gate_failed", {
        transport: request.transport,
        path: request.path,
        error: safeErrorMessage(error),
      });
      return { allow: false, status: 403, error: "Forbidden" };
    }
    if (isRecord(decision) && decision.allow === true) return { allow: true };
    const status =
      isRecord(decision) &&
      typeof decision.status === "number" &&
      Number.isInteger(decision.status) &&
      decision.status >= 400 &&
      decision.status <= 599
        ? decision.status
        : 403;
    const error =
      isRecord(decision) && typeof decision.reason === "string" && decision.reason.length > 0
        ? decision.reason
        : "Forbidden";
    return { allow: false, status, error };
  }

  /** Ask the module to approve a custom pairing. A throw or malformed answer denies. */
  async approvePairing(request: CustomPairingRequest): Promise<CustomPairingDecision> {
    const state = this.state;
    if (state.kind !== "loaded" || !state.approvePairing) return { allow: false };
    let decision: unknown;
    try {
      decision = await (state.approvePairing as (request: CustomPairingRequest) => unknown)(
        request,
      );
    } catch (error: unknown) {
      log.warn("auth.custom_pairing_failed", { error: safeErrorMessage(error) });
      return { allow: false };
    }
    if (!isRecord(decision)) return { allow: false };
    if (decision.allow === true) {
      return typeof decision.source === "string" && decision.source.length > 0
        ? { allow: true, source: decision.source }
        : { allow: true };
    }
    return typeof decision.reason === "string" && decision.reason.length > 0
      ? { allow: false, reason: decision.reason }
      : { allow: false };
  }
}

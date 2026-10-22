/**
 * Fallbacks for iOS builds that predate two wire changes, so a TestFlight build keeps working
 * while its server is updated independently through npm.
 *
 * Capability header: current apps send `X-Oppi-Capabilities: user-image-refs, control-domains`
 * on the requests and WebSocket upgrades of its API and stream clients (not the Share extension,
 * which reads no session shapes). Each token says the app understands one
 * newer shape:
 *
 * - `user-image-refs`: a user event's images may be `media` refs into the session attachment
 *   store instead of data URIs in `text`. Builds 55 and older only read data URIs in `text`, so
 *   without the token the app history routes send the 0.52 shape. Delete this fallback when
 *   Build 55 is no longer supported.
 * - `control-domains`: any `control.domain` string decodes. Builds 53 and 54 decode it as a
 *   closed enum of agents, schedules, skills, workspaces, and one unknown value fails the whole
 *   session list (HTTP) or drops the frame (WebSocket). Builds 53 to 55 only use the domain to
 *   pick the review-comment path format (`skills` is verbatim, anything else is not), and
 *   control routing needs only `control != nil`, so an unknown domain becomes `agents`: the same
 *   behavior Build 55 gives it. Delete this fallback when Build 54 is no longer supported.
 *
 * A request is legacy when its token is absent AND its `User-Agent` contains `CFNetwork/`.
 * URLSession's default user agent is `<CFBundleName>/<CFBundleVersion> CFNetwork/<v> Darwin/<v>`
 * on HTTP and on the WebSocket upgrade, and old builds set no custom one. The build number
 * cannot be the key because unbumped development builds of a current app still report an old
 * one. The CFNetwork guard keeps the CLI, tests, scripts, and other Node or browser clients on
 * the current shape. A missing or different user agent therefore gets the current shape: when
 * detection is wrong, the server behaves as it would without this module.
 *
 * A capable app pays one header check. Only a legacy sink whose body names an unknown domain
 * pays a second serialization.
 */
import type { IncomingMessage } from "node:http";

export type AppCapability = "user-image-refs" | "control-domains";

const CAPABILITIES_HEADER = "x-oppi-capabilities";
const URLSESSION_USER_AGENT_MARKER = "CFNetwork/";

/** Domains Builds 53 and 54 decode. */
const LEGACY_CONTROL_DOMAINS = ["agents", "schedules", "skills", "workspaces"];

/** A JSON `"domain":"<value>"` whose value is not one of {@link LEGACY_CONTROL_DOMAINS}. */
const UNKNOWN_DOMAIN_PATTERN = new RegExp(`"domain":"(?!(?:${LEGACY_CONTROL_DOMAINS.join("|")})")`);

/** Responses and sockets whose app cannot decode every control domain. */
const legacyControlDomainSinks = new WeakSet<object>();

function advertisedCapabilities(req: Pick<IncomingMessage, "headers">): string[] {
  const header = req.headers[CAPABILITIES_HEADER];
  const value = Array.isArray(header) ? header.join(",") : header;
  return value ? value.split(",").map((token) => token.trim().toLowerCase()) : [];
}

/** True for an Apple URLSession client that did not declare `capability`. */
export function isLegacyAppRequest(
  req: Pick<IncomingMessage, "headers">,
  capability: AppCapability,
): boolean {
  const userAgent = req.headers["user-agent"];
  if (!userAgent?.includes(URLSESSION_USER_AGENT_MARKER)) return false;
  return !advertisedCapabilities(req).includes(capability);
}

/** Remember that `sink` (an HTTP response or a WebSocket) belongs to a legacy app request. */
export function markLegacyControlDomains(
  sink: object,
  req: Pick<IncomingMessage, "headers">,
): void {
  if (isLegacyAppRequest(req, "control-domains")) legacyControlDomainSinks.add(sink);
}

function legacyControlDomain(key: string, value: unknown): unknown {
  if (key !== "control" || typeof value !== "object" || value === null) return value;
  const control = value as { domain?: unknown; intent?: unknown };
  if (typeof control.domain !== "string" || typeof control.intent !== "string") return value;
  return LEGACY_CONTROL_DOMAINS.includes(control.domain) ? value : { ...value, domain: "agents" };
}

/** `JSON.stringify(data)` for the app behind `sink`, with control domains it can decode. */
export function stringifyForApp(sink: object, data: unknown): string {
  const body = JSON.stringify(data);
  if (!legacyControlDomainSinks.has(sink) || !UNKNOWN_DOMAIN_PATTERN.test(body)) return body;
  return JSON.stringify(data, legacyControlDomain);
}

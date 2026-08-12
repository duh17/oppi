import { isIanaTimezone, parseResourceUsageRange } from "../resource-usage-service.js";
import type { ResourceUsageSubject } from "../storage/resource-usage-store.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const SKILL_ID = /^skill_[a-f0-9]{64}$/;
const EXTENSION_ID = /^extension_[a-f0-9]{64}$/;

/** Authenticated adapter for Skill, Extension, and server-global Tool Activity usage. */
export function createResourceUsageRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, url, res }) => {
    if (method !== "GET") return false;

    const subject = subjectForPath(path);
    if (!subject) return false;
    const usage = ctx.resourceUsage;
    if (!usage) {
      helpers.error(res, 503, "Resource usage statistics are unavailable");
      return true;
    }

    const keys = [...url.searchParams.keys()];
    if (
      keys.length !== 2 ||
      new Set(keys).size !== 2 ||
      !keys.includes("range") ||
      !keys.includes("timezone") ||
      url.searchParams.getAll("range").length !== 1 ||
      url.searchParams.getAll("timezone").length !== 1
    ) {
      helpers.error(res, 400, "query must contain exactly range and timezone");
      return true;
    }

    const range = parseResourceUsageRange(url.searchParams.get("range"));
    if (!range) {
      helpers.error(res, 400, "range must be one of 7, 30, or 90");
      return true;
    }
    const timezone = url.searchParams.get("timezone") ?? "";
    if (!isIanaTimezone(timezone)) {
      helpers.error(res, 400, "timezone must be a valid IANA timezone");
      return true;
    }

    try {
      helpers.json(res, await usage.getUsage(subject, range, timezone));
    } catch (error) {
      helpers.error(
        res,
        503,
        error instanceof Error ? error.message : "Resource usage statistics are unavailable",
      );
    }
    return true;
  };
}

function subjectForPath(path: string): ResourceUsageSubject | undefined {
  if (path === "/server/stats/tool-activity") return { kind: "tools" };

  const skill = path.match(/^\/server\/resources\/skills\/([^/]+)\/usage$/)?.[1];
  if (skill) {
    const id = decodeSegment(skill);
    return id && SKILL_ID.test(id) ? { kind: "skill", id } : undefined;
  }

  const extension = path.match(/^\/server\/resources\/extensions\/([^/]+)\/usage$/)?.[1];
  if (extension) {
    const id = decodeSegment(extension);
    return id && (id === "oppi" || EXTENSION_ID.test(id)) ? { kind: "extension", id } : undefined;
  }
  return undefined;
}

function decodeSegment(value: string): string | undefined {
  try {
    const decoded = decodeURIComponent(value);
    return decoded.includes("/") || decoded.includes("\\") || decoded.includes("\0")
      ? undefined
      : decoded;
  } catch {
    return undefined;
  }
}

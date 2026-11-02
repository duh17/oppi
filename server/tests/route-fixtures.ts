import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { apiRouteSpecs, type ApiRouteSpec } from "../src/routes/registry.js";

/**
 * `protocol/routes.json`: every route the server answers, as `RouteHandler` sees it.
 *
 * The Apple client's `APIClientRouteContractTests` drives every `APIClient` endpoint
 * method and requires the request it builds to match one row here, so a typo'd path,
 * a wrong verb, or a route the server deleted fails a client test before it ships.
 *
 * Only this serializer defines the bytes. Ordinary tests rebuild it in memory and
 * compare against the committed file; `npm run protocol:fixtures:update` is what
 * writes it.
 */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const ROUTES_SNAPSHOT_PATH = join(repoRoot, "protocol/routes.json");

export const ROUTES_FIXTURE_DESCRIPTION =
  "Every HTTP and WebSocket route server/src/routes/registry.ts declares: method, path template, path params, operationId, surface, auth, and transport. Generated from the registry by server/tests/route-fixtures.ts; server/tests/route-fixtures.test.ts fails when the committed bytes differ. The Apple client's APIClientRouteContractTests requires every request an APIClient endpoint method builds to match a row, so a client path the server does not serve fails there.";

export interface RouteFixtureRow {
  method: string;
  path: string;
  /** Parameter names in `path`, in order: `{name}` for one segment, `{name+}` for the rest. */
  params: string[];
  /** Request/response schema names, carried only when the registry row names one. */
  requestSchema?: string;
  responseSchema?: string;
  operationId: string;
  surface: string;
  auth: string;
  transport: string;
}

/** A schema reference as a registry row names it: a bare name, or an object with one. */
type SchemaRefLike = string | { name?: string } | undefined;

export interface RouteFixtureDocument {
  _meta: { description: string; routeCount: number };
  routes: RouteFixtureRow[];
}

/** Route specs as fixture rows, in registry order. */
export function buildRouteRows(specs: readonly ApiRouteSpec[] = apiRouteSpecs): RouteFixtureRow[] {
  return specs.map((spec) => {
    // The registry may or may not carry schema refs (they were removed once already); a
    // row keeps them when it does, so neither shape forces a generator change.
    const schemas = spec as ApiRouteSpec & {
      requestSchema?: SchemaRefLike;
      responseSchema?: SchemaRefLike;
    };
    const requestSchema = schemaName(schemas.requestSchema);
    const responseSchema = schemaName(schemas.responseSchema);
    return {
      method: spec.method,
      path: spec.path,
      params: pathParamNames(spec.path),
      ...(requestSchema === undefined ? {} : { requestSchema }),
      ...(responseSchema === undefined ? {} : { responseSchema }),
      operationId: spec.operationId,
      surface: spec.surface,
      auth: spec.auth,
      transport: spec.transport ?? "http",
    };
  });
}

function schemaName(ref: SchemaRefLike): string | undefined {
  if (typeof ref === "string") return ref;
  return ref?.name;
}

/**
 * `{name}` and `{name+}` both name a param; the `+` only says it spans the rest of the path.
 * `:name` is accepted too, so a registry that templated paths the way its metrics patterns
 * read still exports the same params.
 */
export function pathParamNames(path: string): string[] {
  return [
    ...path.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\+?\}|:([A-Za-z][A-Za-z0-9_]*)/g),
  ].map((match) => match[1] ?? match[2]);
}

export function buildRouteFixtureDocument(
  rows: RouteFixtureRow[] = buildRouteRows(),
): RouteFixtureDocument {
  return {
    _meta: { description: ROUTES_FIXTURE_DESCRIPTION, routeCount: rows.length },
    routes: rows,
  };
}

export function serializeRouteFixture(rows: RouteFixtureRow[] = buildRouteRows()): string {
  return `${JSON.stringify(buildRouteFixtureDocument(rows), null, 2)}\n`;
}

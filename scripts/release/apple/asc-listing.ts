#!/usr/bin/env bun
/**
 * asc-listing.ts — Diff and write the App Store listing in App Store Connect.
 *
 *   bun scripts/release/apple/asc-listing.ts plan  [--file <desired.json>]
 *   bun scripts/release/apple/asc-listing.ts apply [--file <desired.json>]
 *
 * `plan` only reads (GET). It prints, per resource, each managed field as
 * unchanged or current → desired, plus checks (length limits, `<FILL:` markers,
 * no in-app purchases).
 *
 * `apply` runs the same plan and then PATCHes or POSTs only the differing fields
 * named in the desired-state file (default: app-store-listing.json beside this
 * script). It never submits for review, never attaches or removes a build, and
 * for pricing only creates a free schedule when none exists; it refuses to touch
 * a schedule that is not free. It manages no encryption declaration: the app's
 * Info.plist sets ITSAppUsesNonExemptEncryption to NO (see clients/apple/project.yml).
 *
 * Field names follow Apple's App Store Connect OpenAPI specification (4.6).
 * Auth is the same as asc.ts and testflight.ts:
 *   ASC_KEY_ID / ~/.appstoreconnect/key_id
 *   ASC_ISSUER_ID / ~/.appstoreconnect/issuer_id
 *   ASC_KEY_PATH / ~/.appstoreconnect/AuthKey_<KEY_ID>.p8
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

const ASC_BASE_URL = "https://api.appstoreconnect.apple.com";
const DEFAULT_DESIRED = path.join(import.meta.dir, "app-store-listing.json");

/** App Store version states in which the listing can still be edited. */
const EDITABLE_VERSION_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

/** App info states whose localizations and age rating can still be edited. */
const EDITABLE_APP_INFO_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
]);

/** App Store Connect field limits (characters, except review notes in bytes). */
const LIMITS: Record<string, { max: number; unit: "chars" | "bytes" }> = {
  "appInfoLocalization.name": { max: 30, unit: "chars" },
  "appInfoLocalization.subtitle": { max: 30, unit: "chars" },
  "appStoreVersionLocalization.description": { max: 4000, unit: "chars" },
  "appStoreVersionLocalization.keywords": { max: 100, unit: "chars" },
  "appStoreVersionLocalization.promotionalText": { max: 170, unit: "chars" },
  "appStoreReviewDetail.notes": { max: 4000, unit: "bytes" },
};

const PLACEHOLDER = "<FILL";

type Json = any;
type Fields = Record<string, unknown>;

type Desired = {
  bundleId: string;
  platform: string;
  versionString: string;
  locale: string;
  app: Fields;
  appInfo: { primaryCategory?: string; secondaryCategory?: string };
  appInfoLocalization: Fields;
  ageRatingDeclaration: Fields;
  appStoreVersion: Fields;
  appStoreVersionLocalization: Fields;
  appStoreReviewDetail: Fields;
  pricing: { baseTerritory: string; customerPrice: string };
  availability: { availableInNewTerritories: boolean; unavailableTerritories: string[] };
};

// MARK: - Auth and HTTP (same key handling as asc.ts)

function die(message: string): never {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function readFileOr(file: string, fallback = ""): string {
  try {
    return fs.readFileSync(file, "utf-8");
  } catch {
    return fallback;
  }
}

let jwtCache: { token: string; exp: number } | null = null;

function jwt(): string {
  const now = Math.floor(Date.now() / 1000);
  if (jwtCache && jwtCache.exp - 60 > now) return jwtCache.token;

  const home = process.env.HOME || die("HOME is not set.");
  const keyId = (process.env.ASC_KEY_ID || readFileOr(`${home}/.appstoreconnect/key_id`)).trim();
  const issuerId = (process.env.ASC_ISSUER_ID || readFileOr(`${home}/.appstoreconnect/issuer_id`)).trim();
  if (!keyId) die("Missing ASC key ID (ASC_KEY_ID or ~/.appstoreconnect/key_id).");
  if (!issuerId) die("Missing ASC issuer ID (ASC_ISSUER_ID or ~/.appstoreconnect/issuer_id).");
  const keyPath = process.env.ASC_KEY_PATH || `${home}/.appstoreconnect/AuthKey_${keyId}.p8`;
  if (!fs.existsSync(keyPath)) die(`ASC private key not found at the configured path.`);

  const exp = now + 1200;
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({ iss: issuerId, iat: now, exp, aud: "appstoreconnect-v1" }),
  ).toString("base64url");
  const sig = crypto.sign("sha256", Buffer.from(`${header}.${payload}`), {
    key: fs.readFileSync(keyPath, "utf-8"),
    dsaEncoding: "ieee-p1363",
  });
  jwtCache = { token: `${header}.${payload}.${sig.toString("base64url")}`, exp };
  return jwtCache.token;
}

class AscError extends Error {
  constructor(
    readonly status: number,
    readonly body: Json,
    method: string,
    url: string,
  ) {
    super(`ASC ${method} ${url.replace(ASC_BASE_URL, "")} → ${status}: ${JSON.stringify(body?.errors ?? body)}`);
  }
}

async function asc(method: "GET" | "PATCH" | "POST", pathOrUrl: string, body?: Json): Promise<Json> {
  const url = pathOrUrl.startsWith("https://") ? pathOrUrl : `${ASC_BASE_URL}${pathOrUrl}`;
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) throw new AscError(res.status, json, method, url);
  return json;
}

async function getAll(pathOrUrl: string): Promise<{ data: Json[]; included: Json[] }> {
  const data: Json[] = [];
  const included: Json[] = [];
  let next: string | null = pathOrUrl;
  while (next) {
    const page = await asc("GET", next);
    data.push(...(page.data ?? []));
    included.push(...(page.included ?? []));
    next = page.links?.next ?? null;
  }
  return { data, included };
}

/** GET that maps App Store Connect's 404 for a missing resource to null. */
async function getOrNull(pathOrUrl: string): Promise<Json | null> {
  try {
    return await asc("GET", pathOrUrl);
  } catch (error) {
    if (error instanceof AscError && error.status === 404) return null;
    throw error;
  }
}

// MARK: - Desired state

/** Text fields may be written as an array of lines in the desired-state file. */
function normalize(fields: Fields): Fields {
  const out: Fields = {};
  for (const [key, value] of Object.entries(fields)) {
    if (key.startsWith("$")) continue;
    out[key] = Array.isArray(value) ? value.join("\n") : value;
  }
  return out;
}

function loadDesired(file: string): Desired {
  const raw = JSON.parse(fs.readFileSync(file, "utf-8"));
  for (const key of [
    "app",
    "appInfoLocalization",
    "ageRatingDeclaration",
    "appStoreVersion",
    "appStoreVersionLocalization",
    "appStoreReviewDetail",
  ]) {
    raw[key] = normalize(raw[key] ?? {});
  }
  return raw as Desired;
}

// MARK: - Current state

type Current = {
  app: Json;
  appInfo: Json;
  categories: { primaryCategory: string | null; secondaryCategory: string | null };
  appInfoLocalization: Json | null;
  ageRating: Json;
  territoryRatings: Record<string, number>;
  version: Json;
  buildVersion: string | null;
  versionLocalization: Json | null;
  reviewDetail: Json | null;
  inAppPurchaseCount: number;
  freePricePointId: string;
  /** null when the app has no price schedule yet. */
  basePrice: { territory: string; customerPrice: string } | null;
  allTerritories: string[];
  /** null when the app has no availability yet; otherwise territory → its availability. */
  availability: {
    id: string;
    availableInNewTerritories: boolean;
    territories: Map<string, { id: string; available: boolean }>;
  } | null;
};

async function readCurrent(desired: Desired): Promise<Current> {
  const apps = await asc(
    "GET",
    `/v1/apps?filter[bundleId]=${encodeURIComponent(desired.bundleId)}&fields[apps]=name,bundleId,primaryLocale,contentRightsDeclaration`,
  );
  const app = apps.data?.[0] ?? die(`No app with bundle ID ${desired.bundleId}.`);

  const infos = await asc("GET", `/v1/apps/${app.id}/appInfos?include=primaryCategory,secondaryCategory,ageRatingDeclaration`);
  const appInfo =
    infos.data.find((info: Json) => EDITABLE_APP_INFO_STATES.has(info.attributes?.state)) ??
    die(`No editable app info (states: ${infos.data.map((i: Json) => i.attributes?.state).join(", ")}).`);
  const ageRatingId = appInfo.relationships.ageRatingDeclaration.data.id;
  const ageRating = infos.included.find((r: Json) => r.type === "ageRatingDeclarations" && r.id === ageRatingId);

  const versions = await getAll(
    `/v1/apps/${app.id}/appStoreVersions?filter[platform]=${desired.platform}&filter[versionString]=${encodeURIComponent(desired.versionString)}`,
  );
  const version =
    versions.data[0] ?? die(`No ${desired.platform} App Store version ${desired.versionString}; create it in App Store Connect first.`);
  if (!EDITABLE_VERSION_STATES.has(version.attributes.appVersionState)) {
    die(`Version ${desired.versionString} is ${version.attributes.appVersionState}, which is not editable.`);
  }

  const [infoLocs, versionLocs, reviewDetail, build, iaps, territoryRatings, freePoint, territories] =
    await Promise.all([
      getAll(`/v1/appInfos/${appInfo.id}/appInfoLocalizations`),
      getAll(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`),
      asc("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`),
      asc("GET", `/v1/appStoreVersions/${version.id}/build?fields[builds]=version`),
      asc("GET", `/v1/apps/${app.id}/inAppPurchasesV2?limit=1`),
      getAll(`/v1/appInfos/${appInfo.id}/territoryAgeRatings?limit=200`),
      asc("GET", `/v1/apps/${app.id}/appPricePoints?filter[territory]=${desired.pricing.baseTerritory}&limit=1`),
      getAll(`/v1/territories?limit=200`),
    ]);

  const ratingCounts: Record<string, number> = {};
  for (const rating of territoryRatings.data) {
    const value = rating.attributes?.appStoreAgeRating ?? "none";
    ratingCounts[value] = (ratingCounts[value] ?? 0) + 1;
  }

  // Price points are sorted from free upward; the first one must be free.
  const free = freePoint.data?.[0];
  if (!free || Number(free.attributes.customerPrice) !== 0) die("Could not find the free price point.");

  // An app without a price schedule still returns a placeholder for
  // /appPriceSchedule; its manualPrices then 404.
  const manualPrices = await getOrNull(
    `/v1/appPriceSchedules/${app.id}/manualPrices?include=appPricePoint,territory&fields[appPricePoints]=customerPrice&limit=200`,
  );
  let basePrice: Current["basePrice"] = null;
  if (manualPrices) {
    const baseTerritory = (await asc("GET", `/v1/appPriceSchedules/${app.id}/baseTerritory`)).data.id;
    const price = manualPrices.data.find(
      (p: Json) => p.relationships?.territory?.data?.id === baseTerritory && !p.attributes?.endDate,
    );
    const point = manualPrices.included?.find(
      (r: Json) => r.type === "appPricePoints" && r.id === price?.relationships?.appPricePoint?.data?.id,
    );
    basePrice = { territory: baseTerritory, customerPrice: point?.attributes?.customerPrice ?? "unknown" };
  }

  let availability: Current["availability"] = null;
  const availabilityDoc = await getOrNull(`/v1/apps/${app.id}/appAvailabilityV2`);
  if (availabilityDoc) {
    const id = availabilityDoc.data.id;
    const rows = await getAll(`/v2/appAvailabilities/${id}/territoryAvailabilities?include=territory&limit=200`);
    const map = new Map<string, { id: string; available: boolean }>();
    for (const row of rows.data) {
      map.set(row.relationships.territory.data.id, { id: row.id, available: row.attributes.available });
    }
    availability = {
      id,
      availableInNewTerritories: availabilityDoc.data.attributes.availableInNewTerritories,
      territories: map,
    };
  }

  return {
    app,
    appInfo,
    categories: {
      primaryCategory: appInfo.relationships.primaryCategory?.data?.id ?? null,
      secondaryCategory: appInfo.relationships.secondaryCategory?.data?.id ?? null,
    },
    appInfoLocalization: infoLocs.data.find((l: Json) => l.attributes.locale === desired.locale) ?? null,
    ageRating,
    territoryRatings: ratingCounts,
    version,
    buildVersion: build.data?.attributes?.version ?? null,
    versionLocalization: versionLocs.data.find((l: Json) => l.attributes.locale === desired.locale) ?? null,
    reviewDetail: reviewDetail.data ?? null,
    inAppPurchaseCount: iaps.meta?.paging?.total ?? iaps.data.length,
    freePricePointId: free.id,
    basePrice,
    allTerritories: territories.data.map((t: Json) => t.id).sort(),
    availability,
  };
}

// MARK: - Plan

type Change = { field: string; from: unknown; to: unknown };

type Step = {
  /** Resource label shown in the plan. */
  title: string;
  /** What apply does for this step; null when nothing differs. */
  action: string | null;
  changes: Change[];
  notes: string[];
  run?: () => Promise<Json>;
};

function diffFields(current: Fields | null | undefined, desired: Fields): Change[] {
  const changes: Change[] = [];
  for (const [field, to] of Object.entries(desired)) {
    const from = current?.[field] ?? null;
    if (!sameValue(from, to)) changes.push({ field, from, to });
  }
  return changes;
}

function sameValue(a: unknown, b: unknown): boolean {
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

function patchBody(type: string, id: string, attributes: Fields): Json {
  return { data: { type, id, attributes } };
}

function changedAttributes(changes: Change[]): Fields {
  return Object.fromEntries(changes.map((c) => [c.field, c.to]));
}

function buildPlan(desired: Desired, cur: Current): Step[] {
  const steps: Step[] = [];

  // App: content rights.
  {
    const changes = diffFields(cur.app.attributes, desired.app);
    steps.push({
      title: `App ${cur.app.id} (${cur.app.attributes.name})`,
      action: changes.length ? "PATCH /v1/apps/{id}" : null,
      changes,
      notes: [],
      run: () => asc("PATCH", `/v1/apps/${cur.app.id}`, patchBody("apps", cur.app.id, changedAttributes(changes))),
    });
  }

  // App info: categories.
  {
    const changes = diffFields(cur.categories, desired.appInfo);
    const relationships = Object.fromEntries(
      changes.map((c) => [c.field, { data: { type: "appCategories", id: c.to } }]),
    );
    steps.push({
      title: `App info ${cur.appInfo.id} (${cur.appInfo.attributes.state})`,
      action: changes.length ? "PATCH /v1/appInfos/{id} relationships" : null,
      changes,
      notes: [],
      run: () =>
        asc("PATCH", `/v1/appInfos/${cur.appInfo.id}`, {
          data: { type: "appInfos", id: cur.appInfo.id, relationships },
        }),
    });
  }

  // App info localization: name, subtitle, privacy policy URL.
  {
    const loc = cur.appInfoLocalization;
    const changes = diffFields(loc?.attributes, desired.appInfoLocalization);
    steps.push({
      title: `App info localization ${desired.locale}`,
      action: !changes.length ? null : loc ? "PATCH /v1/appInfoLocalizations/{id}" : "POST /v1/appInfoLocalizations",
      changes,
      notes: [],
      run: () =>
        loc
          ? asc("PATCH", `/v1/appInfoLocalizations/${loc.id}`, patchBody("appInfoLocalizations", loc.id, changedAttributes(changes)))
          : asc("POST", "/v1/appInfoLocalizations", {
              data: {
                type: "appInfoLocalizations",
                attributes: { locale: desired.locale, ...desired.appInfoLocalization },
                relationships: { appInfo: { data: { type: "appInfos", id: cur.appInfo.id } } },
              },
            }),
    });
  }

  // Age rating declaration.
  {
    const changes = diffFields(cur.ageRating.attributes, desired.ageRatingDeclaration);
    const ratings = Object.entries(cur.territoryRatings)
      .map(([rating, count]) => `${rating} in ${count} territories`)
      .join(", ");
    steps.push({
      title: `Age rating declaration ${cur.ageRating.id}`,
      action: changes.length ? "PATCH /v1/ageRatingDeclarations/{id}" : null,
      changes,
      notes: [`Current computed rating: ${ratings || "none"}.`],
      run: () =>
        asc(
          "PATCH",
          `/v1/ageRatingDeclarations/${cur.ageRating.id}`,
          patchBody("ageRatingDeclarations", cur.ageRating.id, changedAttributes(changes)),
        ),
    });
  }

  // App Store version: copyright, release type.
  {
    const changes = diffFields(cur.version.attributes, desired.appStoreVersion);
    steps.push({
      title: `App Store version ${cur.version.attributes.versionString} (${cur.version.attributes.appVersionState})`,
      action: changes.length ? "PATCH /v1/appStoreVersions/{id}" : null,
      changes,
      notes: [`Attached build: ${cur.buildVersion ?? "none"} (not managed; apply never changes the build).`],
      run: () =>
        asc(
          "PATCH",
          `/v1/appStoreVersions/${cur.version.id}`,
          patchBody("appStoreVersions", cur.version.id, changedAttributes(changes)),
        ),
    });
  }

  // Version localization: description, keywords, promotional text, URLs.
  {
    const loc = cur.versionLocalization;
    const changes = diffFields(loc?.attributes, desired.appStoreVersionLocalization);
    steps.push({
      title: `Version localization ${desired.locale}`,
      action: !changes.length
        ? null
        : loc
          ? "PATCH /v1/appStoreVersionLocalizations/{id}"
          : "POST /v1/appStoreVersionLocalizations",
      changes,
      notes: [],
      run: () =>
        loc
          ? asc(
              "PATCH",
              `/v1/appStoreVersionLocalizations/${loc.id}`,
              patchBody("appStoreVersionLocalizations", loc.id, changedAttributes(changes)),
            )
          : asc("POST", "/v1/appStoreVersionLocalizations", {
              data: {
                type: "appStoreVersionLocalizations",
                attributes: { locale: desired.locale, ...desired.appStoreVersionLocalization },
                relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: cur.version.id } } },
              },
            }),
    });
  }

  // App Review information: notes and sign-in flag. Contact fields stay unmanaged.
  {
    const detail = cur.reviewDetail;
    const changes = diffFields(detail?.attributes, desired.appStoreReviewDetail);
    const contact = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"]
      .map((f) => `${f} ${detail?.attributes?.[f] ? "set" : "EMPTY"}`)
      .join(", ");
    steps.push({
      title: "App Review information",
      action: !changes.length
        ? null
        : detail
          ? "PATCH /v1/appStoreReviewDetails/{id}"
          : "POST /v1/appStoreReviewDetails",
      changes,
      notes: [`Contact (not managed): ${contact}.`],
      run: () =>
        detail
          ? asc(
              "PATCH",
              `/v1/appStoreReviewDetails/${detail.id}`,
              patchBody("appStoreReviewDetails", detail.id, changedAttributes(changes)),
            )
          : asc("POST", "/v1/appStoreReviewDetails", {
              data: {
                type: "appStoreReviewDetails",
                attributes: desired.appStoreReviewDetail,
                relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: cur.version.id } } },
              },
            }),
    });
  }

  steps.push(pricingStep(desired, cur));
  steps.push(...availabilitySteps(desired, cur));
  return steps;
}

function pricingStep(desired: Desired, cur: Current): Step {
  const want = desired.pricing;
  const notes = [`In-app purchases: ${cur.inAppPurchaseCount} (expected 0; never changed).`];
  if (cur.basePrice) {
    const isFree = Number(cur.basePrice.customerPrice) === 0;
    notes.push(`Price schedule exists: ${cur.basePrice.territory} ${cur.basePrice.customerPrice}.`);
    return {
      title: "Price",
      action: isFree ? null : "REFUSED: the schedule is not free; change pricing in App Store Connect",
      changes: isFree ? [] : [{ field: "customerPrice", from: cur.basePrice.customerPrice, to: want.customerPrice }],
      notes,
    };
  }
  notes.push("No price schedule exists yet.");
  return {
    title: "Price",
    action: `POST /v1/appPriceSchedules (free, base ${want.baseTerritory})`,
    changes: [{ field: "customerPrice", from: null, to: want.customerPrice }],
    notes,
    run: () =>
      asc("POST", "/v1/appPriceSchedules", {
        data: {
          type: "appPriceSchedules",
          relationships: {
            app: { data: { type: "apps", id: cur.app.id } },
            baseTerritory: { data: { type: "territories", id: want.baseTerritory } },
            manualPrices: { data: [{ type: "appPrices", id: "${free-price}" }] },
          },
        },
        included: [
          {
            type: "appPrices",
            id: "${free-price}",
            attributes: { startDate: null },
            relationships: { appPricePoint: { data: { type: "appPricePoints", id: cur.freePricePointId } } },
          },
        ],
      }),
  };
}

function availabilitySteps(desired: Desired, cur: Current): Step[] {
  const want = desired.availability;
  const unavailable = new Set(want.unavailableTerritories);
  for (const t of unavailable) if (!cur.allTerritories.includes(t)) die(`Unknown territory ${t}.`);
  const summary = `${cur.allTerritories.length - unavailable.size} of ${cur.allTerritories.length} territories; not ${[...unavailable].join(", ")}`;

  if (!cur.availability) {
    return [
      {
        title: "Availability",
        action: `POST /v2/appAvailabilities (${summary})`,
        changes: [
          { field: "availableInNewTerritories", from: null, to: want.availableInNewTerritories },
          { field: "unavailableTerritories", from: null, to: [...unavailable] },
        ],
        notes: ["No availability exists yet."],
        run: () =>
          asc("POST", "/v2/appAvailabilities", {
            data: {
              type: "appAvailabilities",
              attributes: { availableInNewTerritories: want.availableInNewTerritories },
              relationships: {
                app: { data: { type: "apps", id: cur.app.id } },
                territoryAvailabilities: {
                  data: cur.allTerritories.map((t) => ({ type: "territoryAvailabilities", id: `\${${t}}` })),
                },
              },
            },
            included: cur.allTerritories.map((t) => ({
              type: "territoryAvailabilities",
              id: `\${${t}}`,
              attributes: { available: !unavailable.has(t) },
              relationships: { territory: { data: { type: "territories", id: t } } },
            })),
          }),
      },
    ];
  }

  const steps: Step[] = [];
  const existing = cur.availability;
  const changes: Change[] = [];
  const patches: Array<{ id: string; territory: string; available: boolean }> = [];
  for (const territory of cur.allTerritories) {
    const row = existing.territories.get(territory);
    const available = !unavailable.has(territory);
    if (!row) {
      changes.push({ field: territory, from: "missing", to: available });
      continue;
    }
    if (row.available !== available) {
      changes.push({ field: territory, from: row.available, to: available });
      patches.push({ id: row.id, territory, available });
    }
  }
  const notes = [`Target: ${summary}.`];
  if (existing.availableInNewTerritories !== want.availableInNewTerritories) {
    notes.push(
      `availableInNewTerritories is ${existing.availableInNewTerritories}; the API sets it only when availability is created. Change it in Pricing and Availability.`,
    );
  }
  if (changes.some((c) => c.from === "missing")) {
    notes.push("Some territories have no availability row; set them in Pricing and Availability.");
  }
  steps.push({
    title: "Availability",
    action: patches.length ? `PATCH /v1/territoryAvailabilities/{id} ×${patches.length}` : null,
    changes,
    notes,
    run: async () => {
      for (const p of patches) {
        await asc(
          "PATCH",
          `/v1/territoryAvailabilities/${p.id}`,
          patchBody("territoryAvailabilities", p.id, { available: p.available }),
        );
      }
      return { patched: patches.map((p) => p.territory) };
    },
  });
  return steps;
}

function checks(desired: Desired): string[] {
  const out: string[] = [];
  const values: Record<string, unknown> = {
    ...Object.fromEntries(Object.entries(desired.appInfoLocalization).map(([k, v]) => [`appInfoLocalization.${k}`, v])),
    ...Object.fromEntries(
      Object.entries(desired.appStoreVersionLocalization).map(([k, v]) => [`appStoreVersionLocalization.${k}`, v]),
    ),
    ...Object.fromEntries(Object.entries(desired.appStoreReviewDetail).map(([k, v]) => [`appStoreReviewDetail.${k}`, v])),
  };
  for (const [key, value] of Object.entries(values)) {
    if (typeof value !== "string") continue;
    const limit = LIMITS[key];
    if (limit) {
      const size = limit.unit === "bytes" ? Buffer.byteLength(value) : [...value].length;
      out.push(`${size > limit.max ? "FAIL" : "ok  "} ${key}: ${size}/${limit.max} ${limit.unit}`);
    }
    const markers = value.match(/<FILL:[^>]*>/g);
    if (markers) out.push(`TODO ${key}: ${markers.length} placeholder(s) to fill before Submit: ${markers.join(" ")}`);
  }
  return out;
}

// MARK: - Output

function show(value: unknown): string {
  return value === null || value === undefined ? "(unset)" : JSON.stringify(value);
}

/** Line diff (LCS) for multi-line text, so long fields read as a review diff. */
function lineDiff(from: string, to: string): string[] {
  const a = from.split("\n");
  const b = to.split("\n");
  const lcs = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const out: string[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      out.push(`        ${a[i]}`);
      i++;
      j++;
    } else if (j < b.length && (i === a.length || lcs[i][j + 1] >= lcs[i + 1][j])) {
      out.push(`      + ${b[j++]}`);
    } else {
      out.push(`      - ${a[i++]}`);
    }
  }
  return out;
}

function printChange(change: Change): void {
  const { field, from, to } = change;
  const multiline = (v: unknown) => typeof v === "string" && (v.includes("\n") || v.length > 100);
  if (multiline(from) || multiline(to)) {
    console.log(`    ~ ${field}:${typeof from === "string" ? "" : " (unset) →"}`);
    const lines =
      typeof from === "string" ? lineDiff(from, String(to)) : String(to).split("\n").map((l) => `      + ${l}`);
    for (const line of lines) console.log(line);
    return;
  }
  console.log(`    ~ ${field}: ${show(from)} → ${show(to)}`);
}

function printPlan(desired: Desired, cur: Current, steps: Step[], file: string): void {
  console.log(`App Store listing plan — ${desired.bundleId} ${desired.platform} ${desired.versionString} (${desired.locale})`);
  console.log(`Desired state: ${path.relative(process.cwd(), file)}`);
  console.log(`Read at: ${new Date().toISOString()}`);
  console.log("");
  for (const step of steps) {
    console.log(`${step.action ? "●" : "○"} ${step.title}`);
    console.log(`    apply: ${step.action ?? "nothing to do"}`);
    for (const change of step.changes) printChange(change);
    for (const note of step.notes) console.log(`    note: ${note}`);
    console.log("");
  }
  console.log("Checks");
  for (const line of checks(desired)) console.log(`    ${line}`);
  const pending = steps.filter((s) => s.action).length;
  console.log("");
  console.log(`${pending} step(s) would change App Store Connect.`);
}

// MARK: - Main

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const mode = args[0];
  const fileIndex = args.indexOf("--file");
  const file = path.resolve(fileIndex >= 0 ? args[fileIndex + 1] : DEFAULT_DESIRED);
  if (mode !== "plan" && mode !== "apply") {
    console.log("Usage: bun scripts/release/apple/asc-listing.ts <plan|apply> [--file <desired.json>]");
    process.exit(mode === "--help" || mode === "-h" ? 0 : 1);
  }

  const desired = loadDesired(file);
  const current = await readCurrent(desired);
  const steps = buildPlan(desired, current);
  printPlan(desired, current, steps, file);
  if (mode === "plan") return;

  if (checks(desired).some((line) => line.startsWith("FAIL"))) die("A field is over its limit; fix the desired state first.");
  const refused = steps.filter((s) => s.action?.startsWith("REFUSED"));
  if (refused.length) die(`Refused: ${refused.map((s) => s.title).join(", ")}.`);

  console.log("");
  console.log("Applying");
  for (const step of steps) {
    if (!step.action || !step.run) continue;
    process.stdout.write(`  ${step.title}: ${step.action} … `);
    await step.run();
    console.log("done");
  }
  console.log("");
  console.log("Re-run `plan` to confirm nothing is left to change.");
}

main().catch((error) => {
  console.error(error?.message || error);
  process.exit(1);
});

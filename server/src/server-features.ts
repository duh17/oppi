/**
 * Feature switches: whether each larger feature exists on this server, for every device that uses
 * it. Plain Pi (chat, sessions and files) has no switch. Stored as `features` in `config.json`,
 * where an absent key is on, so an older config and an older app see every feature; listed whole
 * in `/server/info` and `GET /server/features`.
 *
 * Readers: the app hides an off feature's entry points (sidebar, pane launcher, chat bar, links);
 * the server stops loading MCP tools into new sessions while `mcp` is off, leaves the `godot_*`
 * tools and their guideline out of durable sessions while `godotPane` is off, and lists a plugin
 * sidebar entry only while its feature is on (`plugin-screens.ts`, `screens-stream.ts`).
 */
import type { ServerConfig, ServerFeature } from "./types.js";
import { isRecord } from "./json-shape.js";

/** Every switch, in the order Server Settings lists them. */
export const SERVER_FEATURES = [
  "agents",
  "schedules",
  "skills",
  "extensions",
  "mcp",
  "terminal",
  "rex",
  "herdr",
  "godotPane",
  "browserPane",
] as const satisfies readonly ServerFeature[];

// A feature added to the type but not to the list fails here.
type Unlisted = Exclude<ServerFeature, (typeof SERVER_FEATURES)[number]>;
const everyFeatureListed: [Unlisted] extends [never] ? true : never = true;
void everyFeatureListed;

export type ServerFeatureSwitches = Record<ServerFeature, boolean>;
export type ServerFeaturePatch = Partial<ServerFeatureSwitches>;

function every(on: boolean): ServerFeatureSwitches {
  return Object.fromEntries(
    SERVER_FEATURES.map((feature) => [feature, on]),
  ) as ServerFeatureSwitches;
}

/** Named sets of switches: `all` is the default, `plainPi` turns every feature off. */
export const SERVER_FEATURE_PRESETS = {
  all: every(true),
  plainPi: every(false),
} as const satisfies Record<string, ServerFeatureSwitches>;

export function isServerFeature(value: unknown): value is ServerFeature {
  return typeof value === "string" && (SERVER_FEATURES as readonly string[]).includes(value);
}

/** Every switch as the server applies it: what is saved, and on for the rest. */
export function serverFeatures(config: Pick<ServerConfig, "features">): ServerFeatureSwitches {
  const saved = config.features ?? {};
  return Object.fromEntries(
    SERVER_FEATURES.map((feature) => [feature, saved[feature] !== false]),
  ) as ServerFeatureSwitches;
}

export function featureOn(config: Pick<ServerConfig, "features">, feature: ServerFeature): boolean {
  return config.features?.[feature] !== false;
}

/**
 * `value` as switches to save: an object of feature names to booleans. Returns the reason when it
 * is not one. `unknown: "drop"` skips names this server does not have (a config file a newer
 * server wrote); `"refuse"` reports the first.
 */
export function parseFeaturePatch(
  value: unknown,
  unknown: "drop" | "refuse",
): ServerFeaturePatch | string {
  if (!isRecord(value)) return "expected an object of feature switches";
  const patch: ServerFeaturePatch = {};
  for (const [key, on] of Object.entries(value)) {
    if (!isServerFeature(key)) {
      if (unknown === "refuse") {
        return `unknown feature ${JSON.stringify(key)}; features are ${SERVER_FEATURES.join(", ")}`;
      }
      continue;
    }
    if (typeof on !== "boolean") return `${key}: expected true or false`;
    patch[key] = on;
  }
  return patch;
}

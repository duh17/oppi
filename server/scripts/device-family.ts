/**
 * The device family of a client upload, for the telemetry review scripts: the
 * same rule as the importer's `device` column
 * (`scripts/manual/telemetry-import-sqlite.mjs`), so a CLI filter and a
 * dashboard filter select the same records. The Mac is the Catalyst build of
 * the app: it sends `kind: "mac"` and a `Mac…` model.
 */

export const DEVICE_FAMILIES = ["iPhone", "iPad", "Mac"] as const;
export type DeviceFamily = (typeof DEVICE_FAMILIES)[number] | "Other";

/** `undefined` when the record names neither a client kind nor a model (server records). */
export function deviceFamily(client: {
  kind?: unknown;
  deviceModel?: unknown;
}): DeviceFamily | undefined {
  const kind = typeof client.kind === "string" ? client.kind : undefined;
  const model = typeof client.deviceModel === "string" ? client.deviceModel.toLowerCase() : undefined;
  if (kind === "mac" || model?.startsWith("mac")) return "Mac";
  if (model?.startsWith("iphone")) return "iPhone";
  if (model?.startsWith("ipad")) return "iPad";
  return kind !== undefined || model !== undefined ? "Other" : undefined;
}

/** The `--device` value: `iphone`, `ipad`, or `mac`, in any case. */
export function parseDeviceFamily(raw: string, flag = "--device"): DeviceFamily {
  const family = DEVICE_FAMILIES.find((name) => name.toLowerCase() === raw.trim().toLowerCase());
  if (!family) throw new Error(`${flag} must be one of: iphone, ipad, mac`);
  return family;
}

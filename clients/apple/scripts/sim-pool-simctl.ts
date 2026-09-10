export type SimulatorDevice = {
  udid: string;
  name: string;
  state: string;
  isAvailable: boolean;
  deviceTypeIdentifier: string;
  runtime: string;
};

export type SimulatorRuntime = {
  identifier: string;
  platform: string;
  isAvailable: boolean;
  version: string;
  buildversion: string;
  name: string;
  bundlePath: string;
  runtimeRoot: string;
  isInternal?: boolean;
};

export function parseDevicesJson(raw: string): SimulatorDevice[] {
  const data = JSON.parse(raw) as { devices?: Record<string, Array<Record<string, unknown>>> };
  const devices: SimulatorDevice[] = [];
  for (const [runtime, list] of Object.entries(data.devices ?? {})) {
    for (const device of list) {
      devices.push({
        udid: String(device.udid ?? ""),
        name: String(device.name ?? ""),
        state: String(device.state ?? ""),
        isAvailable: Boolean(device.isAvailable),
        deviceTypeIdentifier: String(device.deviceTypeIdentifier ?? ""),
        runtime,
      });
    }
  }
  return devices;
}

export function parseRuntimesJson(raw: string): SimulatorRuntime[] {
  const data = JSON.parse(raw) as { runtimes?: Array<Record<string, unknown>> };
  return (data.runtimes ?? []).map((runtime) => ({
    identifier: String(runtime.identifier ?? ""),
    platform: String(runtime.platform ?? ""),
    isAvailable: Boolean(runtime.isAvailable),
    version: String(runtime.version ?? "0"),
    buildversion: String(runtime.buildversion ?? ""),
    name: String(runtime.name ?? ""),
    bundlePath: String(runtime.bundlePath ?? ""),
    runtimeRoot: String(runtime.runtimeRoot ?? ""),
    isInternal: Boolean(runtime.isInternal),
  }));
}

function versionKey(runtime: SimulatorRuntime): [number, number, number, string] {
  const parts = runtime.version.split(".").map((part) => {
    const value = Number(part);
    return Number.isFinite(value) ? value : 0;
  });
  return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0, runtime.buildversion];
}

export function isBetaRuntime(runtime: SimulatorRuntime): boolean {
  const build = runtime.buildversion.trim();
  if (/[a-z]$/.test(build)) {
    return true;
  }
  if (runtime.isInternal) {
    return true;
  }
  const text = `${runtime.name} ${runtime.bundlePath} ${runtime.runtimeRoot}`;
  return /(?:\bbeta\b|\bseed\b|release candidate|\brc\b)/i.test(text);
}

export function selectIosRuntime(
  runtimes: SimulatorRuntime[],
  policy: "latest" | "latest-stable",
): string | { error: string } {
  const ios = runtimes.filter((runtime) => runtime.platform === "iOS" && runtime.isAvailable);
  if (ios.length === 0) {
    return { error: `no available iOS runtime found for OPPI_SIM_RUNTIME_POLICY=${policy}` };
  }
  const candidates = policy === "latest-stable" ? ios.filter((runtime) => !isBetaRuntime(runtime)) : ios;
  if (candidates.length === 0) {
    return { error: `no available iOS runtime found for OPPI_SIM_RUNTIME_POLICY=${policy}` };
  }
  candidates.sort((left, right) => {
    const a = versionKey(left);
    const b = versionKey(right);
    if (a[0] !== b[0]) return a[0] - b[0];
    if (a[1] !== b[1]) return a[1] - b[1];
    if (a[2] !== b[2]) return a[2] - b[2];
    return a[3] < b[3] ? -1 : a[3] > b[3] ? 1 : 0;
  });
  return candidates[candidates.length - 1].identifier;
}

export function poolDeviceName(slot: number): string {
  return `Oppi-Pool-${slot}`;
}

export function findMatchingPoolDevice(
  devices: SimulatorDevice[],
  slot: number,
  runtime: string,
  deviceType: string,
): { match?: SimulatorDevice; mismatches: SimulatorDevice[] } {
  const name = poolDeviceName(slot);
  const mismatches: SimulatorDevice[] = [];
  for (const device of devices) {
    if (device.name !== name || !device.isAvailable) {
      continue;
    }
    if (device.runtime === runtime && device.deviceTypeIdentifier === deviceType) {
      return { match: device, mismatches };
    }
    mismatches.push(device);
  }
  return { mismatches };
}

export function shouldSkipPoolSlot(found: {
  match?: SimulatorDevice;
  mismatches: SimulatorDevice[];
}): boolean {
  return found.match == null && found.mismatches.length > 0;
}

export function deviceState(devices: SimulatorDevice[], udid: string): string | undefined {
  return devices.find((device) => device.udid === udid)?.state;
}

export function resultBundlePathForAttempt(path: string, attemptIndex: number): string {
  if (attemptIndex === 0) {
    return path;
  }
  if (path.endsWith(".xcresult")) {
    return `${path.slice(0, -".xcresult".length)}-retry${attemptIndex}.xcresult`;
  }
  return `${path}-retry${attemptIndex}`;
}

export function buildAttemptCommand(attemptIndex: number, args: string[]): string[] {
  const output: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "-resultBundlePath") {
      const original = args[i + 1];
      if (original == null) {
        throw new Error("-resultBundlePath requires a path");
      }
      output.push("-resultBundlePath", resultBundlePathForAttempt(original, attemptIndex));
      i += 1;
      continue;
    }
    if (arg.startsWith("-resultBundlePath=")) {
      const original = arg.slice("-resultBundlePath=".length);
      output.push(`-resultBundlePath=${resultBundlePathForAttempt(original, attemptIndex)}`);
      continue;
    }
    output.push(arg);
  }
  return output;
}

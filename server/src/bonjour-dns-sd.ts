import { spawn, spawnSync } from "node:child_process";
import type {
  BonjourAdvertisementHandle,
  BonjourAdvertiseInput,
  BonjourPublisher,
} from "./bonjour-advertiser.js";

export function buildDnsSdAdvertiseArgs(input: BonjourAdvertiseInput): string[] {
  const txtEntries = Object.entries(input.txt)
    .filter(([, value]) => typeof value === "string" && value.length > 0)
    .map(([key, value]) => `${key}=${value}`);

  return ["-R", input.serviceName, input.serviceType, "local", String(input.port), ...txtEntries];
}

export function isDnsSdAvailable(): boolean {
  const result = spawnSync("dns-sd", ["-h"], {
    stdio: ["ignore", "ignore", "ignore"],
  });

  if (result.error) {
    const error = result.error as NodeJS.ErrnoException;
    if (error.code === "ENOENT") {
      return false;
    }
  }

  return true;
}

class DnsSdAdvertisementHandle implements BonjourAdvertisementHandle {
  constructor(private readonly stopFn: () => void) {}

  stop(): void {
    this.stopFn();
  }
}

export class DnsSdBonjourPublisher implements BonjourPublisher {
  advertise(input: BonjourAdvertiseInput): BonjourAdvertisementHandle {
    const args = buildDnsSdAdvertiseArgs(input);
    const child = spawn("dns-sd", args, {
      stdio: ["ignore", "ignore", "pipe"],
    });

    child.stderr?.on("data", () => {
      // Intentionally ignore noisy stderr from dns-sd. The server already
      // logs explicit start/stop lifecycle events.
    });

    return new DnsSdAdvertisementHandle(() => {
      if (!child.killed) {
        child.kill("SIGTERM");
      }
    });
  }
}

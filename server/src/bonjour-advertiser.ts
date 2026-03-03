export const OPPI_BONJOUR_SERVICE_TYPE = "_oppi._tcp";
export const OPPI_BONJOUR_PROTOCOL_VERSION = "1";

const DEFAULT_FINGERPRINT_PREFIX_LENGTH = 16;

const TRUE_VALUES = new Set(["1", "true", "yes", "on"]);
const FALSE_VALUES = new Set(["0", "false", "no", "off"]);

export interface BonjourTxtRecord {
  v: string;
  sid: string;
  tfp?: string;
  ip?: string;
  p?: string;
}

export interface BonjourRecordInput {
  serverFingerprint: string;
  tlsCertFingerprint?: string;
  protocolVersion?: string;
  fingerprintPrefixLength?: number;
  lanHost?: string;
  port?: number;
}

export interface BonjourAdvertiseInput {
  serviceType: string;
  serviceName: string;
  port: number;
  txt: BonjourTxtRecord;
}

export interface BonjourAdvertisementHandle {
  stop(): void;
}

export interface BonjourPublisher {
  advertise(input: BonjourAdvertiseInput): BonjourAdvertisementHandle;
}

export function normalizeFingerprint(fingerprint: string): string {
  const trimmed = fingerprint.trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("sha256:")) {
    return trimmed.slice("sha256:".length);
  }
  return trimmed;
}

export function fingerprintPrefix(
  fingerprint: string,
  length: number = DEFAULT_FINGERPRINT_PREFIX_LENGTH,
): string {
  if (length <= 0) {
    return "";
  }

  const normalized = normalizeFingerprint(fingerprint);
  if (!normalized) {
    return "";
  }

  return normalized.slice(0, length);
}

export function buildBonjourTxtRecord(input: BonjourRecordInput): BonjourTxtRecord {
  const sid = fingerprintPrefix(
    input.serverFingerprint,
    input.fingerprintPrefixLength ?? DEFAULT_FINGERPRINT_PREFIX_LENGTH,
  );

  if (!sid) {
    throw new Error("serverFingerprint is required to build Bonjour TXT record");
  }

  const txt: BonjourTxtRecord = {
    v: input.protocolVersion ?? OPPI_BONJOUR_PROTOCOL_VERSION,
    sid,
  };

  const tfp = input.tlsCertFingerprint
    ? fingerprintPrefix(
        input.tlsCertFingerprint,
        input.fingerprintPrefixLength ?? DEFAULT_FINGERPRINT_PREFIX_LENGTH,
      )
    : "";

  if (tfp) {
    txt.tfp = tfp;
  }

  const lanHost = input.lanHost?.trim();
  if (lanHost) {
    txt.ip = lanHost;
  }

  if (input.port && Number.isInteger(input.port) && input.port > 0 && input.port <= 65_535) {
    txt.p = String(input.port);
  }

  return txt;
}

export function buildBonjourServiceName(
  serverFingerprint: string,
  prefix = "oppi",
  fingerprintPrefixLength: number = DEFAULT_FINGERPRINT_PREFIX_LENGTH,
): string {
  const sid = fingerprintPrefix(serverFingerprint, fingerprintPrefixLength);
  if (!sid) {
    throw new Error("serverFingerprint is required to build Bonjour service name");
  }
  return `${prefix}-${sid}`;
}

export function isBonjourEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env.OPPI_BONJOUR?.trim().toLowerCase();
  if (!raw) {
    return true;
  }

  if (TRUE_VALUES.has(raw)) {
    return true;
  }

  if (FALSE_VALUES.has(raw)) {
    return false;
  }

  return true;
}

export class BonjourAdvertiser {
  private activeAdvertisement: BonjourAdvertisementHandle | null = null;

  constructor(private readonly publisher: BonjourPublisher) {}

  get isAdvertising(): boolean {
    return this.activeAdvertisement !== null;
  }

  start(input: BonjourAdvertiseInput): void {
    this.stop();
    this.activeAdvertisement = this.publisher.advertise(input);
  }

  stop(): void {
    this.activeAdvertisement?.stop();
    this.activeAdvertisement = null;
  }
}

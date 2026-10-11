/**
 * Synthetic App Attest objects signed by a throwaway CA, so attestation and assertion checks
 * can be driven through every positive and negative case. Same structure Apple produces:
 * CBOR `{fmt, attStmt: {x5c, receipt}, authData}` and `{signature, authenticatorData}`.
 */

import { webcrypto } from "node:crypto";

const subtle = webcrypto.subtle;

// ─── DER ───

function length(n: number): Uint8Array {
  if (n < 0x80) return Uint8Array.of(n);
  if (n < 0x100) return Uint8Array.of(0x81, n);
  return Uint8Array.of(0x82, n >> 8, n & 0xff);
}

function concat(...parts: Uint8Array[]): Uint8Array {
  return Uint8Array.from(Buffer.concat(parts));
}

function tlv(tag: number, ...content: Uint8Array[]): Uint8Array {
  const body = concat(...content);
  return concat(Uint8Array.of(tag), length(body.length), body);
}

const seq = (...items: Uint8Array[]) => tlv(0x30, ...items);
const set = (...items: Uint8Array[]) => tlv(0x31, ...items);
const octets = (bytes: Uint8Array) => tlv(0x04, bytes);
const explicit = (n: number, ...items: Uint8Array[]) => tlv(0xa0 + n, ...items);

function integer(bytes: Uint8Array): Uint8Array {
  let value = bytes;
  while (value.length > 1 && value[0] === 0 && !(value[1]! & 0x80)) value = value.subarray(1);
  if (value[0]! & 0x80) value = concat(Uint8Array.of(0), value);
  return tlv(0x02, value);
}

function oid(dotted: string): Uint8Array {
  const parts = dotted.split(".").map(Number);
  const bytes = [parts[0]! * 40 + parts[1]!];
  for (const part of parts.slice(2)) {
    const chunk = [part & 0x7f];
    let value = part >>> 7;
    while (value > 0) {
      chunk.unshift((value & 0x7f) | 0x80);
      value >>>= 7;
    }
    bytes.push(...chunk);
  }
  return tlv(0x06, Uint8Array.from(bytes));
}

function name(commonName: string): Uint8Array {
  return seq(set(seq(oid("2.5.4.3"), tlv(0x0c, new TextEncoder().encode(commonName)))));
}

function utcTime(ms: number): Uint8Array {
  const iso = new Date(ms).toISOString();
  const text = `${iso.slice(2, 4)}${iso.slice(5, 7)}${iso.slice(8, 10)}${iso.slice(11, 13)}${iso.slice(14, 16)}${iso.slice(17, 19)}Z`;
  return tlv(0x17, new TextEncoder().encode(text));
}

function rawToDerSignature(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  return seq(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
}

type Curve = "P-256" | "P-384";
const SIG_OID: Record<Curve, string> = { "P-256": "1.2.840.10045.4.3.2", "P-384": "1.2.840.10045.4.3.3" };
const HASH: Record<Curve, "SHA-256" | "SHA-384"> = { "P-256": "SHA-256", "P-384": "SHA-384" };

export interface KeyPair {
  curve: Curve;
  privateKey: CryptoKey;
  spki: Uint8Array;
  point: Uint8Array;
}

export async function generateKey(curve: Curve): Promise<KeyPair> {
  const pair = (await subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  return {
    curve,
    privateKey: pair.privateKey,
    spki: new Uint8Array(await subtle.exportKey("spki", pair.publicKey)),
    point: new Uint8Array(await subtle.exportKey("raw", pair.publicKey)),
  };
}

export async function signDer(key: KeyPair, data: Uint8Array, hash = HASH[key.curve]): Promise<Uint8Array> {
  const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash }, key.privateKey, data));
  return rawToDerSignature(raw);
}

export async function certificate(input: {
  serial: number;
  issuer: string;
  subject: string;
  subjectKey: KeyPair;
  issuerKey: KeyPair;
  notBefore: number;
  notAfter: number;
  extensions?: Array<{ oid: string; value: Uint8Array }>;
}): Promise<Uint8Array> {
  const algorithm = seq(oid(SIG_OID[input.issuerKey.curve]));
  const extensions = input.extensions?.length
    ? [explicit(3, seq(...input.extensions.map((ext) => seq(oid(ext.oid), octets(ext.value)))))]
    : [];
  const tbs = seq(
    explicit(0, integer(Uint8Array.of(2))),
    integer(Uint8Array.of(input.serial)),
    algorithm,
    name(input.issuer),
    seq(utcTime(input.notBefore), utcTime(input.notAfter)),
    name(input.subject),
    input.subjectKey.spki,
    ...extensions,
  );
  const signature = await signDer(input.issuerKey, tbs);
  return seq(tbs, algorithm, tlv(0x03, Uint8Array.of(0), signature));
}

export function toPem(der: Uint8Array): string {
  const body = Buffer.from(der).toString("base64").replace(/(.{64})/g, "$1\n");
  return `-----BEGIN CERTIFICATE-----\n${body}\n-----END CERTIFICATE-----\n`;
}

// ─── CBOR ───

type CborInput = number | string | Uint8Array | CborInput[] | Map<string, CborInput>;

function cborHead(major: number, value: number): Uint8Array {
  if (value < 24) return Uint8Array.of((major << 5) | value);
  if (value < 0x100) return Uint8Array.of((major << 5) | 24, value);
  if (value < 0x10000) return Uint8Array.of((major << 5) | 25, value >> 8, value & 0xff);
  return Uint8Array.of((major << 5) | 26, value >>> 24, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff);
}

export function cbor(value: CborInput): Uint8Array {
  if (typeof value === "number") return cborHead(0, value);
  if (typeof value === "string") {
    const bytes = new TextEncoder().encode(value);
    return concat(cborHead(3, bytes.length), bytes);
  }
  if (value instanceof Uint8Array) return concat(cborHead(2, value.length), value);
  if (Array.isArray(value)) return concat(cborHead(4, value.length), ...value.map(cbor));
  const entries = [...value.entries()];
  return concat(cborHead(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)]));
}

// ─── App Attest ───

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await subtle.digest("SHA-256", data));
}

const DAY = 86_400_000;

export interface AppAttestCA {
  rootPem: string;
  root: KeyPair;
  intermediate: KeyPair;
  intermediateDer: Uint8Array;
}

/** basicConstraints values: `cA` TRUE (as Apple's CAs carry), or `cA` omitted (FALSE). */
const BASIC_CONSTRAINTS_OID = "2.5.29.19";
const CA_TRUE = seq(tlv(0x01, Uint8Array.of(0xff)));
const CA_FALSE = seq();

export async function createCA(
  now: number,
  /** basicConstraints on the intermediate: `ca` like Apple's, or a non-CA certificate. */
  intermediateConstraints: "ca" | "not-ca" | "absent" = "ca",
): Promise<AppAttestCA> {
  const root = await generateKey("P-384");
  const intermediate = await generateKey("P-384");
  const rootDer = await certificate({
    serial: 1,
    issuer: "Test App Attestation Root CA",
    subject: "Test App Attestation Root CA",
    subjectKey: root,
    issuerKey: root,
    notBefore: now - 365 * DAY,
    notAfter: now + 3650 * DAY,
    extensions: [{ oid: BASIC_CONSTRAINTS_OID, value: CA_TRUE }],
  });
  const intermediateDer = await certificate({
    serial: 2,
    issuer: "Test App Attestation Root CA",
    subject: "Test App Attestation CA 1",
    subjectKey: intermediate,
    issuerKey: root,
    notBefore: now - 365 * DAY,
    notAfter: now + 3650 * DAY,
    extensions:
      intermediateConstraints === "absent"
        ? []
        : [
            {
              oid: BASIC_CONSTRAINTS_OID,
              value: intermediateConstraints === "ca" ? CA_TRUE : CA_FALSE,
            },
          ],
  });
  return { rootPem: toPem(rootDer), root, intermediate, intermediateDer };
}

export interface AttestationOptions {
  appId: string;
  clientDataHash: Uint8Array;
  now: number;
  aaguid?: "development" | "production" | "bogus";
  counter?: number;
  /** Put a different nonce in the certificate. */
  wrongNonce?: boolean;
  /** Leaf validity ends before `now`. */
  expired?: boolean;
  /** Sign the leaf with an unrelated key instead of the intermediate. */
  untrustedIssuer?: boolean;
}

export interface Attestation {
  keyId: string;
  object: string;
  credential: KeyPair;
}

export async function createAttestation(ca: AppAttestCA, options: AttestationOptions): Promise<Attestation> {
  const credential = await generateKey("P-256");
  const keyId = await sha256(credential.point);
  const aaguid =
    options.aaguid === "production"
      ? concat(new TextEncoder().encode("appattest"), new Uint8Array(7))
      : options.aaguid === "bogus"
        ? new Uint8Array(16)
        : new TextEncoder().encode("appattestdevelop");
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, options.counter ?? 0);
  const coseKey = cbor(new Map<string, CborInput>([["kty", 2]]));
  const authData = concat(
    await sha256(new TextEncoder().encode(options.appId)),
    Uint8Array.of(0x40),
    counter,
    aaguid,
    Uint8Array.of(0, keyId.length),
    keyId,
    coseKey,
  );
  const nonce = options.wrongNonce
    ? new Uint8Array(32)
    : await sha256(concat(authData, options.clientDataHash));
  const issuerKey = options.untrustedIssuer ? await generateKey("P-384") : ca.intermediate;
  const leaf = await certificate({
    serial: 3,
    issuer: "Test App Attestation CA 1",
    subject: Buffer.from(keyId).toString("hex"),
    subjectKey: credential,
    issuerKey,
    notBefore: options.now - 2 * DAY,
    notAfter: options.expired ? options.now - DAY : options.now + 30 * DAY,
    extensions: [{ oid: "1.2.840.113635.100.8.2", value: seq(explicit(1, octets(nonce))) }],
  });
  const object = cbor(
    new Map<string, CborInput>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, CborInput>([["x5c", [leaf, ca.intermediateDer]], ["receipt", new Uint8Array(8)]])],
      ["authData", authData],
    ]),
  );
  return {
    keyId: Buffer.from(keyId).toString("base64"),
    object: Buffer.from(object).toString("base64"),
    credential,
  };
}

export async function createAssertion(input: {
  credential: KeyPair;
  appId: string;
  counter: number;
  clientDataHash: Uint8Array;
}): Promise<string> {
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, input.counter);
  const authenticatorData = concat(
    await sha256(new TextEncoder().encode(input.appId)),
    Uint8Array.of(0x40),
    counter,
  );
  const nonce = await sha256(concat(authenticatorData, input.clientDataHash));
  const signature = await signDer(input.credential, nonce);
  return Buffer.from(
    cbor(new Map<string, CborInput>([["signature", signature], ["authenticatorData", authenticatorData]])),
  ).toString("base64");
}

export { sha256 };

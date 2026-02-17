import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as signBytes,
  verify as verifyBytes,
  type KeyObject,
  type JsonWebKey,
} from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname } from "node:path";
import { generateId } from "./id.js";
import type { SecurityProfile, ServerIdentityConfig } from "./types.js";

export interface InviteV2Payload {
  host: string;
  port: number;
  token: string;
  name: string;
  fingerprint: string;
  securityProfile: SecurityProfile;
}

export interface InviteV2Envelope {
  v: 2;
  alg: "Ed25519";
  kid: string;
  iat: number;
  exp: number;
  nonce: string;
  publicKey: string; // base64url raw Ed25519 public key (32 bytes)
  payload: InviteV2Payload;
  sig: string; // base64url signature over invite signing input
}

export interface IdentityMaterial {
  keyId: string;
  algorithm: "ed25519";
  privateKeyPem: string;
  publicKeyPem: string;
  publicKeyRaw: string;
  fingerprint: string;
}

function expandHome(path: string): string {
  if (!path.startsWith("~/")) return path;
  return path.replace(/^~\//, `${homedir()}/`);
}

function getPublicKeyRaw(publicKeyPem: string): string {
  const publicKey = createPublicKey(publicKeyPem);
  const jwk = publicKey.export({ format: "jwk" }) as JsonWebKey;
  if (typeof jwk.x !== "string" || jwk.x.length === 0) {
    throw new Error("Unable to derive Ed25519 public key raw bytes from identity key");
  }
  return jwk.x;
}

function fingerprintForPublicKeyRaw(publicKeyRaw: string): string {
  const raw = Buffer.from(publicKeyRaw, "base64url");
  const digest = createHash("sha256").update(raw).digest("base64url");
  return `sha256:${digest}`;
}

function readExistingIdentity(privatePath: string, publicPath: string): IdentityMaterial | null {
  if (!existsSync(privatePath)) return null;

  const privateKeyPem = readFileSync(privatePath, "utf-8");
  const privateKey = createPrivateKey(privateKeyPem);

  let publicKeyPem: string;
  if (existsSync(publicPath)) {
    publicKeyPem = readFileSync(publicPath, "utf-8");
  } else {
    const publicKey = createPublicKey(privateKey);
    publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
    mkdirSync(dirname(publicPath), { recursive: true, mode: 0o700 });
    writeFileSync(publicPath, publicKeyPem, { mode: 0o644 });
  }

  const publicKeyRaw = getPublicKeyRaw(publicKeyPem);
  return {
    keyId: "",
    algorithm: "ed25519",
    privateKeyPem,
    publicKeyPem,
    publicKeyRaw,
    fingerprint: fingerprintForPublicKeyRaw(publicKeyRaw),
  };
}

export function ensureIdentityMaterial(identity: ServerIdentityConfig): IdentityMaterial {
  if (!identity.enabled) {
    throw new Error("Server identity is disabled; cannot sign invite v2");
  }
  if (identity.algorithm !== "ed25519") {
    throw new Error(`Unsupported identity algorithm: ${identity.algorithm}`);
  }

  const privatePath = expandHome(identity.privateKeyPath);
  const publicPath = expandHome(identity.publicKeyPath);

  const existing = readExistingIdentity(privatePath, publicPath);
  if (existing) {
    return {
      ...existing,
      keyId: identity.keyId,
      algorithm: "ed25519",
    };
  }

  mkdirSync(dirname(privatePath), { recursive: true, mode: 0o700 });
  mkdirSync(dirname(publicPath), { recursive: true, mode: 0o700 });

  const generated = generateKeyPairSync("ed25519");
  const privateKeyPem = generated.privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const publicKeyPem = generated.publicKey.export({ type: "spki", format: "pem" }).toString();

  writeFileSync(privatePath, privateKeyPem, { mode: 0o600 });
  writeFileSync(publicPath, publicKeyPem, { mode: 0o644 });

  const publicKeyRaw = getPublicKeyRaw(publicKeyPem);
  return {
    keyId: identity.keyId,
    algorithm: "ed25519",
    privateKeyPem,
    publicKeyPem,
    publicKeyRaw,
    fingerprint: fingerprintForPublicKeyRaw(publicKeyRaw),
  };
}

export function buildInviteSigningInput(
  envelope: Omit<InviteV2Envelope, "sig">,
): string {
  const p = envelope.payload;
  return [
    `v=${envelope.v}`,
    `alg=${envelope.alg}`,
    `kid=${envelope.kid}`,
    `iat=${envelope.iat}`,
    `exp=${envelope.exp}`,
    `nonce=${envelope.nonce}`,
    `publicKey=${envelope.publicKey}`,
    `host=${p.host}`,
    `port=${p.port}`,
    `token=${p.token}`,
    `name=${p.name}`,
    `fingerprint=${p.fingerprint}`,
    `securityProfile=${p.securityProfile}`,
  ].join("\n");
}

function signInviteInput(signingInput: string, privateKey: KeyObject): string {
  const signature = signBytes(null, Buffer.from(signingInput, "utf-8"), privateKey);
  return signature.toString("base64url");
}

export function createSignedInviteV2(
  identity: IdentityMaterial,
  payload: InviteV2Payload,
  maxAgeSeconds: number,
  nowMs: number = Date.now(),
): InviteV2Envelope {
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + maxAgeSeconds;

  const unsigned: Omit<InviteV2Envelope, "sig"> = {
    v: 2,
    alg: "Ed25519",
    kid: identity.keyId,
    iat,
    exp,
    nonce: generateId(16),
    publicKey: identity.publicKeyRaw,
    payload,
  };

  const signingInput = buildInviteSigningInput(unsigned);
  const privateKey = createPrivateKey(identity.privateKeyPem);
  const sig = signInviteInput(signingInput, privateKey);

  return {
    ...unsigned,
    sig,
  };
}

export function verifyInviteV2(envelope: InviteV2Envelope): boolean {
  try {
    const unsigned: Omit<InviteV2Envelope, "sig"> = {
      v: envelope.v,
      alg: envelope.alg,
      kid: envelope.kid,
      iat: envelope.iat,
      exp: envelope.exp,
      nonce: envelope.nonce,
      publicKey: envelope.publicKey,
      payload: envelope.payload,
    };

    const signingInput = buildInviteSigningInput(unsigned);
    const publicJwk: JsonWebKey = {
      kty: "OKP",
      crv: "Ed25519",
      x: envelope.publicKey,
    };
    const publicKey = createPublicKey({ key: publicJwk, format: "jwk" });
    return verifyBytes(
      null,
      Buffer.from(signingInput, "utf-8"),
      publicKey,
      Buffer.from(envelope.sig, "base64url"),
    );
  } catch {
    return false;
  }
}

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  type JsonWebKey,
} from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface IdentityMaterial {
  keyId: string;
  algorithm: "ed25519";
  privateKeyPem: string;
  publicKeyPem: string;
  publicKeyRaw: string;
  fingerprint: string;
}

export interface IdentityConfig {
  keyId: string;
  privateKeyPath: string;
  publicKeyPath: string;
}

export function identityConfigForDataDir(dataDir: string): IdentityConfig {
  return {
    keyId: "srv-default",
    privateKeyPath: join(dataDir, "identity_ed25519"),
    publicKeyPath: join(dataDir, "identity_ed25519.pub"),
  };
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

export function ensureIdentityMaterial(identity: IdentityConfig): IdentityMaterial {
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

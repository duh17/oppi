/**
 * App Attest verification (Apple, "Validating apps that connect to your server").
 * Attestation proves a genuine Oppi build on Apple hardware at registration; assertions
 * sign later management requests with the same Secure Enclave key.
 */

import { bytesEqual, concatBytes, sha256, utf8 } from "./bytes.js";
import { cborMapGet, decodeCbor } from "./cbor.js";
import {
  OID,
  derChildren,
  isIssuedBy,
  parseCertificate,
  readDer,
  verifyEcdsa,
  type Certificate,
} from "./x509.js";

export type AttestationEnvironment = "development" | "production";

const AAGUID_DEVELOPMENT = utf8("appattestdevelop");
const AAGUID_PRODUCTION = concatBytes(utf8("appattest"), new Uint8Array(7));

export interface VerifiedAttestation {
  /** DER SubjectPublicKeyInfo of the App Attest key (P-256). */
  publicKeySpki: Uint8Array;
  environment: AttestationEnvironment;
}

export type AttestationResult = { ok: true; value: VerifiedAttestation } | { ok: false; reason: string };

function fail(reason: string): { ok: false; reason: string } {
  return { ok: false, reason };
}

/** The nonce the credential certificate carries: SEQUENCE { [1] EXPLICIT OCTET STRING }. */
function certificateNonce(cert: Certificate): Uint8Array | null {
  const value = cert.extensions.get(OID.appAttestNonce);
  if (!value) return null;
  try {
    const sequence = readDer(value);
    const tagged = derChildren(sequence).find((node) => node.tag === 0xa1);
    const octets = tagged ? derChildren(tagged)[0] : undefined;
    return octets && octets.tag === 0x04 ? octets.content : null;
  } catch {
    return null;
  }
}

export async function verifyAttestation(input: {
  attestationObject: Uint8Array;
  keyId: Uint8Array;
  clientDataHash: Uint8Array;
  appId: string;
  trustRoot: Certificate;
  now: number;
}): Promise<AttestationResult> {
  let decoded;
  try {
    decoded = decodeCbor(input.attestationObject);
  } catch {
    return fail("cbor");
  }
  if (cborMapGet(decoded, "fmt") !== "apple-appattest") return fail("format");
  const statement = cborMapGet(decoded, "attStmt");
  const authData = cborMapGet(decoded, "authData");
  const x5c = cborMapGet(statement ?? null, "x5c");
  if (!(authData instanceof Uint8Array) || !Array.isArray(x5c) || x5c.length < 2) {
    return fail("structure");
  }
  const [leafDer, intermediateDer] = x5c;
  if (!(leafDer instanceof Uint8Array) || !(intermediateDer instanceof Uint8Array)) {
    return fail("structure");
  }

  // 1. Chain: credential certificate <- intermediate <- Apple App Attestation Root CA.
  let leaf: Certificate;
  let intermediate: Certificate;
  try {
    leaf = parseCertificate(leafDer);
    intermediate = parseCertificate(intermediateDer);
  } catch {
    return fail("certificate");
  }
  for (const cert of [leaf, intermediate, input.trustRoot]) {
    if (input.now < cert.notBefore || input.now > cert.notAfter) return fail("certificate_validity");
  }
  // Only a CA may issue the credential certificate.
  if (!intermediate.isCA) return fail("chain");
  if (!(await isIssuedBy(leaf, intermediate)) || !(await isIssuedBy(intermediate, input.trustRoot))) {
    return fail("chain");
  }

  // 2-3. nonce = SHA-256(authData || clientDataHash) equals the certificate's nonce.
  const nonce = await sha256(concatBytes(authData, input.clientDataHash));
  const certNonce = certificateNonce(leaf);
  if (!certNonce || !bytesEqual(certNonce, nonce)) return fail("nonce");

  // 4. keyId is SHA-256 of the credential public key.
  if (leaf.curve !== "P-256" || leaf.publicKeyPoint.length !== 65) return fail("key");
  if (!bytesEqual(await sha256(leaf.publicKeyPoint), input.keyId)) return fail("key_id");

  // 5-8. Authenticator data.
  if (authData.length < 55) return fail("auth_data");
  const rpIdHash = authData.subarray(0, 32);
  if (!bytesEqual(rpIdHash, await sha256(utf8(input.appId)))) return fail("app_id");
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter !== 0) return fail("counter");
  const aaguid = authData.subarray(37, 53);
  const environment = bytesEqual(aaguid, AAGUID_DEVELOPMENT)
    ? "development"
    : bytesEqual(aaguid, AAGUID_PRODUCTION)
      ? "production"
      : null;
  if (!environment) return fail("aaguid");
  const credentialIdLength = (authData[53]! << 8) | authData[54]!;
  const credentialId = authData.subarray(55, 55 + credentialIdLength);
  if (!bytesEqual(credentialId, input.keyId)) return fail("credential_id");

  return { ok: true, value: { publicKeySpki: leaf.spki, environment } };
}

export type AssertionResult = { ok: true; counter: number } | { ok: false; reason: string };

/**
 * Check an assertion's signature and app ID. The caller enforces that `counter` exceeds the
 * stored counter, atomically with storing it.
 */
export async function verifyAssertion(input: {
  assertion: Uint8Array;
  clientDataHash: Uint8Array;
  publicKeySpki: Uint8Array;
  appId: string;
}): Promise<AssertionResult> {
  let decoded;
  try {
    decoded = decodeCbor(input.assertion);
  } catch {
    return fail("cbor");
  }
  const signature = cborMapGet(decoded, "signature");
  const authenticatorData = cborMapGet(decoded, "authenticatorData");
  if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array)) {
    return fail("structure");
  }
  if (authenticatorData.length < 37) return fail("auth_data");
  if (!bytesEqual(authenticatorData.subarray(0, 32), await sha256(utf8(input.appId)))) {
    return fail("app_id");
  }
  const nonce = await sha256(concatBytes(authenticatorData, input.clientDataHash));
  const valid = await verifyEcdsa({
    spki: input.publicKeySpki,
    curve: "P-256",
    hash: "SHA-256",
    signatureDer: signature,
    data: nonce,
  });
  if (!valid) return fail("signature");
  const counter = new DataView(
    authenticatorData.buffer,
    authenticatorData.byteOffset + 33,
    4,
  ).getUint32(0);
  return { ok: true, counter };
}

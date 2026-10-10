/**
 * Minimal DER and X.509 reading for the App Attest certificate chain, with ECDSA signature
 * checks through WebCrypto. Only what verification needs: TBS bytes, names, validity,
 * subject public key, extensions, and the signature.
 */

import { bytesEqual } from "./bytes.js";

export interface DerNode {
  tag: number;
  /** Full encoding: tag, length, and content. */
  der: Uint8Array;
  content: Uint8Array;
}

export function readDer(bytes: Uint8Array, offset = 0): DerNode & { end: number } {
  const tag = bytes[offset];
  if (tag === undefined) throw new Error("der: truncated");
  let cursor = offset + 1;
  let length = bytes[cursor];
  if (length === undefined) throw new Error("der: truncated");
  cursor += 1;
  if (length & 0x80) {
    const lengthBytes = length & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 3) throw new Error("der: unsupported length");
    length = 0;
    for (let index = 0; index < lengthBytes; index += 1) {
      const next = bytes[cursor];
      if (next === undefined) throw new Error("der: truncated");
      length = (length << 8) | next;
      cursor += 1;
    }
  }
  const end = cursor + length;
  if (end > bytes.length) throw new Error("der: truncated");
  return { tag, der: bytes.subarray(offset, end), content: bytes.subarray(cursor, end), end };
}

/** Children of a constructed node (SEQUENCE, SET, or a constructed context tag). */
export function derChildren(node: DerNode): DerNode[] {
  const children: DerNode[] = [];
  let offset = 0;
  while (offset < node.content.length) {
    const child = readDer(node.content, offset);
    children.push(child);
    offset = child.end;
  }
  return children;
}

function oidToString(content: Uint8Array): string {
  const first = content[0] ?? 0;
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (let index = 1; index < content.length; index += 1) {
    const byte = content[index]!;
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function parseTime(node: DerNode): number {
  const text = new TextDecoder().decode(node.content);
  const match =
    node.tag === 0x17
      ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
      : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
  if (!match) throw new Error("x509: bad time");
  let year = Number(match[1]);
  if (node.tag === 0x17) year += year < 50 ? 2000 : 1900;
  return Date.UTC(
    year,
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6]),
  );
}

export const OID = {
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  ecdsaWithSha384: "1.2.840.10045.4.3.3",
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  appAttestNonce: "1.2.840.113635.100.8.2",
} as const;

export interface Certificate {
  tbs: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  /** DER SubjectPublicKeyInfo. */
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  /** Uncompressed EC point. */
  publicKeyPoint: Uint8Array;
  signatureAlgorithm: string;
  /** DER ECDSA-Sig-Value. */
  signature: Uint8Array;
  extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const root = readDer(der);
  if (root.end !== der.length || root.tag !== 0x30) throw new Error("x509: not a certificate");
  const [tbsNode, algNode, sigNode] = derChildren(root);
  if (!tbsNode || !algNode || !sigNode || sigNode.tag !== 0x03) throw new Error("x509: malformed");
  const tbsFields = derChildren(tbsNode);
  // Optional [0] version comes first.
  const fields = tbsFields[0]?.tag === 0xa0 ? tbsFields.slice(1) : tbsFields;
  const [, , issuer, validity, subject, spkiNode, ...rest] = fields;
  if (!issuer || !validity || !subject || !spkiNode) throw new Error("x509: malformed tbs");
  const [notBefore, notAfter] = derChildren(validity);
  if (!notBefore || !notAfter) throw new Error("x509: malformed validity");

  const [spkiAlg, spkiKey] = derChildren(spkiNode);
  if (!spkiAlg || !spkiKey || spkiKey.tag !== 0x03) throw new Error("x509: malformed key");
  const [keyType, curveOid] = derChildren(spkiAlg).map((node) => oidToString(node.content));
  if (keyType !== OID.ecPublicKey) throw new Error("x509: not an EC key");
  const curve = curveOid === OID.p256 ? "P-256" : curveOid === OID.p384 ? "P-384" : null;
  if (!curve) throw new Error("x509: unsupported curve");

  const extensions = new Map<string, Uint8Array>();
  const extensionsWrapper = rest.find((node) => node.tag === 0xa3);
  if (extensionsWrapper) {
    const [list] = derChildren(extensionsWrapper);
    for (const extension of list ? derChildren(list) : []) {
      const parts = derChildren(extension);
      const id = parts[0];
      const value = parts[parts.length - 1];
      if (id && value && value.tag === 0x04) extensions.set(oidToString(id.content), value.content);
    }
  }

  const [algOid] = derChildren(algNode);
  return {
    tbs: tbsNode.der,
    issuer: issuer.der,
    subject: subject.der,
    notBefore: parseTime(notBefore),
    notAfter: parseTime(notAfter),
    spki: spkiNode.der,
    curve,
    publicKeyPoint: spkiKey.content.subarray(1),
    signatureAlgorithm: algOid ? oidToString(algOid.content) : "",
    signature: sigNode.content.subarray(1),
    extensions,
  };
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

/** DER ECDSA-Sig-Value to the fixed-width `r || s` WebCrypto expects. */
export function derSignatureToRaw(der: Uint8Array, size: number): Uint8Array {
  const sequence = readDer(der);
  if (sequence.tag !== 0x30 || sequence.end !== der.length) throw new Error("ecdsa: bad signature");
  const [r, s] = derChildren(sequence);
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new Error("ecdsa: bad signature");
  const out = new Uint8Array(size * 2);
  for (const [index, part] of [r.content, s.content].entries()) {
    let value = part;
    while (value.length > size && value[0] === 0) value = value.subarray(1);
    if (value.length > size) throw new Error("ecdsa: bad signature");
    out.set(value, index * size + (size - value.length));
  }
  return out;
}

const HASH_FOR_ALGORITHM: Record<string, "SHA-256" | "SHA-384"> = {
  [OID.ecdsaWithSha256]: "SHA-256",
  [OID.ecdsaWithSha384]: "SHA-384",
};

/** Verify a DER ECDSA signature with an EC public key given as SPKI. */
export async function verifyEcdsa(input: {
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  hash: "SHA-256" | "SHA-384";
  signatureDer: Uint8Array;
  data: Uint8Array;
}): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      input.spki as BufferSource,
      { name: "ECDSA", namedCurve: input.curve },
      false,
      ["verify"],
    );
    const raw = derSignatureToRaw(input.signatureDer, input.curve === "P-256" ? 32 : 48);
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: input.hash },
      key,
      raw as BufferSource,
      input.data as BufferSource,
    );
  } catch {
    return false;
  }
}

/** `child` was issued by `issuer`: names chain and the signature verifies. */
export async function isIssuedBy(child: Certificate, issuer: Certificate): Promise<boolean> {
  const hash = HASH_FOR_ALGORITHM[child.signatureAlgorithm];
  if (!hash || !bytesEqual(child.issuer, issuer.subject)) return false;
  return verifyEcdsa({
    spki: issuer.spki,
    curve: issuer.curve,
    hash,
    signatureDer: child.signature,
    data: child.tbs,
  });
}

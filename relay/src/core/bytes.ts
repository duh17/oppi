/** Byte helpers on WebCrypto and standard globals only, so core runs on Workers and Node. */

const BASE64URL_ALPHABET = /^[A-Za-z0-9_-]*$/;
const BASE64_ALPHABET = /^[A-Za-z0-9+/]*={0,2}$/;

export function isBase64url(value: string): boolean {
  return BASE64URL_ALPHABET.test(value) && value.length % 4 !== 1;
}

export function base64urlDecode(value: string): Uint8Array | null {
  if (!isBase64url(value)) return null;
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return base64Decode(normalized + "=".repeat((4 - (normalized.length % 4)) % 4));
}

export function base64Decode(value: string): Uint8Array | null {
  if (!BASE64_ALPHABET.test(value) || value.length % 4 !== 0) return null;
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
}

export function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) diff |= left[index]! ^ right[index]!;
  return diff === 0;
}

export const utf8 = (value: string): Uint8Array => new TextEncoder().encode(value);

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

/** base64url(SHA-256(UTF-8 value)): how secrets are stored and compared. */
export async function secretHash(value: string): Promise<string> {
  return base64urlEncode(await sha256(utf8(value)));
}

export function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytes;
}

export function randomId(prefix: string): string {
  return `${prefix}${base64urlEncode(randomBytes(16))}`;
}

/** Constant-time comparison of two stored hashes. */
export function hashesEqual(left: string, right: string): boolean {
  return bytesEqual(utf8(left), utf8(right));
}

/**
 * Authenticated HTTP/WebSocket principal after the server auth shell.
 * Device `at_` tokens are the only paired-HTTPS callers.
 */

export type RequestPrincipal =
  | { kind: "owner" }
  | { kind: "device"; deviceId: string; tokenClass: "at_"; expiresAt?: number };

export function isDeviceAccessPrincipal(
  principal: RequestPrincipal | undefined,
): principal is Extract<RequestPrincipal, { kind: "device" }> {
  return principal?.kind === "device" && principal.tokenClass === "at_";
}

// ─── Push ───

/**
 * APNs host a device token belongs to. Tokens only work on the host that issued them:
 * Xcode development-signed builds get `sandbox` tokens; TestFlight and App Store builds
 * get `production` tokens.
 */
export type APNsEnvironment = "sandbox" | "production";

/** "apns" for regular alerts, "liveactivity" for a Live Activity push token. */
export type PushTokenType = "apns" | "liveactivity";

export interface RegisterDeviceTokenRequest {
  /** APNs device token (hex string from iOS) */
  deviceToken: string;
  tokenType?: PushTokenType;
  /** Environment of the app's signed `aps-environment` entitlement. */
  apnsEnvironment: APNsEnvironment;
}

/**
 * One stored push token. Owned by the paired device that registered it: revoking that
 * device removes it, and APNs rejections prune it.
 */
export interface PushDeviceToken {
  /** `DeviceRecord.id` of the registering device. */
  deviceId: string;
  tokenType: PushTokenType;
  token: string;
  environment: APNsEnvironment;
  registeredAt: number;
}

import { fileURLToPath } from "node:url";

import {
  DESKTOP_VIEW_COMPANION_FRAME_JSON,
  DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
  DESKTOP_VIEW_COMPANION_PATH,
  DESKTOP_VIEW_COMPANION_UPGRADE,
  DESKTOP_VIEW_ERROR,
  DESKTOP_VIEW_FEATURE_H264_AVCC,
  DESKTOP_VIEW_FATAL_ERROR_MAX,
  DESKTOP_VIEW_FATAL_ERROR_MIN,
  DESKTOP_VIEW_MEDIA_HEADER_BYTES,
  DESKTOP_VIEW_STREAM_PATH,
  DESKTOP_VIEW_WIRE_VERSION,
  type DesktopViewAck,
  type DesktopViewCompanionControl,
  type DesktopViewEncode,
  type DesktopViewErrorMessage,
  type DesktopViewHello,
  type DesktopViewPhoneControl,
  type DesktopViewPing,
  type DesktopViewPong,
} from "../src/types/protocol.js";
import { serializeProtocolFixture } from "./protocol-fixtures.js";

export const DESKTOP_VIEW_STREAM_SNAPSHOT_FILE = fileURLToPath(
  new URL("../../protocol/desktop-view-stream.json", import.meta.url),
);
export const DESKTOP_VIEW_STREAM_FIXTURE_DESCRIPTION =
  "Experimental desktop live-view stream frames — updated by npm run protocol:fixtures:update";

const hello: DesktopViewHello = {
  type: "hello",
  version: DESKTOP_VIEW_WIRE_VERSION,
  features: [DESKTOP_VIEW_FEATURE_H264_AVCC],
  grantId: "11111111-1111-4111-8111-111111111111",
  deviceId: "dev-paired-1",
  surface: { windowId: 42, title: "Notes" },
  expiresAt: "2026-10-10T12:00:00.000Z",
};

const encode: DesktopViewEncode = {
  type: "encode",
  frameId: 1,
  bitrate: 1_800_000,
  fps: 30,
  scale: 0.25,
  keyframe: true,
};

const ack: DesktopViewAck = {
  type: "ack",
  frameId: 1,
  receivedAt: 1_770_000_000_100,
};

const ping: DesktopViewPing = { type: "ping", t: 1_770_000_000_000 };
const pong: DesktopViewPong = { type: "pong", t: 1_770_000_000_000 };

const grantRevoked: DesktopViewErrorMessage = {
  type: "error",
  code: DESKTOP_VIEW_ERROR.grantRevoked,
  message: "View grant revoked",
  fatal: true,
};

const unknownSkipped: DesktopViewPhoneControl | { type: string } = {
  type: "future_control",
  extra: true,
} as unknown as DesktopViewPhoneControl;

const PHONE: Record<string, DesktopViewPhoneControl | DesktopViewHello> = {
  hello,
  ping,
  pong,
  ack,
  error_grant_revoked: grantRevoked,
};

const COMPANION: Record<string, DesktopViewCompanionControl> = {
  hello,
  encode,
  error_grant_revoked: grantRevoked,
};

export function buildDesktopViewStreamMessages(): Record<string, unknown> {
  return {
    ...Object.fromEntries(Object.entries(PHONE).map(([key, value]) => [`phone.${key}`, value])),
    ...Object.fromEntries(
      Object.entries(COMPANION).map(([key, value]) => [`companion.${key}`, value]),
    ),
    "compat.unknown_type": unknownSkipped,
    wire: {
      streamPath: DESKTOP_VIEW_STREAM_PATH,
      companionPath: DESKTOP_VIEW_COMPANION_PATH,
      companionUpgrade: DESKTOP_VIEW_COMPANION_UPGRADE,
      version: DESKTOP_VIEW_WIRE_VERSION,
      mediaHeaderBytes: DESKTOP_VIEW_MEDIA_HEADER_BYTES,
      companionFrameJson: DESKTOP_VIEW_COMPANION_FRAME_JSON,
      companionFrameMedia: DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
      avcc: true,
      mediaLayout: {
        version: { offset: 0, bits: 8 },
        flags: { offset: 1, bits: 8, keyframeBit: 0 },
        headerBytes: { offset: 2, bits: 8 },
        reserved: { offset: 3, bits: 8 },
        frameId: { offset: 4, bits: 32, endian: "be" },
        capturedAtMs: { offset: 8, bits: 64, endian: "be" },
        width: { offset: 16, bits: 16, endian: "be" },
        height: { offset: 18, bits: 16, endian: "be" },
        payloadBytes: { offset: 20, bits: 32, endian: "be" },
        payload: { offset: 24, format: "h264-avcc" },
      },
      fatalErrorRange: { min: DESKTOP_VIEW_FATAL_ERROR_MIN, max: DESKTOP_VIEW_FATAL_ERROR_MAX },
      errors: DESKTOP_VIEW_ERROR,
    },
  };
}

export function serializeDesktopViewStreamFixture(): string {
  return serializeProtocolFixture(
    DESKTOP_VIEW_STREAM_FIXTURE_DESCRIPTION,
    buildDesktopViewStreamMessages(),
  );
}

export type IconChoice =
  | { kind: "default" }
  | { kind: "emoji"; value: string }
  | { kind: "symbol"; name: string }
  | {
      kind: "genmoji";
      assetId: string;
      contentDescription: string;
    }
  /** An image the person imported (PNG, APNG, GIF, or WebP), stored as an icon asset. */
  | { kind: "image"; assetId: string };

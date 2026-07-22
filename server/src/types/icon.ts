export type IconChoice =
  | { kind: "default" }
  | { kind: "emoji"; value: string }
  | { kind: "symbol"; name: string }
  | {
      kind: "genmoji";
      assetId: string;
      contentDescription: string;
    };

/** An SF Symbols effect a symbol icon plays as an idle loop where icons animate. */
export type IconSymbolEffect = "bounce" | "pulse" | "breathe" | "wiggle" | "rotate";

export type IconChoice =
  | { kind: "default" }
  | { kind: "emoji"; value: string }
  | { kind: "symbol"; name: string; effect?: IconSymbolEffect }
  | {
      kind: "genmoji";
      assetId: string;
      contentDescription: string;
    }
  /** An image the person imported (WebP, still or animated, or PNG), stored as an icon asset. */
  | { kind: "image"; assetId: string };

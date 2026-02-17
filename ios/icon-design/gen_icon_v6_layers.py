#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
#   "numpy>=2.0",
# ]
# ///
"""
Oppi icon v6 — iOS 26 composable icon layers.

iOS 26 .icon format:
  - Foreground: glyph on transparent background (system adds glass/depth/shadow)
  - Fill color: system generates gradient background from your color
  - Translucency: system applies glass material
  - Shadow: system adds depth shadow

We provide the foreground layer only. System does the rest.
Also generates a pre-baked fallback for .appiconset (App Store, older iOS).
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np
import math
import json
import shutil
from pathlib import Path

SIZE = 1024


def find_font(target_size: int) -> ImageFont.FreeTypeFont:
    paths = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/Library/Fonts/SF-Pro-Display-Regular.otf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in paths:
        try:
            f = ImageFont.truetype(p, target_size)
            test = Image.new("L", (50, 50))
            d = ImageDraw.Draw(test)
            bb = d.textbbox((0, 0), "π", font=f)
            if bb[2] - bb[0] > 5:
                print(f"  Font: {p} @ {target_size}px")
                return f
        except (OSError, IOError):
            pass
    return ImageFont.load_default()


def render_foreground(size: int, font_size: int) -> Image.Image:
    """White π on transparent background — the iOS 26 foreground layer.

    Optically centered: π's bar is heavy at top, so we shift up ~2%.
    The glyph should occupy ~65-70% of the icon area for a bold presence
    while leaving enough margin for the system's rounded-rect mask.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    font = find_font(font_size)

    # Measure glyph bounds
    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]

    # Center horizontally, optical center vertically (shift up 2%)
    x = (size - tw) // 2 - bb[0]
    y = (size - th) // 2 - bb[1] - int(size * 0.02)

    draw.text((x, y), "π", fill=(255, 255, 255, 255), font=font)
    return img


# ─── Pre-baked fallback (for .appiconset / App Store) ───

def gradient_bg(size: int) -> Image.Image:
    """Deep blue gradient derived from tokyoBlue #7AA2F7.
    Background is a very dark desaturated blue, center lifts toward the accent."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        for x in range(size):
            t = y / size
            cx = (x / size - 0.5) * 2
            cy = (y / size - 0.46) * 2
            d = math.sqrt(cx * cx + cy * cy)
            lift = max(0, 1 - d * 0.9) ** 1.8
            # Dark navy base → deep blue
            r = int(max(4, 12 - t * 6 + lift * 16))
            g = int(max(6, 16 + t * 2 + lift * 18))
            b = int(max(28, 52 - t * 14 + lift * 42))
            arr[y, x] = [r, g, b, 255]
    return Image.fromarray(arr, "RGBA")


def center_glow(size: int) -> Image.Image:
    """Glow derived from tokyoBlue #7AA2F7 — deep saturated blue light source."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    gcx, gcy = 0.50, 0.42
    for y in range(size):
        for x in range(size):
            dx = (x / size - gcx) / 0.36
            dy = (y / size - gcy) / 0.32
            d2 = dx * dx + dy * dy
            if d2 < 6.0:
                v = math.exp(-d2 * 1.2) * 0.55
                # Tokyo blue glow: #7AA2F7 darkened for background
                arr[y, x] = [60, 90, 210, int(v * 255)]
    img = Image.fromarray(arr, "RGBA")
    return img.filter(ImageFilter.GaussianBlur(radius=60))


def glass_fill(mask: Image.Image, size: int) -> Image.Image:
    """Glass gradient with blue tint — top bright, bottom cool blue-grey."""
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    out = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        t = y / size
        # Top: near-white with subtle blue. Bottom: cool blue-grey.
        r = int(235 - t * 80)
        g = int(240 - t * 75)
        b = int(252 - t * 30)
        a_factor = 0.95 - t * 0.40
        row = mask_arr[y]
        idx = row > 0.01
        if np.any(idx):
            out[y, idx, 0] = min(255, r)
            out[y, idx, 1] = min(255, g)
            out[y, idx, 2] = min(255, b)
            out[y, idx, 3] = (a_factor * row[idx] * 255).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def top_edge_highlight(mask: Image.Image, size: int, shift: int = 5) -> Image.Image:
    m = np.array(mask).astype(np.float32)
    edge = np.zeros_like(m)
    for y in range(shift, size):
        diff = m[y] - m[y - shift]
        pos = diff > 20
        edge[y, pos] = np.minimum(diff[pos] * 3.0, 255)
    edge_img = Image.fromarray(edge.astype(np.uint8), "L")
    edge_img = edge_img.filter(ImageFilter.GaussianBlur(radius=1.5))
    out = np.zeros((size, size, 4), dtype=np.uint8)
    e = np.array(edge_img).astype(np.float32)
    bright = e > 2
    out[bright, 0] = 255
    out[bright, 1] = 255
    out[bright, 2] = 255
    out[bright, 3] = (e[bright] * 0.7).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def thin_outline(mask: Image.Image, size: int) -> Image.Image:
    dilated = np.array(mask.filter(ImageFilter.MaxFilter(5))).astype(np.float32)
    eroded = np.array(mask.filter(ImageFilter.MinFilter(5))).astype(np.float32)
    ring = (dilated - eroded).clip(0, 255)
    ring_img = Image.fromarray(ring.astype(np.uint8), "L")
    ring_img = ring_img.filter(ImageFilter.GaussianBlur(radius=0.8))
    ring = np.array(ring_img).astype(np.float32)
    out = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        t = y / size
        opacity = max(0.02, 0.20 - t * 0.14)
        row = ring[y]
        idx = row > 8
        if np.any(idx):
            out[y, idx, :3] = 255
            out[y, idx, 3] = (row[idx] * opacity).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def drop_shadow(mask: Image.Image, size: int) -> Image.Image:
    shifted = Image.new("L", (size, size), 0)
    shifted.paste(mask, (0, 28))
    shifted = shifted.filter(ImageFilter.GaussianBlur(radius=35))
    out = np.zeros((size, size, 4), dtype=np.uint8)
    s = np.array(shifted).astype(np.float32)
    bright = s > 2
    out[bright, 0] = 4
    out[bright, 1] = 4
    out[bright, 2] = 20
    out[bright, 3] = (s[bright] * 0.65).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def vignette(size: int) -> Image.Image:
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    ys = np.linspace(-1, 1, size)
    xs = np.linspace(-1, 1, size)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    d = np.sqrt(xx ** 2 + yy ** 2)
    mask = d > 0.45
    t = ((d[mask] - 0.45) / 0.55).clip(0, 1)
    arr[mask, 3] = (t * t * 100).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def render_prebaked(size: int, font_size: int) -> Image.Image:
    """Full pre-baked icon for .appiconset / App Store."""
    bg = gradient_bg(size)
    bg = Image.alpha_composite(bg, center_glow(size))

    # Render mask for glass effects
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = find_font(font_size)
    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) // 2 - bb[0]
    y = (size - th) // 2 - bb[1] - int(size * 0.02)
    draw.text((x, y), "π", fill=255, font=font)

    bg = Image.alpha_composite(bg, drop_shadow(mask, size))
    bg = Image.alpha_composite(bg, glass_fill(mask, size))
    bg = Image.alpha_composite(bg, top_edge_highlight(mask, size))
    bg = Image.alpha_composite(bg, thin_outline(mask, size))
    bg = Image.alpha_composite(bg, vignette(size))
    return bg


def main():
    print("Generating Oppi icon v6 (iOS 26 + fallback)...")

    FONT_SIZE = 720

    # ─── 1. iOS 26 foreground layer ───
    foreground = render_foreground(SIZE, FONT_SIZE)
    foreground.save("pi-foreground-v6.png", "PNG")
    print("  Saved: pi-foreground-v6.png")

    # ─── 2. Pre-baked fallback ───
    prebaked = render_prebaked(SIZE, FONT_SIZE)
    prebaked.save("pi-icon-v6-1024.png", "PNG")
    print("  Saved: pi-icon-v6-1024.png")

    # ─── 3. Update the .icon package ───
    icon_dir = Path("../Oppi/Resources/AppIcon.icon")
    assets_dir = icon_dir / "Assets"

    # Find existing asset filename
    existing = list(assets_dir.glob("*.png"))
    if existing:
        asset_name = existing[0].stem
        print(f"  Updating .icon asset: {asset_name}.png")
    else:
        asset_name = "835C931E-C63C-48AC-BDD7-E705250EE958"
        print(f"  Creating .icon asset: {asset_name}.png")

    foreground.save(assets_dir / f"{asset_name}.png", "PNG")

    # Update icon.json with refined settings
    icon_json = {
        "fill": {
            # Deep navy blue — derived from tokyoBlue #7AA2F7
            "automatic-gradient": "extended-srgb:0.06000,0.08000,0.24000,1.00000"
        },
        "groups": [
            {
                "layers": [
                    {
                        "image-name": asset_name,
                        "name": asset_name,
                    }
                ],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.55,
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.30,
                },
            }
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared",
        },
    }

    with open(icon_dir / "icon.json", "w") as f:
        json.dump(icon_json, f, indent=2)
    print("  Updated: icon.json")

    # ─── 4. Update .appiconset fallback ───
    appiconset = Path("../Oppi/Resources/Assets.xcassets/AppIcon.appiconset")
    prebaked.save(appiconset / "AppIcon.png", "PNG")
    print("  Updated: AppIcon.appiconset/AppIcon.png")

    print("\nDone! Changes:")
    print("  - .icon foreground: bigger 720px π, white on transparent")
    print("  - .icon fill: slightly richer indigo")
    print("  - .icon translucency: 0.30 (was 0.35) — slightly more opaque for readability")
    print("  - .icon shadow: 0.55 (was 0.50) — slightly deeper")
    print("  - .appiconset: pre-baked v6 with glass/glow for App Store + older iOS")


if __name__ == "__main__":
    main()

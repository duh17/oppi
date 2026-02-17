#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
#   "numpy>=2.0",
# ]
# ///
"""
Oppi icon v6 — timeless, bold, refined.

Design principles:
  - One big confident glyph, optically centered
  - Rich gradient background with focused center glow
  - Subtle glass fill — no gimmicky specular dots or caustic arcs
  - Top-edge catch light only (Apple's own playbook)
  - Deep vignette for presence on any background
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np
import math

SIZE = 1024


def gradient_bg(size: int) -> Image.Image:
    """Deep indigo gradient — darker at edges, warmer at center."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        for x in range(size):
            t = y / size
            cx = (x / size - 0.5) * 2
            cy = (y / size - 0.46) * 2
            d = math.sqrt(cx * cx + cy * cy)
            # Radial center lift — creates sense of depth/light source above
            lift = max(0, 1 - d * 0.9) ** 1.8

            r = int(max(4, 18 - t * 10 + lift * 22))
            g = int(max(4, 12 + t * 4 + lift * 12))
            b = int(max(24, 58 - t * 18 + lift * 38))
            arr[y, x] = [r, g, b, 255]
    return Image.fromarray(arr, "RGBA")


def center_glow(size: int) -> Image.Image:
    """Single focused glow behind the glyph — the "light source"."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    # Glow slightly above center (light from above)
    gcx, gcy = 0.50, 0.42
    for y in range(size):
        for x in range(size):
            dx = (x / size - gcx) / 0.36
            dy = (y / size - gcy) / 0.32
            d2 = dx * dx + dy * dy
            if d2 < 6.0:
                v = math.exp(-d2 * 1.2) * 0.55
                arr[y, x] = [100, 80, 210, int(v * 255)]
    img = Image.fromarray(arr, "RGBA")
    return img.filter(ImageFilter.GaussianBlur(radius=60))


def find_font(target_size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Find best available font. Prefer semibold/medium for more presence."""
    if bold:
        paths = [
            "/System/Library/Fonts/SFNS.ttf",  # SF has weight variants
            "/Library/Fonts/SF-Pro-Display-Semibold.otf",
            "/Library/Fonts/SF-Pro-Display-Medium.otf",
            "/System/Library/Fonts/SFNSDisplay.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
    else:
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


def render_pi(size: int, font_size: int) -> Image.Image:
    """Render π glyph mask, optically centered (slightly above geometric center)."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = find_font(font_size, bold=True)
    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) // 2 - bb[0]
    # Optical center: shift up ~2% — the bar of π is heavy at top
    y = (size - th) // 2 - bb[1] - int(size * 0.02)
    draw.text((x, y), "π", fill=255, font=font)
    return mask


def glass_fill(mask: Image.Image, size: int) -> Image.Image:
    """Clean glass gradient: bright top → muted bottom. No frills."""
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    out = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        t = y / size
        # Top: near-white. Bottom: cool lavender-grey.
        r = int(240 - t * 70)
        g = int(238 - t * 80)
        b = int(248 - t * 45)
        # Alpha: strong at top, fading at bottom for depth
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
    """Single strong top-edge catch light — the one effect that matters."""
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
    """Hairline outline for definition — fades toward bottom."""
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
    """Soft shadow below the glyph for float/depth."""
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
    """Strong corner vignette — frames the glyph and adds weight."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    ys = np.linspace(-1, 1, size)
    xs = np.linspace(-1, 1, size)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    d = np.sqrt(xx ** 2 + yy ** 2)
    mask = d > 0.45
    t = ((d[mask] - 0.45) / 0.55).clip(0, 1)
    arr[mask, 3] = (t * t * 100).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def round_corners(img: Image.Image, r: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=r, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def main():
    print("Generating Oppi icon v6 (timeless)...")

    # 1. Deep gradient background
    bg = gradient_bg(SIZE)

    # 2. Single focused center glow (light source)
    bg = Image.alpha_composite(bg, center_glow(SIZE))

    # 3. Big bold π glyph — 720px (bigger than v3's 660, room to breathe)
    pi_mask = render_pi(SIZE, 720)

    # 4. Depth: shadow → glass fill → edge highlight → outline
    bg = Image.alpha_composite(bg, drop_shadow(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, glass_fill(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, top_edge_highlight(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, thin_outline(pi_mask, SIZE))

    # 5. Vignette to frame
    bg = Image.alpha_composite(bg, vignette(SIZE))

    # Save
    bg.save("pi-icon-v6-1024.png", "PNG")
    print("  Saved: pi-icon-v6-1024.png")

    preview = round_corners(bg, 224)
    preview.save("pi-icon-v6-preview.png", "PNG")
    print("  Saved: pi-icon-v6-preview.png")


if __name__ == "__main__":
    main()

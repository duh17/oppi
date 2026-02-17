#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
#   "numpy>=2.0",
# ]
# ///
"""Generate Pi Remote iOS icon — v2: larger glyph, stronger glass."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops
import numpy as np
import math

SIZE = 1024
HALF = SIZE // 2


def gradient_bg(size: int) -> Image.Image:
    """Rich indigo gradient background."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        for x in range(size):
            t = (x / size * 0.6 + y / size * 0.4)
            r = int(26 - t * 14)
            g = int(18 + t * 10)
            b = int(72 - t * 24)
            arr[y, x] = [max(4, r), max(6, g), max(28, b), 255]
    return Image.fromarray(arr, "RGBA")


def radial_glow(size: int, cx: float, cy: float, r: float,
                color: tuple, alpha: float) -> Image.Image:
    """Gaussian-ish radial glow."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        for x in range(size):
            dx = (x - cx * size) / (r * size)
            dy = (y - cy * size) / (r * size)
            d2 = dx * dx + dy * dy
            if d2 < 4.0:
                v = math.exp(-d2 * 1.5) * alpha
                arr[y, x] = [color[0], color[1], color[2], int(v * 255)]
    img = Image.fromarray(arr, "RGBA")
    return img.filter(ImageFilter.GaussianBlur(radius=45))


def find_font(target_size: int) -> ImageFont.FreeTypeFont:
    """Find SF font for π."""
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
    """Render π as grayscale mask, centered."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = find_font(font_size)

    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) // 2 - bb[0]
    y = (size - th) // 2 - bb[1] + 20  # nudge down slightly
    draw.text((x, y), "π", fill=255, font=font)
    return mask


def glass_fill(mask: Image.Image, size: int) -> Image.Image:
    """Apply vertical glass gradient to masked region."""
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    out = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        t = y / size
        # White at top → lavender-blue at bottom
        r = int(255 - t * 80)
        g = int(255 - t * 90)
        b = int(255 - t * 45)
        # Opacity: ~0.95 at top → ~0.38 at bottom
        a_factor = 0.95 - t * 0.57

        row_m = mask_arr[y]
        idx = row_m > 0.01
        if np.any(idx):
            alphas = (a_factor * row_m[idx] * 255).clip(0, 255).astype(np.uint8)
            out[y, idx, 0] = min(255, r)
            out[y, idx, 1] = min(255, g)
            out[y, idx, 2] = min(255, b)
            out[y, idx, 3] = alphas

    return Image.fromarray(out, "RGBA")


def top_edge_highlight(mask: Image.Image, size: int, shift: int = 4) -> Image.Image:
    """Bright line along top edges of the glyph."""
    m = np.array(mask).astype(np.float32)
    edge = np.zeros_like(m)

    for y in range(shift, size):
        diff = m[y] - m[y - shift]
        pos = diff > 30
        edge[y, pos] = np.minimum(diff[pos] * 2.5, 255)

    edge_img = Image.fromarray(edge.astype(np.uint8), "L")
    edge_img = edge_img.filter(ImageFilter.GaussianBlur(radius=1.8))

    out = np.zeros((size, size, 4), dtype=np.uint8)
    e = np.array(edge_img).astype(np.float32)
    bright = e > 5
    out[bright, 0] = 255
    out[bright, 1] = 255
    out[bright, 2] = 255
    out[bright, 3] = (e[bright] * 0.8).clip(0, 255).astype(np.uint8)

    return Image.fromarray(out, "RGBA")


def thin_outline(mask: Image.Image, size: int) -> Image.Image:
    """Subtle white outline — glass edge definition."""
    dilated = np.array(mask.filter(ImageFilter.MaxFilter(5))).astype(np.float32)
    eroded = np.array(mask.filter(ImageFilter.MinFilter(5))).astype(np.float32)
    ring = (dilated - eroded).clip(0, 255)

    ring_img = Image.fromarray(ring.astype(np.uint8), "L")
    ring_img = ring_img.filter(ImageFilter.GaussianBlur(radius=1.0))
    ring = np.array(ring_img).astype(np.float32)

    out = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        t = y / size
        opacity = max(0.04, 0.28 - t * 0.18)
        row = ring[y]
        idx = row > 8
        if np.any(idx):
            out[y, idx, 0] = 255
            out[y, idx, 1] = 255
            out[y, idx, 2] = 255
            out[y, idx, 3] = (row[idx] * opacity).clip(0, 255).astype(np.uint8)

    return Image.fromarray(out, "RGBA")


def drop_shadow(mask: Image.Image, size: int, dy: int = 20, blur: int = 28,
                color=(6, 6, 35), opacity: float = 0.55) -> Image.Image:
    """Offset blurred shadow."""
    shifted = Image.new("L", (size, size), 0)
    shifted.paste(mask, (0, dy))
    shifted = shifted.filter(ImageFilter.GaussianBlur(radius=blur))

    out = np.zeros((size, size, 4), dtype=np.uint8)
    s = np.array(shifted).astype(np.float32)
    bright = s > 2
    out[bright, 0] = color[0]
    out[bright, 1] = color[1]
    out[bright, 2] = color[2]
    out[bright, 3] = (s[bright] * opacity).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def caustic_arc(size: int, cx: float, cy: float, rx: float, ry: float,
                thick: float, peak_opacity: float) -> Image.Image:
    """Elliptical caustic light sweep."""
    img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(img)

    scx, scy = int(cx * size), int(cy * size)
    srx, sry = int(rx * size), int(ry * size)
    t = int(thick * size)

    for i in range(t):
        frac = abs(i - t / 2) / (t / 2)
        a = int((1 - frac * frac) * 255)
        draw.ellipse([scx - srx - i, scy - sry - i, scx + srx + i, scy + sry + i],
                     outline=a)

    img = img.filter(ImageFilter.GaussianBlur(radius=10))

    # Horizontal bell-curve fade
    arr = np.array(img).astype(np.float32)
    xs = np.linspace(0, 1, size)
    fade = np.exp(-((xs - 0.5) ** 2) / 0.07)
    arr = arr * fade[np.newaxis, :]
    arr = (arr * peak_opacity).clip(0, 255)

    out = np.zeros((size, size, 4), dtype=np.uint8)
    bright = arr > 1
    out[bright, :3] = 255
    out[bright, 3] = arr[bright].astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def vignette(size: int) -> Image.Image:
    """Radial vignette."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    ys = np.linspace(-1, 1, size)
    xs = np.linspace(-1, 1, size)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    d = np.sqrt(xx ** 2 + yy ** 2)

    mask = d > 0.55
    t = ((d[mask] - 0.55) / 0.5).clip(0, 1)
    arr[mask, 3] = (t * t * 85).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def specular_dots(size: int) -> Image.Image:
    """Tiny bright specular highlights."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    dots = [
        (0.35, 0.28, 4, 130),
        (0.62, 0.27, 3.5, 110),
        (0.24, 0.32, 2.5, 80),
        (0.76, 0.31, 2.5, 70),
        (0.50, 0.26, 2, 60),
    ]
    for dx, dy, r, a in dots:
        cx, cy = int(dx * size), int(dy * size)
        ri = int(r)
        draw.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=(255, 255, 255, a))

    return img.filter(ImageFilter.GaussianBlur(radius=1.5))


def round_corners(img: Image.Image, r: int) -> Image.Image:
    """iOS rounded rect mask."""
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=r, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def main():
    print("Generating Pi icon v2...")

    # Background
    bg = gradient_bg(SIZE)

    # Glows
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.50, 0.47, 0.42, (120, 100, 235), 0.5))
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.65, 0.30, 0.22, (100, 70, 220), 0.08))
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.35, 0.68, 0.20, (60, 80, 200), 0.06))

    # Pi mask — BIG (680px font)
    pi_mask = render_pi(SIZE, 680)

    # Shadow
    bg = Image.alpha_composite(bg, drop_shadow(pi_mask, SIZE))

    # Glass fill
    bg = Image.alpha_composite(bg, glass_fill(pi_mask, SIZE))

    # Edge highlight
    bg = Image.alpha_composite(bg, top_edge_highlight(pi_mask, SIZE))

    # Outline
    bg = Image.alpha_composite(bg, thin_outline(pi_mask, SIZE))

    # Caustics
    bg = Image.alpha_composite(bg, caustic_arc(SIZE, 0.50, 0.12, 0.44, 0.20, 0.06, 0.18))
    bg = Image.alpha_composite(bg, caustic_arc(SIZE, 0.54, 0.90, 0.30, 0.08, 0.035, 0.08))

    # Specular dots
    bg = Image.alpha_composite(bg, specular_dots(SIZE))

    # Vignette
    bg = Image.alpha_composite(bg, vignette(SIZE))

    # Save square (for Xcode — it applies its own mask)
    bg.save("pi-icon-v5-square.png", "PNG")
    print("  Saved: pi-icon-v5-square.png")

    # Save with rounded corners for preview
    preview = round_corners(bg, 224)
    preview.save("pi-icon-v5-preview.png", "PNG")
    print("  Saved: pi-icon-v5-preview.png")


if __name__ == "__main__":
    main()

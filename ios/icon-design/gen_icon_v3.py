#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
#   "numpy>=2.0",
# ]
# ///
"""Generate Pi Remote iOS icon — v3: final polish."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np
import math

SIZE = 1024


def gradient_bg(size: int) -> Image.Image:
    """Rich indigo gradient background with subtle depth variation."""
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for y in range(size):
        for x in range(size):
            # Diagonal gradient with slight radial warmth at center
            t = (x / size * 0.55 + y / size * 0.45)
            cx = (x / size - 0.5) * 2
            cy = (y / size - 0.48) * 2
            d = math.sqrt(cx * cx + cy * cy)
            center_lift = max(0, 1 - d) * 0.08  # subtle center brightening

            r = int(max(6, 26 - t * 16 + center_lift * 30))
            g = int(max(8, 18 + t * 8 + center_lift * 15))
            b = int(max(30, 74 - t * 22 + center_lift * 40))
            arr[y, x] = [r, g, b, 255]
    return Image.fromarray(arr, "RGBA")


def radial_glow(size: int, cx: float, cy: float, r: float,
                color: tuple, alpha: float) -> Image.Image:
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
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = find_font(font_size)
    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) // 2 - bb[0]
    y = (size - th) // 2 - bb[1] + 15
    draw.text((x, y), "π", fill=255, font=font)
    return mask


def glass_fill(mask: Image.Image, size: int) -> Image.Image:
    """Glass gradient: white top → translucent blue bottom."""
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    out = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        t = y / size
        r = int(255 - t * 105)
        g = int(255 - t * 75)
        b = int(255 - t * 20)
        a_factor = 0.93 - t * 0.52

        row = mask_arr[y]
        idx = row > 0.01
        if np.any(idx):
            out[y, idx, 0] = min(255, r)
            out[y, idx, 1] = min(255, g)
            out[y, idx, 2] = min(255, b)
            out[y, idx, 3] = (a_factor * row[idx] * 255).clip(0, 255).astype(np.uint8)

    return Image.fromarray(out, "RGBA")


def refraction_band(mask: Image.Image, size: int) -> Image.Image:
    """Horizontal light band across the middle — refraction through glass."""
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    out = np.zeros((size, size, 4), dtype=np.uint8)

    # Band centered around y=0.42 of the glyph area, narrow
    band_center = 0.40
    band_width = 0.06

    for y in range(size):
        t = y / size
        dist = abs(t - band_center) / band_width
        if dist < 1.0:
            # Smooth bell curve
            intensity = math.exp(-dist * dist * 3.0) * 0.18
            row = mask_arr[y]
            idx = row > 0.1
            if np.any(idx):
                a = int(intensity * 255)
                out[y, idx, 0] = 255
                out[y, idx, 1] = 252
                out[y, idx, 2] = 255
                out[y, idx, 3] = (row[idx] * a).clip(0, 255).astype(np.uint8)

    img = Image.fromarray(out, "RGBA")
    return img.filter(ImageFilter.GaussianBlur(radius=4))


def top_edge_highlight(mask: Image.Image, size: int, shift: int = 4) -> Image.Image:
    m = np.array(mask).astype(np.float32)
    edge = np.zeros_like(m)

    for y in range(shift, size):
        diff = m[y] - m[y - shift]
        pos = diff > 25
        edge[y, pos] = np.minimum(diff[pos] * 2.8, 255)

    edge_img = Image.fromarray(edge.astype(np.uint8), "L")
    edge_img = edge_img.filter(ImageFilter.GaussianBlur(radius=1.5))

    out = np.zeros((size, size, 4), dtype=np.uint8)
    e = np.array(edge_img).astype(np.float32)
    bright = e > 3
    out[bright, 0] = 255
    out[bright, 1] = 255
    out[bright, 2] = 255
    out[bright, 3] = (e[bright] * 0.85).clip(0, 255).astype(np.uint8)

    return Image.fromarray(out, "RGBA")


def left_edge_highlight(mask: Image.Image, size: int, shift: int = 4) -> Image.Image:
    """Subtle left-edge highlight (light coming from top-left)."""
    m = np.array(mask).astype(np.float32)
    edge = np.zeros_like(m)

    for y in range(size):
        for x in range(shift, size):
            diff = m[y, x] - m[y, x - shift]
            if diff > 25:
                edge[y, x] = min(255, diff * 1.5)

    edge_img = Image.fromarray(edge.astype(np.uint8), "L")
    edge_img = edge_img.filter(ImageFilter.GaussianBlur(radius=2.0))

    out = np.zeros((size, size, 4), dtype=np.uint8)
    e = np.array(edge_img).astype(np.float32)
    bright = e > 3
    out[bright, 0] = 255
    out[bright, 1] = 255
    out[bright, 2] = 255
    out[bright, 3] = (e[bright] * 0.35).clip(0, 255).astype(np.uint8)

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
        opacity = max(0.04, 0.25 - t * 0.15)
        row = ring[y]
        idx = row > 8
        if np.any(idx):
            out[y, idx, :3] = 255
            out[y, idx, 3] = (row[idx] * opacity).clip(0, 255).astype(np.uint8)

    return Image.fromarray(out, "RGBA")


def drop_shadow(mask: Image.Image, size: int) -> Image.Image:
    shifted = Image.new("L", (size, size), 0)
    shifted.paste(mask, (0, 22))
    shifted = shifted.filter(ImageFilter.GaussianBlur(radius=30))

    out = np.zeros((size, size, 4), dtype=np.uint8)
    s = np.array(shifted).astype(np.float32)
    bright = s > 2
    out[bright, 0] = 5
    out[bright, 1] = 5
    out[bright, 2] = 30
    out[bright, 3] = (s[bright] * 0.6).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def caustic_arc(size: int, cx: float, cy: float, rx: float, ry: float,
                thick: float, peak_op: float) -> Image.Image:
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

    arr = np.array(img).astype(np.float32)
    xs = np.linspace(0, 1, size)
    fade = np.exp(-((xs - 0.5) ** 2) / 0.07)
    arr = (arr * fade[np.newaxis, :] * peak_op).clip(0, 255)

    out = np.zeros((size, size, 4), dtype=np.uint8)
    bright = arr > 1
    out[bright, :3] = 255
    out[bright, 3] = arr[bright].astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def specular_dots(size: int) -> Image.Image:
    """Bright white specular catch points."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    dots = [
        # (x_frac, y_frac, radius, alpha)
        (0.35, 0.275, 5, 200),   # left of bar
        (0.62, 0.272, 4, 170),   # right of bar
        (0.24, 0.30, 3, 120),    # far left
        (0.76, 0.295, 3, 100),   # far right
    ]
    for dx, dy, r, a in dots:
        cx, cy = int(dx * size), int(dy * size)
        # Bright white core
        draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                     fill=(255, 255, 255, min(255, a)))
        # Larger soft bloom
        draw.ellipse([cx - r * 3, cy - r * 3, cx + r * 3, cy + r * 3],
                     fill=(255, 255, 255, a // 6))

    return img.filter(ImageFilter.GaussianBlur(radius=2))


def vignette(size: int) -> Image.Image:
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    ys = np.linspace(-1, 1, size)
    xs = np.linspace(-1, 1, size)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    d = np.sqrt(xx ** 2 + yy ** 2)
    mask = d > 0.55
    t = ((d[mask] - 0.55) / 0.5).clip(0, 1)
    arr[mask, 3] = (t * t * 80).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def round_corners(img: Image.Image, r: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=r, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def main():
    print("Generating Pi icon v3 (final)...")

    # Background
    bg = gradient_bg(SIZE)

    # Glows — blue-shifted (from tokyoBlue #7AA2F7)
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.50, 0.46, 0.40, (70, 110, 230), 0.50))
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.64, 0.28, 0.20, (55, 85, 220), 0.09))
    bg = Image.alpha_composite(bg, radial_glow(SIZE, 0.36, 0.70, 0.18, (40, 75, 200), 0.06))

    # Pi glyph mask — big and bold
    pi_mask = render_pi(SIZE, 660)

    # Layers
    bg = Image.alpha_composite(bg, drop_shadow(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, glass_fill(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, refraction_band(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, top_edge_highlight(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, left_edge_highlight(pi_mask, SIZE))
    bg = Image.alpha_composite(bg, thin_outline(pi_mask, SIZE))

    # Caustics
    bg = Image.alpha_composite(bg, caustic_arc(SIZE, 0.50, 0.11, 0.44, 0.20, 0.055, 0.18))
    bg = Image.alpha_composite(bg, caustic_arc(SIZE, 0.54, 0.91, 0.28, 0.07, 0.03, 0.07))

    # Specular dots
    bg = Image.alpha_composite(bg, specular_dots(SIZE))

    # Vignette
    bg = Image.alpha_composite(bg, vignette(SIZE))

    # Save
    bg.save("pi-icon-final-square.png", "PNG")
    print("  Saved: pi-icon-final-square.png")

    preview = round_corners(bg, 224)
    preview.save("pi-icon-final-preview.png", "PNG")
    print("  Saved: pi-icon-final-preview.png")


if __name__ == "__main__":
    main()

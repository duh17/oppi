#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
#   "numpy>=2.0",
# ]
# ///
"""Generate Pi Remote iOS icon with liquid glass aesthetic."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np
import math

SIZE = 1024
CENTER = SIZE // 2


def make_background(size: int) -> Image.Image:
    """Deep indigo-to-dark-teal gradient background."""
    img = Image.new("RGBA", (size, size))
    arr = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        for x in range(size):
            # Diagonal gradient
            t = (x / size * 0.7 + y / size * 0.3)
            r = int(28 - t * 12)
            g = int(19 + t * 8)
            b = int(72 - t * 20)
            arr[y, x] = [max(0, r), max(0, g), max(0, b), 255]

    return Image.fromarray(arr, "RGBA")


def make_radial_glow(size: int, cx: float, cy: float, radius: float,
                     color: tuple, peak_alpha: float) -> Image.Image:
    """Soft radial glow."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    arr = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        for x in range(size):
            dx = (x - cx * size) / (radius * size)
            dy = (y - cy * size) / (radius * size)
            d = math.sqrt(dx * dx + dy * dy)
            if d < 1.0:
                # Smooth falloff
                t = 1.0 - d
                t = t * t * (3 - 2 * t)  # smoothstep
                a = int(peak_alpha * 255 * t)
                arr[y, x] = [color[0], color[1], color[2], a]

    return Image.fromarray(arr, "RGBA")


def find_pi_font(target_size: int) -> tuple:
    """Find a good font for π and return (font, size)."""
    # Try system fonts in order of preference
    font_candidates = [
        "/System/Library/Fonts/SFNSDisplay.ttf",  # San Francisco
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/SF-Pro-Display-Light.otf",
        "/Library/Fonts/SF-Pro-Display-Regular.otf",
        "/Library/Fonts/SF-Pro.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
    ]

    for path in font_candidates:
        try:
            font = ImageFont.truetype(path, target_size)
            # Test that it can render π
            test_img = Image.new("RGBA", (100, 100))
            test_draw = ImageDraw.Draw(test_img)
            bbox = test_draw.textbbox((0, 0), "π", font=font)
            if bbox[2] - bbox[0] > 10:  # has a real glyph
                print(f"Using font: {path}")
                return font
        except (OSError, IOError):
            continue

    # Fallback
    print("Using default font")
    return ImageFont.load_default()


def render_pi_mask(size: int, font_size: int) -> Image.Image:
    """Render π as a white-on-black mask."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = find_pi_font(font_size)

    # Get text bounds to center it
    bbox = draw.textbbox((0, 0), "π", font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]

    x = (size - tw) // 2 - bbox[0]
    y = (size - th) // 2 - bbox[1] + 15  # slight downward nudge

    draw.text((x, y), "π", fill=255, font=font)
    return mask


def apply_glass_gradient(mask: Image.Image, size: int) -> Image.Image:
    """Apply a top-to-bottom glass gradient to the pi mask."""
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    arr = np.array(result)
    mask_arr = np.array(mask)

    for y in range(size):
        t = y / size
        # Top: bright white, Bottom: muted lavender
        r = int(255 - t * 100)
        g = int(255 - t * 110)
        b = int(255 - t * 60)
        # Opacity gradient: bright at top, more transparent at bottom
        base_alpha = 0.92 - t * 0.5
        for x in range(size):
            m = mask_arr[y, x] / 255.0
            if m > 0.01:
                a = int(base_alpha * m * 255)
                arr[y, x] = [min(255, r), min(255, g), min(255, b), min(255, a)]

    return Image.fromarray(arr, "RGBA")


def make_edge_highlight(mask: Image.Image, size: int) -> Image.Image:
    """Create a bright edge highlight along the top edges of the pi."""
    # Erode the mask slightly
    from PIL import ImageFilter

    # Original mask blurred slightly for edge detection
    blurred = mask.filter(ImageFilter.GaussianBlur(radius=3))
    edge = Image.new("L", (size, size), 0)
    mask_arr = np.array(mask)
    blur_arr = np.array(blurred)

    # Top edges: where mask is present but slightly above is less
    edge_arr = np.zeros((size, size), dtype=np.uint8)
    for y in range(3, size):
        for x in range(size):
            if mask_arr[y, x] > 128:
                above = int(mask_arr[y - 3, x])
                current = int(mask_arr[y, x])
                diff = current - above
                if diff > 20:
                    # This is a top edge
                    edge_arr[y, x] = min(255, diff * 3)

    edge = Image.fromarray(edge_arr, "L")
    edge = edge.filter(ImageFilter.GaussianBlur(radius=1.5))

    # Make it white with the edge as alpha
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    highlight_arr = np.array(highlight)
    edge_arr = np.array(edge)

    for y in range(size):
        for x in range(size):
            e = edge_arr[y, x]
            if e > 5:
                a = min(255, int(e * 0.7))
                highlight_arr[y, x] = [255, 255, 255, a]

    return Image.fromarray(highlight_arr, "RGBA")


def make_outline(mask: Image.Image, size: int, width: float = 1.5) -> Image.Image:
    """Subtle white outline on the pi for glass edge definition."""
    # Dilate - original = outline
    dilated = mask.filter(ImageFilter.MaxFilter(3))
    eroded = mask.filter(ImageFilter.MinFilter(3))

    outline = Image.new("L", (size, size), 0)
    d_arr = np.array(dilated)
    e_arr = np.array(eroded)
    o_arr = np.zeros((size, size), dtype=np.uint8)

    for y in range(size):
        for x in range(size):
            diff = int(d_arr[y, x]) - int(e_arr[y, x])
            if diff > 10:
                o_arr[y, x] = min(255, diff)

    outline = Image.fromarray(o_arr, "L")
    outline = outline.filter(ImageFilter.GaussianBlur(radius=0.8))

    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    r_arr = np.array(result)
    o_arr = np.array(outline)

    for y in range(size):
        t = y / size
        opacity = 0.3 - t * 0.15  # Brighter at top
        for x in range(size):
            o = o_arr[y, x]
            if o > 5:
                a = int(o * max(0.05, opacity))
                r_arr[y, x] = [255, 255, 255, min(255, a)]

    return Image.fromarray(r_arr, "RGBA")


def make_shadow(mask: Image.Image, size: int) -> Image.Image:
    """Drop shadow beneath the pi."""
    # Offset and blur the mask
    shadow_mask = Image.new("L", (size, size), 0)
    mask_arr = np.array(mask)
    s_arr = np.zeros((size, size), dtype=np.uint8)

    offset_y = 18
    for y in range(size - offset_y):
        for x in range(size):
            s_arr[y + offset_y, x] = mask_arr[y, x]

    shadow_mask = Image.fromarray(s_arr, "L")
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(radius=25))

    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    r_arr = np.array(result)
    s_arr = np.array(shadow_mask)

    for y in range(size):
        for x in range(size):
            s = s_arr[y, x]
            if s > 2:
                a = int(s * 0.55)
                r_arr[y, x] = [6, 6, 40, min(255, a)]

    return Image.fromarray(r_arr, "RGBA")


def make_caustic_arc(size: int, cx: float, cy: float, rx: float, ry: float,
                     thickness: float, opacity: float) -> Image.Image:
    """Elliptical caustic light arc."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Draw ellipse ring
    x0 = int((cx - rx) * size)
    y0 = int((cy - ry) * size)
    x1 = int((cx + rx) * size)
    y1 = int((cy + ry) * size)
    t = int(thickness * size)

    for i in range(t):
        alpha = int(opacity * 255 * (1 - abs(i - t / 2) / (t / 2)))
        alpha = max(0, min(255, alpha))
        draw.ellipse([x0 - i, y0 - i, x1 + i, y1 + i],
                     outline=(255, 255, 255, alpha))

    # Apply horizontal fade (center bright, edges transparent)
    arr = np.array(img)
    for x in range(size):
        xt = x / size
        # Bell curve centered at 0.5
        fade = math.exp(-((xt - 0.5) ** 2) / 0.08)
        arr[:, x, 3] = (arr[:, x, 3].astype(float) * fade).astype(np.uint8)

    result = Image.fromarray(arr, "RGBA")
    return result.filter(ImageFilter.GaussianBlur(radius=8))


def make_vignette(size: int) -> Image.Image:
    """Radial vignette darkening."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    arr = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        for x in range(size):
            dx = (x - size / 2) / (size / 2)
            dy = (y - size / 2) / (size / 2)
            d = math.sqrt(dx * dx + dy * dy)
            if d > 0.55:
                t = (d - 0.55) / 0.45
                t = min(1.0, t)
                a = int(t * t * 90)
                arr[y, x] = [0, 0, 0, a]

    return Image.fromarray(arr, "RGBA")


def apply_rounded_corners(img: Image.Image, radius: int) -> Image.Image:
    """Apply iOS-style rounded corners (superellipse approximation)."""
    size = img.size[0]
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size, size], radius=radius, fill=255)
    result = Image.new("RGBA", img.size, (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def main():
    print(f"Generating {SIZE}x{SIZE} Pi icon...")

    # 1. Background
    print("  Background...")
    bg = make_background(SIZE)

    # 2. Back glow
    print("  Glow...")
    glow = make_radial_glow(SIZE, 0.5, 0.48, 0.4, (123, 104, 238), 0.45)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=50))
    bg.paste(Image.alpha_composite(Image.new("RGBA", bg.size, (0, 0, 0, 0)), glow), (0, 0), glow)

    # Warm accent
    warm = make_radial_glow(SIZE, 0.68, 0.28, 0.22, (110, 80, 210), 0.08)
    warm = warm.filter(ImageFilter.GaussianBlur(radius=40))
    bg = Image.alpha_composite(bg, warm)

    # Cool accent
    cool = make_radial_glow(SIZE, 0.32, 0.72, 0.2, (60, 90, 200), 0.06)
    cool = cool.filter(ImageFilter.GaussianBlur(radius=40))
    bg = Image.alpha_composite(bg, cool)

    # 3. Pi mask
    print("  Pi glyph...")
    pi_mask = render_pi_mask(SIZE, 520)

    # 4. Shadow
    print("  Shadow...")
    shadow = make_shadow(pi_mask, SIZE)
    bg = Image.alpha_composite(bg, shadow)

    # 5. Glass pi
    print("  Glass effect...")
    glass_pi = apply_glass_gradient(pi_mask, SIZE)
    bg = Image.alpha_composite(bg, glass_pi)

    # 6. Edge highlight
    print("  Edge highlights...")
    edges = make_edge_highlight(pi_mask, SIZE)
    bg = Image.alpha_composite(bg, edges)

    # 7. Outline
    print("  Outline...")
    outline = make_outline(pi_mask, SIZE)
    bg = Image.alpha_composite(bg, outline)

    # 8. Caustic arcs
    print("  Caustics...")
    caustic1 = make_caustic_arc(SIZE, 0.5, 0.13, 0.43, 0.19, 0.06, 0.15)
    bg = Image.alpha_composite(bg, caustic1)

    caustic2 = make_caustic_arc(SIZE, 0.55, 0.88, 0.28, 0.09, 0.04, 0.08)
    bg = Image.alpha_composite(bg, caustic2)

    # 9. Vignette
    print("  Vignette...")
    vignette = make_vignette(SIZE)
    bg = Image.alpha_composite(bg, vignette)

    # 10. Rounded corners
    print("  Rounding corners...")
    final = apply_rounded_corners(bg, 224)

    # Save
    out_path = "pi-icon-v4-pillow-1024.png"
    final.save(out_path, "PNG")
    print(f"  Saved: {out_path}")

    # Also save without rounded corners (Xcode applies its own mask)
    bg.save("pi-icon-v4-pillow-1024-square.png", "PNG")
    print("  Saved: pi-icon-v4-pillow-1024-square.png (for Xcode)")


if __name__ == "__main__":
    main()

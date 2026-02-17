#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#   "pillow>=11.0",
# ]
# ///
"""Generate clean foreground layer for iOS 26 Icon Composer format.

The system renders liquid glass effects — we just provide clean layers:
- Background: defined as fill color in icon.json (system handles it)
- Foreground: clean π glyph, white on transparent
"""

from PIL import Image, ImageDraw, ImageFont
import json
import os
import shutil
import uuid

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


def render_pi_foreground(size: int, font_size: int) -> Image.Image:
    """Render π as white on transparent — clean, no effects."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    font = find_font(font_size)

    bb = draw.textbbox((0, 0), "π", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) // 2 - bb[0]
    y = (size - th) // 2 - bb[1] + 10

    # Pure white glyph on transparent background
    draw.text((x, y), "π", fill=(255, 255, 255, 255), font=font)
    return img


def create_icon_package(output_dir: str, foreground_img: Image.Image):
    """Create an Icon Composer .icon package."""
    icon_dir = output_dir
    assets_dir = os.path.join(icon_dir, "Assets")

    # Clean and create directories
    if os.path.exists(icon_dir):
        shutil.rmtree(icon_dir)
    os.makedirs(assets_dir)

    # Save foreground layer
    layer_id = str(uuid.uuid4()).upper()
    layer_filename = f"{layer_id}.png"
    foreground_img.save(os.path.join(assets_dir, layer_filename), "PNG")
    print(f"  Layer: {layer_filename}")

    # Background fill: deep indigo-purple
    # extended-srgb format: R, G, B, A (0-1 range)
    # Our deep indigo: roughly #1c1348 → R=0.11, G=0.075, B=0.28
    bg_color = "extended-srgb:0.11000,0.07500,0.28000,1.00000"

    icon_json = {
        "fill": {
            "automatic-gradient": bg_color
        },
        "groups": [
            {
                "layers": [
                    {
                        "image-name": layer_filename.replace(".png", ""),
                        "name": layer_filename.replace(".png", ""),
                    }
                ],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.5
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.35
                }
            }
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared"
        }
    }

    with open(os.path.join(icon_dir, "icon.json"), "w") as f:
        json.dump(icon_json, f, indent=2)

    print(f"  Created: {icon_dir}")


def main():
    print("Generating iOS 26 layered icon...")

    # Clean white π foreground — no effects, no shadows, no glass
    # System will apply liquid glass, specular highlights, shadows
    fg = render_pi_foreground(SIZE, 660)

    # Also save standalone for preview
    fg.save("pi-foreground-layer.png", "PNG")
    print("  Saved: pi-foreground-layer.png")

    # Create .icon package
    create_icon_package("PiRemote.icon", fg)

    # Also generate a flat fallback for older iOS (clean version)
    # Simple: indigo background + white π, no baked effects
    flat = Image.new("RGBA", (SIZE, SIZE), (28, 19, 72, 255))
    flat.paste(fg, (0, 0), fg)
    flat.save("pi-icon-flat-fallback.png", "PNG")
    print("  Saved: pi-icon-flat-fallback.png (flat fallback)")


if __name__ == "__main__":
    main()

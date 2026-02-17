#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["pillow>=11.0"]
# ///
"""Flat blue AppIcon — white π on deep navy, no effects."""

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024

bg = Image.new("RGBA", (SIZE, SIZE), (15, 23, 66, 255))

for p in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
    try:
        font = ImageFont.truetype(p, 820)
        break
    except (OSError, IOError):
        pass

draw = ImageDraw.Draw(bg)
bb = draw.textbbox((0, 0), "π", font=font)
tw, th = bb[2] - bb[0], bb[3] - bb[1]
x = (SIZE - tw) // 2 - bb[0]
y = (SIZE - th) // 2 - bb[1] - int(SIZE * 0.02)
draw.text((x, y), "π", fill=(255, 255, 255, 255), font=font)

bg.save("../Oppi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", "PNG")
print("Done — flat blue AppIcon with 720px π")

#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["pillow>=11.0"]
# ///
"""Big white π on transparent — iOS 26 .icon foreground layer."""

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
FONT_SIZE = 820

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

for p in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
    try:
        font = ImageFont.truetype(p, FONT_SIZE)
        break
    except (OSError, IOError):
        pass

draw = ImageDraw.Draw(img)
bb = draw.textbbox((0, 0), "π", font=font)
tw, th = bb[2] - bb[0], bb[3] - bb[1]
x = (SIZE - tw) // 2 - bb[0]
y = (SIZE - th) // 2 - bb[1] - int(SIZE * 0.02)
draw.text((x, y), "π", fill=(255, 255, 255, 255), font=font)

img.save("../Oppi/Resources/AppIcon.icon/Assets/835C931E-C63C-48AC-BDD7-E705250EE958.png", "PNG")
print(f"Done — {FONT_SIZE}px π foreground")

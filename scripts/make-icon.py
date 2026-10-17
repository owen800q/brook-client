"""Turns assets/icon-source.png (generated art) into assets/AppIcon.icns on Apple's icon grid.

Run with a pyenv Python that has Pillow:  python scripts/make-icon.py
"""
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/icon-source.png"
OUT = ROOT / "assets/AppIcon.icns"
CANVAS, TILE, RADIUS = 1024, 824, 185  # macOS grid: 824pt tile, 100pt margin

src = Image.open(SRC).convert("RGBA")
# Crop to the opaque tile, trimming a few px of the generator's soft/noisy fringe.
box = src.getchannel("A").point(lambda a: 255 if a > 200 else 0).getbbox()
inset = int((box[2] - box[0]) * 0.012)
tile = src.crop((box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset)).resize((TILE, TILE), Image.LANCZOS)

# Clean anti-aliased rounded-rect mask drawn at 4x.
big = Image.new("L", (TILE * 4, TILE * 4), 0)
ImageDraw.Draw(big).rounded_rectangle((0, 0, TILE * 4 - 1, TILE * 4 - 1), RADIUS * 4, fill=255)
mask = big.resize((TILE, TILE), Image.LANCZOS)
tile.putalpha(mask)

off = (CANVAS - TILE) // 2
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (off, off + 12), mask)
icon = shadow.filter(ImageFilter.GaussianBlur(14))
icon.alpha_composite(tile, (off, off))
icon.save(ROOT / "assets/AppIcon.png")

with tempfile.TemporaryDirectory() as d:
    iconset = pathlib.Path(d) / "AppIcon.iconset"
    iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
print(OUT)

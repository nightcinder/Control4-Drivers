#!/usr/bin/env python3
"""Draws the generic curtain icons for drivers/switchbot-curtain/www/icons (original artwork, no brand marks).
Run from the repo root:  python3 tools/switchbot-curtain/make_icons.py"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "drivers", "switchbot-curtain", "www", "icons")
FILL, LINE, FOLD = (222, 228, 236, 255), (150, 160, 176, 255), (170, 180, 195, 255)

def master(n=1024):
    s = 4  # supersample
    im = Image.new("RGBA", (n * s, n * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    k = n * s / 1024.0
    def P(pts): return [(x * k, y * k) for x, y in pts]
    # rod and finials
    d.rounded_rectangle([x * k for x in (150, 170, 874, 214)], radius=22 * k, fill=LINE)
    for cx in (140, 884):
        d.ellipse([ (cx - 34) * k, 156 * k, (cx + 34) * k, 228 * k ], fill=LINE)
    # drapes (left and right panels with a gap in the middle)
    left = [(190, 214), (490, 214), (470, 850), (400, 880), (330, 850), (260, 884), (200, 850)]
    right = [(534, 214), (834, 214), (824, 850), (764, 884), (694, 850), (624, 880), (554, 850)]
    for poly in (left, right):
        d.polygon(P(poly), fill=FILL, outline=LINE)
        d.line(P(poly + [poly[0]]), fill=LINE, width=int(10 * k))
    # fold lines
    for xs in ((270, 340, 410), (604, 674, 744)):
        for x in xs:
            d.line(P([(x, 230), (x + 8, 840)]), fill=FOLD, width=int(8 * k))
    return im.resize((n, n), Image.LANCZOS)

m = master()
os.makedirs(os.path.join(OUT, "device", "blind"), exist_ok=True)
for size in (1024, 512, 300, 90, 70):
    m.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, "device", "blind", f"experience_{size}.png"))
m.resize((16, 16), Image.LANCZOS).save(os.path.join(OUT, "device_sm.png"))
m.resize((32, 32), Image.LANCZOS).save(os.path.join(OUT, "device_lg.png"))
print("icons written to", os.path.normpath(OUT))

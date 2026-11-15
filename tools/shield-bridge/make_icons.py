"""Regenerate the Control4 device icons for shield-tv-bridge.

Draws the generic black streaming box (no logo, no text) on a transparent
background, at 4x and downsampled for smooth edges. Each existing PNG keeps its
filename and square pixel size. Run from any directory:

    python make_icons.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

from art import shield_image

ICON_DIR = Path(__file__).resolve().parents[2] / "drivers" / "shield-tv-bridge" / "www" / "icons"
NAMES = ("device_lg.png", "device_sm.png")


def main() -> None:
    for name in NAMES:
        path = ICON_DIR / name
        with Image.open(path) as existing:
            width, height = existing.size
        if width != height:
            raise SystemExit(f"{path}: expected a square icon, got {width}x{height}")
        shield_image(width, (0, 0, 0, 0), ss=4).save(path, "PNG", optimize=True)
        print(f"rewrote {path} {width}x{height}")


if __name__ == "__main__":
    main()

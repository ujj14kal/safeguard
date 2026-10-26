#!/usr/bin/env python3
"""Builds the app icon and launch logo from design/logo-source.png.

Usage: python3 scripts/make-brand-assets.py
Requires Pillow and numpy. Writes into ios/Safeguard/Assets.xcassets:
  AppIcon.appiconset/AppIcon.png        1024x1024, opaque white, shield enlarged
  LaunchLogo.imageset/LaunchLogo@2x.png tight shield crop for the launch screen
  LaunchLogo.imageset/LaunchLogo@3x.png and the in-app splash (same image, so the
                                        hand-off from launch screen to splash is seamless)
The source has an off-white background (254-255); it is flattened to pure white
so the icon and launch screen are exactly #FFFFFF.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "design", "logo-source.png")
CATALOG = os.path.join(ROOT, "ios", "Safeguard", "Assets.xcassets")

# Brand purple for the icon, launch logo and splash text. The supplied logo is
# #582560; this is a bit lighter (still 8.2:1 contrast on white).
BRAND_PURPLE = (111, 58, 124)  # #6F3A7C
SOURCE_PURPLE_GREEN = 37       # green channel of the supplied #582560 (the darkest channel)

ICON_SIZE = 1024
ICON_SHIELD_HEIGHT = 840      # ~82% of the icon; iOS rounds the corners, so keep a margin
LAUNCH_SHIELD_HEIGHT_PT = 220  # shown at 2x/3x, identical in the splash view
PAD = 6                        # source px of white kept around the shield crop


def flatten_white(rgb: np.ndarray) -> np.ndarray:
    """Pure white wherever the source is (near-)white; keep anti-aliased edges."""
    out = rgb.copy()
    near_white = (out >= 240).all(axis=2)
    out[near_white] = 255
    return out


def recolor(rgb: np.ndarray) -> np.ndarray:
    """Re-tint the purple, keeping the anti-aliased edges.

    Every pixel is white*(1-c) + purple*c. Coverage c comes from the green
    channel (the one with the most contrast against white); the new pixel is the
    same blend with BRAND_PURPLE, so edges stay smooth and white stays white.
    """
    coverage = np.clip((255 - rgb[..., 1]) / (255 - SOURCE_PURPLE_GREEN), 0, 1)[..., None]
    purple = np.array(BRAND_PURPLE, dtype=float)
    return np.rint(255 * (1 - coverage) + purple * coverage).astype("uint8")


def shield_crop(image: Image.Image) -> Image.Image:
    rgb = np.asarray(image.convert("RGB")).astype(int)
    colourful = (255 - rgb).sum(axis=2) > 120
    ys, xs = np.where(colourful)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    box = (max(x0 - PAD, 0), max(y0 - PAD, 0),
           min(x1 + PAD + 1, image.width), min(y1 + PAD + 1, image.height))
    cropped = np.asarray(image.convert("RGB").crop(box)).astype(int)
    return Image.fromarray(recolor(flatten_white(cropped)), "RGB")


def scaled_to_height(image: Image.Image, height: int) -> Image.Image:
    width = round(image.width * height / image.height)
    return image.resize((width, height), Image.LANCZOS)


def write_json(path: str, payload: dict) -> None:
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def main() -> int:
    if not os.path.exists(SOURCE):
        print(f"missing {SOURCE}", file=sys.stderr)
        return 1
    shield = shield_crop(Image.open(SOURCE))

    # App icon: opaque white square, shield enlarged and centred.
    icon_dir = os.path.join(CATALOG, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    big = scaled_to_height(shield, ICON_SHIELD_HEIGHT)
    canvas = Image.new("RGB", (ICON_SIZE, ICON_SIZE), (255, 255, 255))
    canvas.paste(big, ((ICON_SIZE - big.width) // 2, (ICON_SIZE - big.height) // 2))
    canvas.save(os.path.join(icon_dir, "AppIcon.png"), "PNG", optimize=True)
    write_json(os.path.join(icon_dir, "Contents.json"), {
        "images": [{
            "filename": "AppIcon.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }],
        "info": {"author": "xcode", "version": 1},
    })

    # Launch logo: same tight crop at 2x and 3x (220 pt tall).
    launch_dir = os.path.join(CATALOG, "LaunchLogo.imageset")
    os.makedirs(launch_dir, exist_ok=True)
    for scale in (2, 3):
        scaled_to_height(shield, LAUNCH_SHIELD_HEIGHT_PT * scale).save(
            os.path.join(launch_dir, f"LaunchLogo@{scale}x.png"), "PNG", optimize=True
        )
    write_json(os.path.join(launch_dir, "Contents.json"), {
        "images": [
            {"filename": "LaunchLogo@2x.png", "idiom": "universal", "scale": "2x"},
            {"filename": "LaunchLogo@3x.png", "idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    })

    # Launch background: pure white in light AND dark mode (the logo is on white).
    bg_dir = os.path.join(CATALOG, "LaunchBackground.colorset")
    os.makedirs(bg_dir, exist_ok=True)
    white = {"color-space": "srgb", "components": {"red": "1.000", "green": "1.000",
                                                    "blue": "1.000", "alpha": "1.000"}}
    write_json(os.path.join(bg_dir, "Contents.json"), {
        "colors": [
            {"color": white, "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "color": white, "idiom": "universal"},
        ],
        "info": {"author": "xcode", "version": 1},
    })
    print(f"shield crop {shield.size}; icon shield {big.size} on {ICON_SIZE}x{ICON_SIZE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

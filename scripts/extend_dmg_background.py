#!/usr/bin/env python3
"""Rescale the upstream Blender DMG background to fit our 720x480 pt window.

The upstream background.tif is 1080x700 px (the size Blender's official DMG
expects, ~540x350 pts on retina). UPBGE's DMG window is bigger (720x480 pts)
to fit Blender, Blenderplayer, and the /Applications drag-target — so we
rescale the background to 1440x960 px (the retina @2x of 720x480) so it
fills the whole window without any white edges.

Output: upbge/release/darwin/background_extended.tif
"""
from PIL import Image
import os

ROOT = os.environ.get("UPBGE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC  = os.path.join(ROOT, "upbge/release/darwin/background.tif")
DST  = os.path.join(ROOT, "upbge/release/darwin/background_extended.tif")

# Window size in points × 2 (retina).
TARGET_W, TARGET_H = 1440, 960

orig = Image.open(SRC).convert("RGB")
out = orig.resize((TARGET_W, TARGET_H), Image.LANCZOS)
# TIFF + JPEG compression matches the original encoding, keeps file size sane.
out.save(DST, format="TIFF", compression="jpeg")
print(f"wrote {DST}: {out.size[0]} x {out.size[1]} px")
print(f"original: {orig.size[0]} x {orig.size[1]} px → "
      f"scale factor: {TARGET_W/orig.size[0]:.3f}x horizontal, "
      f"{TARGET_H/orig.size[1]:.3f}x vertical")

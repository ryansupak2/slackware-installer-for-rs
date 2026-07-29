#!/usr/bin/env python3
"""Render bobdobbs.txt as a PNG with Berkeley Mono, black background, equal padding."""

from PIL import Image, ImageDraw, ImageFont
import os
import sys

# Resolve paths relative to the repo root
REPO_DIR = os.environ.get("REPO_DIR", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEXT_PATH = os.path.join(REPO_DIR, "dotfiles", "neofetch", "bobdobbs.txt")
OUT_PATH  = os.path.join(REPO_DIR, "dotfiles", "neofetch", "bobdobbs.png")

FONT_PATH = "/usr/share/fonts/TTF/BerkeleyMono-Regular.ttf"
FONT_SIZE = 18
LINE_SPACING = 1.4
PADDING = 30

# Read the ASCII art
with open(TEXT_PATH) as f:
    lines = f.readlines()

# Strip trailing newlines only — preserve all spaces in the art
lines = [l.rstrip('\n') for l in lines]

# Load font
font = ImageFont.truetype(FONT_PATH, FONT_SIZE)

# Accurate line height from FreeType face
try:
    ft_height = font.font.height
    ft_scale = font.font.size / font.font.units_per_EM
    cell_height = ft_height * ft_scale
except Exception:
    cell_height = font.size * 1.2

line_height = int(cell_height * LINE_SPACING)

# Measure max text width
tmp_img = Image.new("RGB", (1, 1))
tmp_draw = ImageDraw.Draw(tmp_img)

max_text_w = 0
for line in lines:
    bbox = tmp_draw.textbbox((0, 0), line, font=font)
    w = bbox[2] - bbox[0]
    if w > max_text_w:
        max_text_w = w

text_h = line_height * len(lines)
print(f"Text block: {max_text_w}x{text_h} (cols x rows: {max(len(l) for l in lines)}x{len(lines)})")

# Equal padding on all sides
img_w = int(max_text_w) + 2 * PADDING
img_h = int(text_h) + 2 * PADDING

# Force portrait: if still wider than tall, add extra vertical padding
if img_w >= img_h:
    extra = (img_w - img_h) + 40
    img_h += extra
    top_pad = PADDING + extra // 2
else:
    top_pad = PADDING

print(f"Image: {img_w}x{img_h}")

# Create black image
img = Image.new("RGB", (img_w, img_h), "#000000")
draw = ImageDraw.Draw(img)

# Draw each line left-aligned at PADDING (equal left/right margins)
y = top_pad
for line in lines:
    draw.text((PADDING, y), line, font=font, fill="#FFFFFF")
    y += line_height

img.save(OUT_PATH, "PNG")
print(f"Saved {img_w}x{img_h} → {OUT_PATH}")

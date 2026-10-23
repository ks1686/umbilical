#!/usr/bin/env python3
"""Build the macOS app icon set from the chosen folder-and-cable art.

The source JPEGs are the full composition (folder, cable, light or dark
fill). This script strips every metadata segment from those JPEGs, then
draws each one onto Apple's 1024-pt macOS grid: an 824-pt squircle tile
with a 100-pt transparent margin. Light is the default appearance. Dark
is the luminosity=dark asset-catalog variant. Icon Composer .icon files
are not produced; they need the Icon Composer app on a Mac.

Run from the repository root:

    python3 design/icon/generate.py
"""

from __future__ import annotations

import argparse
import io
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SOURCE_LIGHT = Path(__file__).resolve().parent / "umbilical-icon-light-source.jpg"
SOURCE_DARK = Path(__file__).resolve().parent / "umbilical-icon-dark-source.jpg"
ASSET_CATALOG = ROOT / "App" / "Assets.xcassets"
APPICON_SET = ASSET_CATALOG / "AppIcon.appiconset"
DOCS_ASSETS = ROOT / "docs" / "assets"
DOCS_ICON = DOCS_ASSETS / "umbilical-icon.png"
DOCS_PREVIEW = DOCS_ASSETS / "umbilical-icon-preview.png"

CANVAS = 1024
TILE = 824
MARGIN = (CANVAS - TILE) // 2
SQUIRCLE_N = 5.0
SUPERSAMPLE = 4

# Point size, scale, pixel size. Every macOS AppIcon slot.
MAC_SLOTS: list[tuple[int, int, int]] = [
    (16, 1, 16),
    (16, 2, 32),
    (32, 1, 32),
    (32, 2, 64),
    (128, 1, 128),
    (128, 2, 256),
    (256, 1, 256),
    (256, 2, 512),
    (512, 1, 512),
    (512, 2, 1024),
]

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_KEEP = {b"IHDR", b"IDAT", b"IEND"}


def icon_filename(size_pt: int, scale: int, *, dark: bool) -> str:
    scale_s = "" if scale == 1 else "@2x"
    appearance = "_dark" if dark else ""
    return f"appicon_{size_pt}x{size_pt}{scale_s}{appearance}.png"


def png_keep_essential_chunks(data: bytes) -> bytes:
    if data[:8] != PNG_SIG:
        raise SystemExit("generated PNG is missing the PNG signature")
    out = bytearray(PNG_SIG)
    pos = 8
    while pos + 12 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        end = pos + 12 + length
        if end > len(data):
            raise SystemExit("generated PNG is truncated")
        if ctype in PNG_KEEP:
            out.extend(data[pos:end])
        pos = end
    return bytes(out)


def save_png(image: Image.Image, path: Path) -> None:
    if image.mode != "RGBA":
        raise SystemExit(f"{path} would not be RGBA")
    buf = io.BytesIO()
    image.save(buf, format="PNG", optimize=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png_keep_essential_chunks(buf.getvalue()))


def save_jpeg_without_metadata(image: Image.Image, path: Path) -> None:
    rgb = image.convert("RGB")
    rgb.save(path, format="JPEG", quality=95, optimize=True, subsampling=2)


def strip_source_jpeg(path: Path) -> None:
    image = Image.open(path)
    rgb = image.convert("RGB")
    # Copy samples only so Pillow cannot round-trip EXIF, XMP, or C2PA.
    clean = Image.frombytes("RGB", rgb.size, rgb.tobytes())
    save_jpeg_without_metadata(clean, path)


def squircle_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    ys = np.linspace(-1.0, 1.0, big, dtype=np.float64)
    xs = np.linspace(-1.0, 1.0, big, dtype=np.float64)
    x, y = np.meshgrid(xs, ys)
    inside = (np.abs(x) ** SQUIRCLE_N + np.abs(y) ** SQUIRCLE_N) <= 1.0
    mask = Image.fromarray((inside.astype(np.uint8) * 255), mode="L")
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def resize_rgba(image: Image.Image, size: int) -> Image.Image:
    if image.size == (size, size):
        return image.copy()
    rgba = np.asarray(image.convert("RGBA")).astype(np.float64)
    alpha = rgba[..., 3:4]
    premul = np.concatenate([rgba[..., :3] * (alpha / 255.0), alpha], axis=2)
    premul_img = Image.fromarray(np.clip(premul, 0, 255).astype(np.uint8), "RGBA")
    resized = premul_img.resize((size, size), Image.Resampling.LANCZOS)
    out = np.asarray(resized).astype(np.float64)
    out_alpha = out[..., 3:4]
    rgb = np.divide(
        out[..., :3],
        out_alpha / 255.0,
        out=np.zeros_like(out[..., :3]),
        where=out_alpha > 0.5,
    )
    out[..., :3] = np.clip(rgb, 0, 255)
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def compose_tile(source: Image.Image) -> Image.Image:
    art = source.convert("RGB").resize((TILE, TILE), Image.Resampling.LANCZOS)
    tile = art.convert("RGBA")
    mask = squircle_mask(TILE)
    tile.putalpha(mask)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(tile, (MARGIN, MARGIN), tile)
    return canvas


def write_catalog_json() -> None:
    images: list[dict[str, object]] = []
    for size_pt, scale, _pixels in MAC_SLOTS:
        entry: dict[str, object] = {
            "filename": icon_filename(size_pt, scale, dark=False),
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size_pt}x{size_pt}",
        }
        images.append(entry)
        dark: dict[str, object] = {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": icon_filename(size_pt, scale, dark=True),
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size_pt}x{size_pt}",
        }
        images.append(dark)
    payload = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    APPICON_SET.mkdir(parents=True, exist_ok=True)
    (APPICON_SET / "Contents.json").write_text(
        json.dumps(payload, indent=2) + "\n",
        encoding="utf-8",
    )
    (ASSET_CATALOG / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def load_font(size: int) -> ImageFont.ImageFont:
    path = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
    if path.is_file():
        return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def compose_preview(light: Image.Image, dark: Image.Image) -> Image.Image:
    """1024 / 128 / 32 tiles on light and dark backgrounds, both appearances."""
    sizes = (1024, 128, 32)
    pad = 36
    gap = 28
    label_h = 44
    section_h = 36
    col_w = [1024, 160, 80]
    row_h = 1024
    inner_w = sum(col_w) + gap * (len(col_w) - 1)
    width = pad * 2 + inner_w
    # Two appearances, each with two background rows.
    height = pad * 2 + (section_h + label_h + row_h) * 4 + gap * 3
    sheet = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    title_font = load_font(26)
    label_font = load_font(20)
    light_bg = (242, 242, 247)
    dark_bg = (28, 28, 30)

    rows = [
        ("Default (light tile) on light", light, light_bg),
        ("Default (light tile) on dark", light, dark_bg),
        ("Dark appearance on light", dark, light_bg),
        ("Dark appearance on dark", dark, dark_bg),
    ]
    y = pad
    for title, icon, bg in rows:
        draw.text((pad, y), title, fill=(50, 50, 50), font=title_font)
        y += section_h
        x = pad
        for pixels, column in zip(sizes, col_w):
            cell = Image.new("RGB", (column, row_h), bg)
            scaled = icon if pixels == CANVAS else resize_rgba(icon, pixels)
            ox = (column - pixels) // 2
            oy = (row_h - pixels) // 2
            cell.paste(scaled, (ox, oy), scaled)
            sheet.paste(cell, (x, y))
            draw.text(
                (x, y + row_h + 8),
                f"{pixels} px",
                fill=(50, 50, 50),
                font=label_font,
            )
            x += column + gap
        y += row_h + label_h + gap
    return sheet.convert("RGBA")


def generate_slots(master: Image.Image, *, dark: bool) -> None:
    for size_pt, scale, pixels in MAC_SLOTS:
        icon = master if pixels == CANVAS else resize_rgba(master, pixels)
        save_png(icon, APPICON_SET / icon_filename(size_pt, scale, dark=dark))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strip-sources-only",
        action="store_true",
        help="rewrite the source JPEGs without metadata and stop",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not SOURCE_LIGHT.is_file() or not SOURCE_DARK.is_file():
        raise SystemExit("source JPEGs are missing under design/icon")
    strip_source_jpeg(SOURCE_LIGHT)
    strip_source_jpeg(SOURCE_DARK)
    if args.strip_sources_only:
        return

    light_source = Image.open(SOURCE_LIGHT)
    dark_source = Image.open(SOURCE_DARK)
    light_tile = compose_tile(light_source)
    dark_tile = compose_tile(dark_source)

    if APPICON_SET.exists():
        for old in APPICON_SET.glob("*.png"):
            old.unlink()
    write_catalog_json()
    generate_slots(light_tile, dark=False)
    generate_slots(dark_tile, dark=True)

    DOCS_ASSETS.mkdir(parents=True, exist_ok=True)
    save_png(resize_rgba(light_tile, 512), DOCS_ICON)
    preview = compose_preview(light_tile, dark_tile)
    # The proof sheet is a labeled RGB composite, still saved without text chunks.
    save_png(preview, DOCS_PREVIEW)
    print(f"wrote {APPICON_SET.relative_to(ROOT)}", file=sys.stderr)
    print(f"wrote {DOCS_ICON.relative_to(ROOT)}", file=sys.stderr)
    print(f"wrote {DOCS_PREVIEW.relative_to(ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()

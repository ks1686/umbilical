#!/usr/bin/env python3
"""Reject committed icon files that still carry metadata or a full-bleed tile.

Checks the source JPEGs, the Icon Composer App/AppIcon.icon bundle, and
the docs icon. AppIcon.icon layers are full 1024x1024 art; Icon Composer
and actool apply the macOS mask, so they are not checked for a margin.
The bundle must have a light default and a dark specialization. The proof
preview sheet is a labeled composite, so it may be opaque; it still must
be an RGBA PNG with no text or EXIF chunks.
"""

from __future__ import annotations

import json
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "design" / "icon"
APP_ICON = ROOT / "App" / "AppIcon.icon"
APP_ICON_JSON = APP_ICON / "icon.json"
APP_ICON_ASSETS = APP_ICON / "Assets"
APP_ICON_PIXELS = 1024
# An appiconset next to the .icon would compete for the AppIcon name.
LEGACY_APPICON_SET = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"
DOCS_ICON = ROOT / "docs" / "assets" / "umbilical-icon.png"
DOCS_PREVIEW = ROOT / "docs" / "assets" / "umbilical-icon-preview.png"

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_ALLOWED = {b"IHDR", b"IDAT", b"IEND"}
# APP0 JFIF and APP14 Adobe color transform are encoding tags, not EXIF/XMP.
JPEG_ALLOWED_APP = {0xE0, 0xEE}


class CheckError(Exception):
    pass


def fail(path: Path, message: str) -> None:
    raise CheckError(f"{path.relative_to(ROOT)}: {message}")


def jpeg_app_and_comment_segments(data: bytes) -> list[tuple[int, bytes]]:
    if data[:2] != b"\xff\xd8":
        raise CheckError("not a JPEG")
    found: list[tuple[int, bytes]] = []
    i = 2
    length = len(data)
    while i + 1 < length:
        if data[i] != 0xFF:
            i += 1
            continue
        while i < length and data[i] == 0xFF:
            i += 1
        if i >= length:
            break
        marker = data[i]
        i += 1
        if marker == 0xDA:  # SOS: entropy-coded data follows
            break
        if marker == 0xD9:
            break
        if marker in {0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0x01, 0xD8}:
            continue
        if i + 2 > length:
            break
        seglen = struct.unpack(">H", data[i : i + 2])[0]
        payload = data[i + 2 : i + seglen]
        if marker == 0xFE or 0xE0 <= marker <= 0xEF:
            found.append((marker, payload))
        i += seglen
    return found


def check_jpeg(path: Path) -> None:
    data = path.read_bytes()
    try:
        segments = jpeg_app_and_comment_segments(data)
    except CheckError as exc:
        fail(path, str(exc))
    bad = [marker for marker, _ in segments if marker not in JPEG_ALLOWED_APP]
    if bad:
        names = ", ".join(
            f"APP{m - 0xE0}" if 0xE0 <= m <= 0xEF else "COM" for m in bad
        )
        fail(path, f"still contains metadata markers {names}")
    for _, payload in segments:
        lowered = payload.lower()
        for needle in (b"exif", b"xmp", b"c2pa", b"jumbf", b"grok imagine"):
            if needle in lowered:
                fail(path, f"still contains {needle.decode('ascii', 'replace')}")


def iter_png_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    if data[:8] != PNG_SIG:
        raise CheckError("not a PNG")
    chunks: list[tuple[bytes, bytes]] = []
    pos = 8
    while pos + 12 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        crc_start = pos + 8 + length
        if crc_start + 4 > len(data):
            raise CheckError("truncated PNG chunk")
        crc = struct.unpack(">I", data[crc_start : crc_start + 4])[0]
        expect = zlib.crc32(ctype + payload) & 0xFFFFFFFF
        if crc != expect:
            raise CheckError(f"bad CRC on {ctype.decode('ascii', 'replace')} chunk")
        chunks.append((ctype, payload))
        pos = crc_start + 4
        if ctype == b"IEND":
            break
    return chunks


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_rgba_png(data: bytes) -> tuple[int, int, bytes]:
    chunks = iter_png_chunks(data)
    ihdr = next((payload for ctype, payload in chunks if ctype == b"IHDR"), None)
    if ihdr is None or len(ihdr) < 13:
        raise CheckError("PNG has no IHDR")
    width, height, bit_depth, color_type, compression, filt, interlace = struct.unpack(
        ">IIBBBBB", ihdr[:13]
    )
    if bit_depth != 8 or color_type != 6 or compression != 0 or filt != 0 or interlace != 0:
        raise CheckError(
            f"PNG must be 8-bit RGBA (got bit_depth={bit_depth} "
            f"color_type={color_type} interlace={interlace})"
        )
    extra = [ctype for ctype, _ in chunks if ctype not in PNG_ALLOWED]
    if extra:
        names = b", ".join(extra).decode("ascii", "replace")
        raise CheckError(f"PNG still contains ancillary chunks {names}")
    raw = zlib.decompress(b"".join(payload for ctype, payload in chunks if ctype == b"IDAT"))
    bpp = 4
    stride = width * bpp
    expected = (1 + stride) * height
    if len(raw) != expected:
        raise CheckError(f"PNG IDAT length {len(raw)} != {expected}")
    pixels = bytearray(height * stride)
    prev = bytearray(stride)
    offset = 0
    for row in range(height):
        ftype = raw[offset]
        scan = bytearray(raw[offset + 1 : offset + 1 + stride])
        offset += 1 + stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(stride):
                left = scan[i - bpp] if i >= bpp else 0
                scan[i] = (scan[i] + left) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                scan[i] = (scan[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = scan[i - bpp] if i >= bpp else 0
                scan[i] = (scan[i] + ((left + prev[i]) // 2)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = scan[i - bpp] if i >= bpp else 0
                up = prev[i]
                ul = prev[i - bpp] if i >= bpp else 0
                scan[i] = (scan[i] + paeth(left, up, ul)) & 0xFF
        else:
            raise CheckError(f"unsupported PNG filter {ftype}")
        pixels[row * stride : (row + 1) * stride] = scan
        prev = scan
    return width, height, bytes(pixels)


def alpha_at(pixels: bytes, width: int, x: int, y: int) -> int:
    return pixels[(y * width + x) * 4 + 3]


def check_png_clean(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    try:
        return decode_rgba_png(data)
    except CheckError as exc:
        fail(path, str(exc))
        raise


def check_tile_margin(path: Path, width: int, height: int, pixels: bytes) -> None:
    if width != height:
        fail(path, f"icon is {width}x{height}, not square")
    size = width
    for x, y in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
        if alpha_at(pixels, size, x, y) != 0:
            fail(path, f"corner ({x},{y}) is not transparent")
    mid = size // 2
    if alpha_at(pixels, size, mid, mid) < 250:
        fail(path, "center of the tile is not opaque")
    # Outer frame must be transparent. At 16 px the 100/1024 macOS margin
    # is about 1.5 px, so only the outermost pixel is a reliable sample.
    if alpha_at(pixels, size, mid, 0) > 16:
        fail(path, "top margin is not transparent")
    if alpha_at(pixels, size, 0, mid) > 16:
        fail(path, "left margin is not transparent")
    if alpha_at(pixels, size, mid, size - 1) > 16:
        fail(path, "bottom margin is not transparent")
    if alpha_at(pixels, size, size - 1, mid) > 16:
        fail(path, "right margin is not transparent")
    margin = max(1, round(size * 100 / 1024))
    inside = min(size - 1, margin + max(4, size // 16))
    if alpha_at(pixels, size, mid, inside) < 200:
        fail(path, "tile interior is transparent; icon may be full-bleed or empty")


def check_icon_layer_png(path: Path) -> None:
    """Icon Composer layer: 1024x1024, 8-bit RGB or RGBA, no ancillary chunks."""
    try:
        chunks = iter_png_chunks(path.read_bytes())
    except CheckError as exc:
        fail(path, str(exc))
    ihdr = next((payload for ctype, payload in chunks if ctype == b"IHDR"), None)
    if ihdr is None or len(ihdr) < 13:
        fail(path, "PNG has no IHDR")
    width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
        ">IIBBBBB", ihdr[:13]
    )
    extra = sorted({ctype for ctype, _ in chunks if ctype not in PNG_ALLOWED})
    if extra:
        names = b", ".join(extra).decode("ascii", "replace")
        fail(path, f"PNG still contains ancillary chunks {names}")
    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        fail(
            path,
            f"PNG must be 8-bit RGB or RGBA, not interlaced (got bit_depth={bit_depth} "
            f"color_type={color_type} interlace={interlace})",
        )
    if width != APP_ICON_PIXELS or height != APP_ICON_PIXELS:
        fail(path, f"is {width}x{height}, expected {APP_ICON_PIXELS}x{APP_ICON_PIXELS}")


def icon_layer_images(icon: dict) -> tuple[set[str], set[str]]:
    """Return (default image names, dark image names) across every layer."""
    default: set[str] = set()
    dark: set[str] = set()
    groups = icon.get("groups")
    if not isinstance(groups, list) or not groups:
        raise CheckError("icon.json has no groups")
    for group in groups:
        layers = group.get("layers") if isinstance(group, dict) else None
        if not isinstance(layers, list) or not layers:
            raise CheckError("icon.json group has no layers")
        for layer in layers:
            if not isinstance(layer, dict):
                raise CheckError("icon.json layer is not an object")
            name = layer.get("image-name")
            if isinstance(name, str):
                default.add(name)
            specs = layer.get("image-name-specializations", [])
            if not isinstance(specs, list):
                raise CheckError("image-name-specializations is not a list")
            for spec in specs:
                value = spec.get("value") if isinstance(spec, dict) else None
                if not isinstance(value, str):
                    raise CheckError("image-name specialization has no file name")
                appearance = spec.get("appearance")
                if appearance is None:
                    default.add(value)
                elif appearance == "dark":
                    dark.add(value)
    return default, dark


def check_app_icon(errors: list[str]) -> None:
    if LEGACY_APPICON_SET.exists():
        errors.append(
            "App/Assets.xcassets/AppIcon.appiconset must not exist; "
            "App/AppIcon.icon is the app icon"
        )
    if not APP_ICON_JSON.is_file():
        errors.append("App/AppIcon.icon/icon.json is missing")
        return
    try:
        icon = json.loads(APP_ICON_JSON.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        errors.append(f"App/AppIcon.icon/icon.json does not parse: {exc}")
        return
    if not isinstance(icon, dict):
        errors.append("App/AppIcon.icon/icon.json is not an object")
        return
    platforms = icon.get("supported-platforms", {})
    squares = platforms.get("squares") if isinstance(platforms, dict) else None
    if not (squares == "shared" or (isinstance(squares, list) and "macOS" in squares)):
        errors.append("App/AppIcon.icon/icon.json does not support macOS")
    try:
        default, dark = icon_layer_images(icon)
    except CheckError as exc:
        errors.append(f"App/AppIcon.icon/icon.json: {exc}")
        return
    if not default:
        errors.append("App/AppIcon.icon has no default (light) layer image")
    if not dark:
        errors.append("App/AppIcon.icon has no dark appearance layer image")
    if dark and dark <= default:
        errors.append("App/AppIcon.icon dark layer reuses the light image")
    referenced = default | dark
    present = (
        {p.name for p in APP_ICON_ASSETS.iterdir() if p.is_file()}
        if APP_ICON_ASSETS.is_dir()
        else set()
    )
    missing = sorted(referenced - present)
    unused = sorted(present - referenced)
    if missing:
        errors.append("App/AppIcon.icon/Assets is missing " + ", ".join(missing))
    if unused:
        errors.append("App/AppIcon.icon/Assets has unreferenced files " + ", ".join(unused))
    for name in sorted(referenced & present):
        path = APP_ICON_ASSETS / name
        if path.suffix.lower() != ".png":
            errors.append(f"{path.relative_to(ROOT)}: expected a PNG layer")
            continue
        try:
            check_icon_layer_png(path)
        except CheckError as exc:
            errors.append(str(exc))


def main() -> int:
    errors: list[str] = []

    def run(action) -> None:
        try:
            action()
        except CheckError as exc:
            errors.append(str(exc))

    jpegs = sorted(SOURCE_DIR.glob("umbilical-icon-*-source.jpg"))
    if len(jpegs) != 2:
        errors.append("expected two source JPEGs under design/icon")
    for jpeg in jpegs:
        run(lambda jpeg=jpeg: check_jpeg(jpeg))

    check_app_icon(errors)

    if not DOCS_ICON.is_file():
        errors.append("docs/assets/umbilical-icon.png is missing")
    else:

        def _docs() -> None:
            width, height, pixels = check_png_clean(DOCS_ICON)
            if width != 512 or height != 512:
                fail(DOCS_ICON, f"is {width}x{height}, expected 512x512")
            check_tile_margin(DOCS_ICON, width, height, pixels)

        run(_docs)

    if not DOCS_PREVIEW.is_file():
        errors.append("docs/assets/umbilical-icon-preview.png is missing")
    else:
        run(lambda: check_png_clean(DOCS_PREVIEW))

    if errors:
        for item in errors:
            print(item, file=sys.stderr)
        return 1
    print("app icon assets have no metadata; AppIcon.icon has light and dark layers")
    return 0


if __name__ == "__main__":
    sys.exit(main())

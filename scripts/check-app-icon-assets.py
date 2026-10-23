#!/usr/bin/env python3
"""Reject committed icon files that still carry metadata or a full-bleed tile.

Checks the source JPEGs, every AppIcon PNG, and the docs icon. The proof
preview sheet is a labeled composite, so it may be opaque; it still must
be an RGBA PNG with no text or EXIF chunks.
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "design" / "icon"
APPICON_SET = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"
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


def expected_icon_names() -> set[str]:
    names: set[str] = set()
    for size_pt, scale in (
        (16, 1),
        (16, 2),
        (32, 1),
        (32, 2),
        (128, 1),
        (128, 2),
        (256, 1),
        (256, 2),
        (512, 1),
        (512, 2),
    ):
        scale_s = "" if scale == 1 else "@2x"
        names.add(f"appicon_{size_pt}x{size_pt}{scale_s}.png")
        names.add(f"appicon_{size_pt}x{size_pt}{scale_s}_dark.png")
    return names


def check_contents_json(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    compact = text.replace(" ", "").replace("\n", "")
    if '"idiom":"mac"' not in compact:
        fail(path, "AppIcon Contents.json does not declare mac slots")
    if '"value":"dark"' not in compact:
        fail(path, "AppIcon Contents.json has no dark appearance slots")


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

    contents = APPICON_SET / "Contents.json"
    if not contents.is_file():
        errors.append("App/Assets.xcassets/AppIcon.appiconset/Contents.json is missing")
    else:
        run(lambda: check_contents_json(contents))

    expected = expected_icon_names()
    present = {p.name for p in APPICON_SET.glob("*.png")}
    missing = sorted(expected - present)
    extra = sorted(present - expected)
    if missing:
        errors.append("AppIcon is missing " + ", ".join(missing))
    if extra:
        errors.append("AppIcon has unexpected files " + ", ".join(extra))
    for name in sorted(present & expected):
        path = APPICON_SET / name
        def _check(path: Path = path) -> None:
            width, height, pixels = check_png_clean(path)
            pixels_expected = int(name.split("x")[0].split("_")[1])
            # filename is point size; @2x doubles pixels.
            scale = 2 if "@2x" in name else 1
            want = pixels_expected * scale
            if width != want or height != want:
                fail(path, f"is {width}x{height}, expected {want}x{want}")
            check_tile_margin(path, width, height, pixels)

        run(_check)

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
    print("app icon assets are RGBA tiles with no metadata")
    return 0


if __name__ == "__main__":
    sys.exit(main())

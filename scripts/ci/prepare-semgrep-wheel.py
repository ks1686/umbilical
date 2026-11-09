#!/usr/bin/env python3
"""Write the local Semgrep wheel used by requirements/semgrep.txt.

semgrep 1.181.0 through 1.184.0 pin mcp==1.29.0 and OpenTelemetry 1.37.
Those pins make the patched releases uninstallable. This downloads the
official manylinux wheel, checks its hash, and writes a local version whose
Requires-Dist lines allow the versions in requirements/semgrep.in.

The local version is 1.181.0+umbilical.1 so pip will not prefer the PyPI
wheel of 1.181.0. Compressed payloads are copied unchanged.
"""

from __future__ import annotations

import base64
import hashlib
import io
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WHEEL_NAME = (
    "semgrep-1.181.0+umbilical.1-cp310.cp311.cp312.cp313.cp314."
    "py310.py311.py312.py313.py314-none-manylinux_2_34_x86_64.whl"
)
OUT = ROOT / "requirements" / "wheels" / WHEEL_NAME
WHEEL_URL = (
    "https://files.pythonhosted.org/packages/b0/1d/"
    "aed54e9cea5491f0dd54286126216f97ef817a356734d3c9d5e40c124c34/"
    "semgrep-1.181.0-cp310.cp311.cp312.cp313.cp314.py310.py311.py312.py313.py314-"
    "none-manylinux_2_34_x86_64.whl"
)
WHEEL_SHA256 = "c142ec04a2ed144970cb0a92f6877651dd3c088505eec737bb7f4db7ae5f0ffa"
EXPECTED_PATCHED_SHA256 = (
    "e26b771b0f6011d15aaed40b6d7c355cea49d5bd5c8c8f286be65fb732a60687"
)

OLD_DATA = "semgrep-1.181.0.data/"
NEW_DATA = "semgrep-1.181.0+umbilical.1.data/"
OLD_DIST = "semgrep-1.181.0.dist-info/"
NEW_DIST = "semgrep-1.181.0+umbilical.1.dist-info/"

REPLACEMENTS = (
    ("Version: 1.181.0\n", "Version: 1.181.0+umbilical.1\n"),
    ("Requires-Dist: mcp==1.29.0", "Requires-Dist: mcp>=1.30.0"),
    (
        "Requires-Dist: opentelemetry-api~=1.37.0",
        "Requires-Dist: opentelemetry-api>=1.45.1",
    ),
    (
        "Requires-Dist: opentelemetry-sdk~=1.37.0",
        "Requires-Dist: opentelemetry-sdk>=1.45.1",
    ),
    (
        "Requires-Dist: opentelemetry-exporter-otlp-proto-http~=1.37.0",
        "Requires-Dist: opentelemetry-exporter-otlp-proto-http>=1.45.1",
    ),
    (
        "Requires-Dist: opentelemetry-instrumentation-requests~=0.58b0",
        "Requires-Dist: opentelemetry-instrumentation-requests>=0.66b1",
    ),
    (
        "Requires-Dist: opentelemetry-instrumentation-threading~=0.58b0",
        "Requires-Dist: opentelemetry-instrumentation-threading>=0.66b1",
    ),
)

LOCAL_HEADER = struct.Struct("<4s2B4HL2L2H")
CENTRAL_HEADER = struct.Struct("<4s4B4HL2L5H2L")
EOCD = struct.Struct("<4s4H2LH")


def download_official() -> bytes:
    completed = subprocess.run(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--retry",
            "3",
            "--max-time",
            "120",
            WHEEL_URL,
        ],
        check=True,
        capture_output=True,
    )
    data = completed.stdout
    digest = hashlib.sha256(data).hexdigest()
    if digest != WHEEL_SHA256:
        raise SystemExit(
            f"official semgrep wheel hash is {digest}, expected {WHEEL_SHA256}"
        )
    return data


def rename(name: str) -> str:
    if name.startswith(OLD_DATA):
        return NEW_DATA + name[len(OLD_DATA) :]
    if name.startswith(OLD_DIST):
        return NEW_DIST + name[len(OLD_DIST) :]
    raise SystemExit(f"unexpected wheel member {name}")


def patch_metadata(data: bytes) -> bytes:
    text = data.decode("utf-8")
    for old, new in REPLACEMENTS:
        count = text.count(old)
        if count != 1:
            raise SystemExit(f"expected one {old!r} in METADATA, found {count}")
        text = text.replace(old, new, 1)
    return text.encode("utf-8")


def record_hash(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return "sha256=" + encoded


def patch_record(data: bytes, metadata_name: str, metadata: bytes) -> bytes:
    text = data.decode("utf-8")
    text = text.replace(OLD_DATA, NEW_DATA).replace(OLD_DIST, NEW_DIST)
    prefix = metadata_name + ","
    lines = text.splitlines()
    replaced = False
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = f"{metadata_name},{record_hash(metadata)},{len(metadata)}"
            replaced = True
            break
    if not replaced:
        raise SystemExit(f"RECORD has no entry for {metadata_name}")
    body = "\n".join(lines)
    if text.endswith("\n"):
        body += "\n"
    return body.encode("utf-8")


def parse_local(blob: bytes) -> dict[str, object]:
    if len(blob) < LOCAL_HEADER.size or blob[:4] != b"PK\x03\x04":
        raise SystemExit("bad local file header")
    (
        _sig,
        extract,
        reserved,
        flags,
        method,
        dos_time,
        dos_date,
        crc,
        csize,
        usize,
        namelen,
        extralen,
    ) = LOCAL_HEADER.unpack_from(blob)
    if flags & 0x8:
        raise SystemExit("data descriptors are not supported")
    cursor = LOCAL_HEADER.size
    name = blob[cursor : cursor + namelen].decode("utf-8")
    cursor += namelen
    extra = blob[cursor : cursor + extralen]
    cursor += extralen
    payload = blob[cursor : cursor + csize]
    if cursor + csize != len(blob):
        raise SystemExit(f"local entry length mismatch for {name}")
    return {
        "extract": extract,
        "reserved": reserved,
        "flags": flags,
        "method": method,
        "time": dos_time,
        "date": dos_date,
        "crc": crc,
        "extra": extra,
        "payload": payload,
        "usize": usize,
        "name": name,
    }


def local_bytes(entry: dict[str, object]) -> bytes:
    name_b = str(entry["name"]).encode("utf-8")
    payload = bytes(entry["payload"])
    extra = bytes(entry["extra"])
    header = LOCAL_HEADER.pack(
        b"PK\x03\x04",
        entry["extract"],
        entry["reserved"],
        entry["flags"],
        entry["method"],
        entry["time"],
        entry["date"],
        entry["crc"],
        len(payload),
        entry["usize"],
        len(name_b),
        len(extra),
    )
    return header + name_b + extra + payload


def central_bytes(entry: dict[str, object], offset: int) -> bytes:
    name_b = str(entry["name"]).encode("utf-8")
    payload = bytes(entry["payload"])
    extra = bytes(entry["extra"])
    return CENTRAL_HEADER.pack(
        b"PK\x01\x02",
        20,
        3,
        entry["extract"],
        entry["reserved"],
        entry["flags"],
        entry["method"],
        entry["time"],
        entry["date"],
        entry["crc"],
        len(payload),
        entry["usize"],
        len(name_b),
        len(extra),
        0,
        0,
        0,
        entry["attr"],
        offset,
    ) + name_b + extra


def stored_entry(name: str, data: bytes) -> dict[str, object]:
    return {
        "name": name,
        "extract": 20,
        "reserved": 0,
        "flags": 0,
        "method": 0,
        "time": 0,
        "date": (1 << 5) | 1,
        "crc": zipfile.crc32(data) & 0xFFFFFFFF,
        "extra": b"",
        "payload": data,
        "usize": len(data),
        "attr": 0o100644 << 16,
    }


def next_local_offset(info: zipfile.ZipInfo, infos: list[zipfile.ZipInfo], end: int) -> int:
    later = [item.header_offset for item in infos if item.header_offset > info.header_offset]
    return min(later) if later else end


def build_wheel(official: bytes) -> bytes:
    source = zipfile.ZipFile(io.BytesIO(official))
    infos = source.infolist()
    old_metadata = next(info.filename for info in infos if info.filename.endswith(".dist-info/METADATA"))
    old_record = next(info.filename for info in infos if info.filename.endswith(".dist-info/RECORD"))
    metadata = patch_metadata(source.read(old_metadata))
    record = patch_record(source.read(old_record), rename(old_metadata), metadata)
    entries: list[dict[str, object]] = []
    for info in infos:
        if info.filename == old_metadata:
            entries.append(stored_entry(rename(info.filename), metadata))
            continue
        if info.filename == old_record:
            entries.append(stored_entry(rename(info.filename), record))
            continue
        blob = official[info.header_offset : next_local_offset(info, infos, source.start_dir)]
        parsed = parse_local(blob)
        parsed["name"] = rename(str(parsed["name"]))
        parsed["attr"] = info.external_attr
        entries.append(parsed)
    out = bytearray()
    offsets: list[int] = []
    for entry in entries:
        offsets.append(len(out))
        out += local_bytes(entry)
    central_start = len(out)
    central = bytearray()
    for entry, offset in zip(entries, offsets):
        central += central_bytes(entry, offset)
    out += central
    out += EOCD.pack(
        b"PK\x05\x06",
        0,
        0,
        len(entries),
        len(entries),
        len(central),
        central_start,
        0,
    )
    return bytes(out)


def assert_wheel(patched: bytes) -> None:
    with zipfile.ZipFile(io.BytesIO(patched)) as check:
        bad = check.testzip()
        if bad:
            raise SystemExit(f"bad crc for {bad}")
        names = check.namelist()
        if any(name.startswith(OLD_DATA) or name.startswith(OLD_DIST) for name in names):
            raise SystemExit("wheel still contains the original version paths")
        metadata_name = next(name for name in names if name.endswith(".dist-info/METADATA"))
        record_name = next(name for name in names if name.endswith(".dist-info/RECORD"))
        metadata = check.read(metadata_name).decode()
        record = check.read(record_name).decode()
        if "Version: 1.181.0+umbilical.1" not in metadata:
            raise SystemExit("METADATA version was not rewritten")
        if "mcp>=1.30.0" not in metadata or "opentelemetry-api>=1.45.1" not in metadata:
            raise SystemExit("patched METADATA does not contain the new requirements")
        if "mcp==1.29.0" in metadata or "~=1.37.0" in metadata or "~=0.58b0" in metadata:
            raise SystemExit("patched METADATA still has the old pins")
        if record_hash(check.read(metadata_name)) not in record:
            raise SystemExit("RECORD hash does not match patched METADATA")
        # A .data directory member must exist or semgrep-core will not be installed.
        if not any(name.startswith(NEW_DATA) for name in names):
            raise SystemExit("patched wheel is missing package data")


def main() -> None:
    patched = build_wheel(download_official())
    assert_wheel(patched)
    digest = hashlib.sha256(patched).hexdigest()
    if EXPECTED_PATCHED_SHA256 and digest != EXPECTED_PATCHED_SHA256:
        raise SystemExit(
            f"patched wheel hash is {digest}, expected {EXPECTED_PATCHED_SHA256}"
        )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    temporary = OUT.with_suffix(".whl.tmp")
    temporary.write_bytes(patched)
    temporary.replace(OUT)
    print(f"{digest}  {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"prepare-semgrep-wheel: {exc}", file=sys.stderr)
        raise

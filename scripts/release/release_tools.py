#!/usr/bin/env python3
"""Helpers for the umbilical release workflow.

These functions do not print private keys. Callers pass secrets through the
environment, not through argv.
"""

from __future__ import annotations

import argparse
import base64
import copy
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

FEED_URL = "https://github.com/ks1686/umbilical/releases/latest/download/appcast.xml"
PUBLIC_ED_KEY = "wMhJbYoJtpde3xrtBBL1neu9PM5giL3OnYmE7C04OFY="
REPO = "ks1686/umbilical"
SPARKLE_VERSION = "2.9.6"
SPARKLE_SPM_SHA256 = "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SIGNATURE_LINE_RE = re.compile(
    r'^sparkle:edSignature="([A-Za-z0-9+/=]+)" length="([0-9]+)"$'
)
MINIMUM_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
PKCS8_SEED_PREFIX = bytes.fromhex("302e020100300506032b657004220420")


def fail(message: str) -> None:
    raise SystemExit(message)


def version_from_tag(tag: str) -> str:
    if TAG_RE.fullmatch(tag) is None:
        fail("release tag must look like v1.2.3")
    return tag[1:]


def assert_repo(name: str) -> None:
    if name != REPO:
        fail("signed releases only run from ks1686/umbilical")


def dmg_name(version: str) -> str:
    if VERSION_RE.fullmatch(version) is None:
        fail("version must look like 1.2.3")
    return f"umbilical-{version}.dmg"


def dmg_url(version: str) -> str:
    return f"https://github.com/{REPO}/releases/download/v{version}/{dmg_name(version)}"


def normalize_organization_id(raw: str | None) -> str:
    text = (raw or "").strip()
    if text == "" or "$(" in text:
        fail("POLAR_ORGANIZATION_ID is empty")
    if UUID_RE.fullmatch(text) is None:
        fail("POLAR_ORGANIZATION_ID is not a UUID")
    return text.lower()


def write_licensing_xcconfig(organization_id: str, dest: Path) -> None:
    if dest.name != "Licensing.local.xcconfig":
        fail("refusing to write licensing config to an unexpected path")
    if not dest.parent.is_dir():
        fail("Config directory is missing")
    value = normalize_organization_id(organization_id)
    contents = (
        "// Written by the release workflow. Not an access token.\n"
        f"POLAR_ORGANIZATION_ID = {value}\n"
    )
    dest.write_text(contents, encoding="utf-8")
    dest.chmod(0o644)


def _compact(text: str) -> str:
    return "".join(text.split())


def ed25519_public_key(secret_b64: str) -> str:
    try:
        raw = base64.b64decode(_compact(secret_b64), validate=True)
    except Exception:
        fail("SPARKLE_ED_PRIVATE_KEY is not valid base64")
    if len(raw) == 32:
        public = _public_key_from_seed(raw)
    elif len(raw) == 96:
        public = raw[64:]
    else:
        fail(
            "SPARKLE_ED_PRIVATE_KEY must decode to 32 bytes "
            "(current generate_keys -x seed) or 96 bytes (older Sparkle export)"
        )
    if len(public) != 32:
        fail("derived Sparkle public key is not 32 bytes")
    return base64.b64encode(public).decode("ascii")


def _public_key_from_seed(seed: bytes) -> bytes:
    der = PKCS8_SEED_PREFIX + seed
    path = ""
    try:
        handle = tempfile.NamedTemporaryFile(delete=False)
        path = handle.name
        handle.write(der)
        handle.close()
        os.chmod(path, 0o600)
        result = subprocess.run(
            [
                "openssl",
                "pkey",
                "-inform",
                "DER",
                "-in",
                path,
                "-pubout",
                "-outform",
                "DER",
            ],
            check=False,
            capture_output=True,
        )
    finally:
        if path:
            os.unlink(path)
    if result.returncode != 0 or len(result.stdout) < 32:
        fail("could not derive the Sparkle public key")
    return result.stdout[-32:]


def plist_string(plist: dict, key: str) -> str:
    value = plist.get(key)
    if not isinstance(value, str) or value == "":
        fail(f"built app is missing {key}")
    return value


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        loaded = plistlib.load(handle)
    if not isinstance(loaded, dict):
        fail(f"{path} is not a plist dictionary")
    return loaded


def assert_private_key_matches(secret: str, expected_public: str) -> None:
    if secret.strip() == "":
        fail("SPARKLE_ED_PRIVATE_KEY is empty")
    derived = ed25519_public_key(secret)
    if derived != expected_public:
        fail(
            "SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey "
            f"(derived {derived}, expected {expected_public})"
        )


def check_sparkle_key(info_plist: Path) -> None:
    source = load_plist(info_plist)
    expected = plist_string(source, "SUPublicEDKey")
    if expected != PUBLIC_ED_KEY:
        fail("SUPublicEDKey in Info.plist does not match the release feed key")
    assert_private_key_matches(os.environ.get("SPARKLE_ED_PRIVATE_KEY", ""), expected)


def parse_signature_line(text: str) -> tuple[str, str]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        fail("sign_update did not return one signature line")
    match = SIGNATURE_LINE_RE.fullmatch(lines[0])
    if match is None:
        fail("sign_update returned an unexpected signature line")
    return match.group(1), match.group(2)


def _sparkle_version(item: ET.Element) -> str:
    node = item.find(f"{{{SPARKLE_NS}}}version")
    if node is None or node.text is None:
        return ""
    return node.text.strip()


def _load_previous_items(path: Path | None, version: str) -> list[ET.Element]:
    if path is None or not path.is_file() or path.stat().st_size == 0:
        return []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        fail("previous appcast is not XML")
    channel = root.find("channel")
    if channel is None:
        fail("previous appcast has no channel")
    kept: list[ET.Element] = []
    for item in channel.findall("item"):
        if _sparkle_version(item) == version:
            continue
        kept.append(copy.deepcopy(item))
    return kept


def render_appcast(
    *,
    version: str,
    short_version: str,
    minimum: str,
    signature: str,
    length: int,
    previous: Path | None,
    output: Path,
    pubdate: str,
) -> None:
    if VERSION_RE.fullmatch(version) is None:
        fail("version must look like 1.2.3")
    if VERSION_RE.fullmatch(short_version) is None:
        fail("short version must look like 1.2.3")
    if MINIMUM_RE.fullmatch(minimum) is None:
        fail("minimum system version is not a dotted number")
    if not re.fullmatch(r"[A-Za-z0-9+/=]+", signature):
        fail("ed signature is not base64")
    if length < 1:
        fail("dmg length is empty")

    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "umbilical"
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "description").text = "umbilical updates"
    ET.SubElement(channel, "language").text = "en"

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {short_version}"
    ET.SubElement(item, "pubDate").text = pubdate
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = short_version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = minimum
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": dmg_url(version),
            "length": str(length),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": signature,
        },
    )

    for old in _load_previous_items(previous, version):
        channel.append(old)

    if hasattr(ET, "indent"):
        ET.indent(rss, space="  ")
    body = ET.tostring(rss, encoding="utf-8")
    output.write_bytes(b'<?xml version="1.0" encoding="utf-8"?>\n' + body + b"\n")


def render_cask(version: str, sha256: str, *, draft_header: bool) -> str:
    if VERSION_RE.fullmatch(version) is None:
        fail("version must look like 1.2.3")
    if SHA256_RE.fullmatch(sha256) is None:
        fail("sha256 must be 64 hex characters")
    header = ""
    if draft_header:
        header = (
            "# Draft for ks1686/homebrew-tap.\n"
            "# The release workflow uploads the same cask with the real version and sha256.\n"
            "# Do not push this file. Copy the release asset into the tap after review.\n"
        )
    return (
        f"{header}"
        'cask "umbilical" do\n'
        f'  version "{version}"\n'
        f'  sha256 "{sha256}"\n'
        "\n"
        '  url "https://github.com/ks1686/umbilical/releases/download/'
        'v#{version}/umbilical-#{version}.dmg"\n'
        '  name "umbilical"\n'
        '  desc "Download manager that never seeds"\n'
        '  homepage "https://github.com/ks1686/umbilical"\n'
        "\n"
        "  auto_updates true\n"
        '  depends_on macos: ">= :sonoma"\n'
        "\n"
        '  app "umbilical.app"\n'
        "\n"
        "  zap trash: [\n"
        '    "~/Library/Caches/me.peapod.umbilical",\n'
        '    "~/Library/Containers/me.peapod.umbilical.extension",\n'
        '    "~/Library/HTTPStorages/me.peapod.umbilical",\n'
        '    "~/Library/Preferences/me.peapod.umbilical.extension.plist",\n'
        '    "~/Library/Preferences/me.peapod.umbilical.plist",\n'
        '    "~/Library/Saved Application State/me.peapod.umbilical.savedState",\n'
        '    "~/Library/WebKit/me.peapod.umbilical",\n'
        "  ]\n"
        "end\n"
    )


def _require_true(plist: dict, key: str) -> None:
    if plist.get(key) is not True:
        fail(f"built app does not set {key}")


def _organization_state(raw: object) -> str:
    if not isinstance(raw, str):
        return "absent"
    text = raw.strip()
    if text == "" or "$(" in text:
        return "absent"
    if UUID_RE.fullmatch(text) is None:
        return "invalid"
    return text.lower()


def check_built_app(app: Path, version: str, *, signed: bool) -> None:
    plist_path = app / "Contents" / "Info.plist"
    if not plist_path.is_file():
        fail("built app has no Info.plist")
    plist = load_plist(plist_path)
    if plist_string(plist, "SUFeedURL") != FEED_URL:
        fail("SUFeedURL is not the GitHub Releases appcast")
    if plist_string(plist, "SUPublicEDKey") != PUBLIC_ED_KEY:
        fail("SUPublicEDKey does not match the release feed key")
    _require_true(plist, "SUEnableAutomaticChecks")
    _require_true(plist, "SUVerifyUpdateBeforeExtraction")
    _require_true(plist, "SURequireSignedFeed")
    if plist.get("SUScheduledCheckInterval") != 86400:
        fail("SUScheduledCheckInterval is not 86400")

    state = _organization_state(plist.get("PolarOrganizationID"))
    if signed:
        if VERSION_RE.fullmatch(version) is None:
            fail("version must look like 1.2.3")
        if plist_string(plist, "CFBundleShortVersionString") != version:
            fail("CFBundleShortVersionString does not match the tag")
        if plist_string(plist, "CFBundleVersion") != version:
            fail("CFBundleVersion does not match the tag")
        expected = normalize_organization_id(os.environ.get("POLAR_ORGANIZATION_ID", ""))
        if state != expected:
            fail("PolarOrganizationID does not match POLAR_ORGANIZATION_ID")
        minimum = plist_string(plist, "LSMinimumSystemVersion")
        if not minimum.startswith("14."):
            fail("LSMinimumSystemVersion is not macOS 14")
    elif state != "absent":
        fail("unsigned build contains a Polar organization id")

    required = [
        app / "Contents" / "Frameworks" / "Sparkle.framework",
        app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Autoupdate",
        app
        / "Contents"
        / "Frameworks"
        / "Sparkle.framework"
        / "Versions"
        / "B"
        / "XPCServices"
        / "Downloader.xpc",
        app
        / "Contents"
        / "Frameworks"
        / "Sparkle.framework"
        / "Versions"
        / "B"
        / "XPCServices"
        / "Installer.xpc",
        app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Updater.app",
        app / "Contents" / "Helpers" / "aria2c",
        app / "Contents" / "Helpers" / "yt-dlp",
        app / "Contents" / "Helpers" / "umb-watch",
    ]
    for path in required:
        if not path.exists():
            fail(f"built app is missing {path.name}")
    plugins = list((app / "Contents" / "PlugIns").glob("*.appex"))
    if len(plugins) != 1:
        fail("built app does not contain one Safari extension")


_RFC822_WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_RFC822_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)


def rfc822_now() -> str:
    now = datetime.now(timezone.utc)
    return (
        f"{_RFC822_WEEKDAYS[now.weekday()]}, {now.day:02d} "
        f"{_RFC822_MONTHS[now.month - 1]} {now.year:04d} "
        f"{now.hour:02d}:{now.minute:02d}:{now.second:02d} +0000"
    )


def _cmd_write_licensing(args: argparse.Namespace) -> None:
    raw = os.environ.get("POLAR_ORGANIZATION_ID", "")
    write_licensing_xcconfig(raw, Path(args.dest))


def _cmd_check_sparkle_key(args: argparse.Namespace) -> None:
    check_sparkle_key(Path(args.info_plist))


def _cmd_version_from_tag(args: argparse.Namespace) -> None:
    sys.stdout.write(version_from_tag(args.tag) + "\n")


def _cmd_assert_repo(_args: argparse.Namespace) -> None:
    assert_repo(os.environ.get("GITHUB_REPOSITORY", ""))


def _cmd_render_appcast(args: argparse.Namespace) -> None:
    signature, length_text = parse_signature_line(Path(args.signature_file).read_text(encoding="utf-8"))
    dmg = Path(args.dmg)
    actual = dmg.stat().st_size
    if int(length_text) != actual:
        fail("sign_update length does not match the dmg")
    previous = Path(args.previous) if args.previous else None
    render_appcast(
        version=args.version,
        short_version=args.short_version,
        minimum=args.minimum,
        signature=signature,
        length=actual,
        previous=previous,
        output=Path(args.output),
        pubdate=args.pubdate or rfc822_now(),
    )


def _cmd_render_cask(args: argparse.Namespace) -> None:
    text = render_cask(args.version, args.sha256, draft_header=args.draft_header)
    Path(args.output).write_text(text, encoding="utf-8")


def _cmd_check_built_app(args: argparse.Namespace) -> None:
    check_built_app(Path(args.app), args.version, signed=args.signed)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="umbilical release helpers")
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write-licensing-xcconfig")
    write.add_argument("--dest", required=True)
    write.set_defaults(func=_cmd_write_licensing)

    key = sub.add_parser("check-sparkle-key")
    key.add_argument("--info-plist", required=True)
    key.set_defaults(func=_cmd_check_sparkle_key)

    tag = sub.add_parser("version-from-tag")
    tag.add_argument("--tag", required=True)
    tag.set_defaults(func=_cmd_version_from_tag)

    repo = sub.add_parser("assert-repo")
    repo.set_defaults(func=_cmd_assert_repo)

    appcast = sub.add_parser("render-appcast")
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--short-version", required=True)
    appcast.add_argument("--minimum", required=True)
    appcast.add_argument("--signature-file", required=True)
    appcast.add_argument("--dmg", required=True)
    appcast.add_argument("--previous")
    appcast.add_argument("--output", required=True)
    appcast.add_argument("--pubdate")
    appcast.set_defaults(func=_cmd_render_appcast)

    cask = sub.add_parser("render-cask")
    cask.add_argument("--version", required=True)
    cask.add_argument("--sha256", required=True)
    cask.add_argument("--output", required=True)
    cask.add_argument("--draft-header", action="store_true")
    cask.set_defaults(func=_cmd_render_cask)

    built = sub.add_parser("check-built-app")
    built.add_argument("--app", required=True)
    built.add_argument("--version", default="")
    built.add_argument("--signed", action="store_true")
    built.set_defaults(func=_cmd_check_built_app)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())

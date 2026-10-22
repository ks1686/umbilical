#!/usr/bin/env python3
"""Helpers for the umbilical Mac release script.

These functions do not print private keys. The Sparkle private key and the
App Store Connect API key are read from local files. Callers do not pass
key material through argv or the environment.
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


def repo_from_remote(url: str) -> str:
    text = url.strip().rstrip("/")
    if text.endswith(".git"):
        text = text[:-4]
    if "://" in text:
        text = text.split("://", 1)[1]
        if "@" in text:
            text = text.split("@", 1)[1]
    if text.startswith("git@github.com:"):
        name = text[len("git@github.com:") :]
    elif text.startswith("github.com/"):
        name = text[len("github.com/") :]
    elif text.startswith("github.com:"):
        name = text[len("github.com:") :]
    else:
        fail("origin is not a github.com remote")
    parts = [part for part in name.strip("/").split("/") if part]
    if len(parts) != 2:
        fail("origin is not a github.com remote")
    return f"{parts[0]}/{parts[1]}"


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
        "// Written by the Mac release script. Not an access token.\n"
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
        fail("Sparkle private key is not valid base64")
    if len(raw) == 32:
        public = _public_key_from_seed(raw)
    elif len(raw) == 96:
        public = raw[64:]
    else:
        fail(
            "Sparkle private key must decode to 32 bytes "
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
        fail("Sparkle private key is empty")
    derived = ed25519_public_key(secret)
    if derived != expected_public:
        fail(
            "Sparkle private key does not match SUPublicEDKey "
            f"(derived {derived}, expected {expected_public})"
        )


def assert_private_file(path: Path, label: str) -> None:
    if path.is_symlink():
        fail(f"{label} must not be a symlink")
    if not path.is_file():
        fail(f"{label} is missing")
    mode = path.stat().st_mode & 0o777
    if mode not in (0o600, 0o400):
        fail(f"{label} must be mode 600 or 400")


def read_private_key_file(path: Path) -> str:
    assert_private_file(path, "Sparkle private key file")
    return path.read_text(encoding="utf-8")


def check_sparkle_key(info_plist: Path, key_file: Path) -> None:
    source = load_plist(info_plist)
    expected = plist_string(source, "SUPublicEDKey")
    if expected != PUBLIC_ED_KEY:
        fail("SUPublicEDKey in Info.plist does not match the release feed key")
    assert_private_key_matches(read_private_key_file(key_file), expected)


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
    data = path.read_bytes()
    lowered = data.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        fail("previous appcast contains a doctype or entity")
    try:
        # Our own GitHub release asset. DOCTYPE and ENTITY are rejected above.
        root = ET.fromstring(data)  # nosemgrep: python.lang.security.use-defused-xml-parse.use-defused-xml-parse
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


def release_notes_path(root: Path, version: str) -> Path:
    if VERSION_RE.fullmatch(version) is None:
        fail("version must look like 1.2.3")
    return root / "docs" / "release-notes" / f"{version}.md"


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
    notes: str | None = None,
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
    if notes is not None and notes.strip() != "":
        ET.SubElement(item, "description").text = notes.strip()
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
            "# The Mac release script uploads the same cask with the real version and sha256.\n"
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


_XCCONFIG_ID_RE = re.compile(r"^POLAR_ORGANIZATION_ID\s*=\s*(\S+)\s*$")


def organization_id_from_xcconfig(text: str) -> str | None:
    for line in text.splitlines():
        code = line.split("//", 1)[0].strip()
        if code == "":
            continue
        match = _XCCONFIG_ID_RE.fullmatch(code)
        if match is not None:
            return match.group(1)
    return None


def prepare_licensing(dest: Path) -> str:
    env_value = os.environ.get("POLAR_ORGANIZATION_ID", "")
    if env_value.strip() != "":
        value = normalize_organization_id(env_value)
    elif dest.is_file():
        found = organization_id_from_xcconfig(dest.read_text(encoding="utf-8"))
        if found is None:
            fail("POLAR_ORGANIZATION_ID is empty")
        value = normalize_organization_id(found)
    else:
        fail("POLAR_ORGANIZATION_ID is empty")
    write_licensing_xcconfig(value, dest)
    return value


_DEVELOPER_ID_RE = re.compile(r'"(Developer ID Application:[^"]*)"')
_NOTARY_KEY_ID_RE = re.compile(r"^[A-Za-z0-9]{10}$")


def developer_id_identity(find_identity_text: str) -> str:
    names = _DEVELOPER_ID_RE.findall(find_identity_text)
    if len(names) != 1:
        fail(f"expected one Developer ID Application identity, found {len(names)}")
    return names[0]


def read_single_line(path: Path, label: str) -> str:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} is missing")
    text = path.read_text(encoding="utf-8").strip()
    if text == "" or any(char.isspace() for char in text):
        fail(f"{label} must be one line")
    return text


def _notary_profile(config_dir: Path) -> str:
    profile = os.environ.get("NOTARY_KEYCHAIN_PROFILE", "").strip()
    if profile == "":
        profile_file = config_dir / "keychain-profile"
        if profile_file.is_file():
            profile = read_single_line(profile_file, "notarytool keychain profile")
    if profile == "":
        return ""
    if any(char.isspace() for char in profile) or "/" in profile:
        fail("notarytool keychain profile must be a single token")
    return profile


def _pem_private_key(path: Path) -> None:
    data = path.read_bytes()
    if b"PRIVATE KEY" not in data:
        fail("App Store Connect API key file is not a private key")


def resolve_notary_auth(config_dir: Path) -> list[str]:
    profile = _notary_profile(config_dir)
    if profile != "":
        return ["--keychain-profile", profile]

    override = os.environ.get("NOTARY_KEY_PATH", "").strip()
    key_path = Path(override).expanduser() if override else config_dir / "AuthKey.p8"
    assert_private_file(key_path, "App Store Connect API key file")
    _pem_private_key(key_path)

    key_id = os.environ.get("NOTARY_KEY_ID", "").strip()
    if key_id == "" and (config_dir / "key-id").is_file():
        key_id = read_single_line(config_dir / "key-id", "notary key id")
    issuer = os.environ.get("NOTARY_ISSUER_ID", "").strip()
    if issuer == "" and (config_dir / "issuer-id").is_file():
        issuer = read_single_line(config_dir / "issuer-id", "notary issuer id")
    if key_id == "" or issuer == "":
        fail("notarytool key id or issuer id is empty")
    if _NOTARY_KEY_ID_RE.fullmatch(key_id) is None:
        fail("notarytool key id is not 10 letters or digits")
    if UUID_RE.fullmatch(issuer) is None:
        fail("notarytool issuer id is not a UUID")
    return ["--key", str(key_path), "--key-id", key_id, "--issuer", issuer]


APP_BUNDLE_ID = "me.peapod.umbilical"
APP_TEAM_ID = "7R2VPW8GH4"
APP_ACCESS_GROUP = f"{APP_TEAM_ID}.{APP_BUNDLE_ID}"
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
ACCESS_GROUP_RE = re.compile(rf"^([A-Z0-9]{{10}})\.{re.escape(APP_BUNDLE_ID)}$")


def access_group_for_team(team_id: str) -> str:
    if TEAM_ID_RE.fullmatch(team_id) is None:
        fail("team id must be 10 letters or digits")
    return f"{team_id}.{APP_BUNDLE_ID}"


def require_exact_app_access_group(template: dict) -> str:
    if set(template) != {"keychain-access-groups"}:
        fail("Developer ID entitlements must contain only keychain-access-groups")
    groups = template.get("keychain-access-groups")
    if not isinstance(groups, list) or len(groups) != 1 or not isinstance(groups[0], str):
        fail("Developer ID entitlements must set one keychain access group")
    match = ACCESS_GROUP_RE.fullmatch(groups[0])
    if match is None:
        fail(
            "Developer ID keychain access group must be the team id plus "
            "me.peapod.umbilical"
        )
    return match.group(1)


def require_build_entitlements_omit_keychain(template: dict) -> None:
    if "keychain-access-groups" in template:
        fail("Xcode Release entitlements must not include keychain-access-groups")


def check_keychain_entitlement_files(build: dict, developer: dict) -> str:
    require_build_entitlements_omit_keychain(build)
    team_id = require_exact_app_access_group(developer)
    if team_id != APP_TEAM_ID or developer["keychain-access-groups"] != [APP_ACCESS_GROUP]:
        fail(
            "Developer ID entitlements must set keychain-access-groups to "
            f"{APP_ACCESS_GROUP} only"
        )
    return team_id


def entitlements_for_adhoc(template: dict) -> dict:
    cleaned = copy.deepcopy(template)
    cleaned.pop("keychain-access-groups", None)
    return cleaned


def entitlements_for_developer_id(template: dict, team_id: str) -> dict:
    file_team = require_exact_app_access_group(template)
    if team_id != file_team:
        fail("provisioning profile team id does not match the app keychain access group")
    cleaned = copy.deepcopy(template)
    cleaned["keychain-access-groups"] = [access_group_for_team(team_id)]
    return cleaned


def provisioning_profile_path(env_value: str | None, default: Path) -> Path:
    if env_value is None:
        path = default
    else:
        if (
            env_value == ""
            or env_value == "-"
            or "\n" in env_value
            or "\x00" in env_value
            or len(env_value) > 1024
        ):
            fail("UMBILICAL_PROVISIONING_PROFILE is not a file path")
        path = Path(env_value).expanduser()
    if path.is_symlink() or not path.is_file():
        fail(
            "Developer ID provisioning profile is missing. Save a macOS "
            "Developer ID profile for me.peapod.umbilical with Keychain Sharing at "
            "~/.config/genv/signing/umbilical.provisionprofile"
        )
    return path


def default_provisioning_profile() -> Path:
    default = Path.home() / ".config" / "genv" / "signing" / "umbilical.provisionprofile"
    return provisioning_profile_path(os.environ.get("UMBILICAL_PROVISIONING_PROFILE"), default)


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def validate_developer_id_profile(plist: dict, now: datetime) -> str:
    teams = plist.get("TeamIdentifier")
    if not isinstance(teams, list) or len(teams) != 1 or not isinstance(teams[0], str):
        fail("provisioning profile must name one team id")
    team_id = teams[0]
    wanted = access_group_for_team(team_id)
    if "ProvisionedDevices" in plist:
        fail("provisioning profile is a development profile; use a Developer ID profile")
    entitlements = plist.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail("provisioning profile has no entitlements")
    if entitlements.get("com.apple.application-identifier") != wanted:
        fail("provisioning profile must be for me.peapod.umbilical")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        fail("provisioning profile team id does not match the application identifier")
    groups = entitlements.get("keychain-access-groups")
    allowed = {wanted, f"{team_id}.*"}
    if not isinstance(groups, list) or not any(
        isinstance(item, str) and item in allowed for item in groups
    ):
        fail("provisioning profile does not authorize the app keychain access group")
    expiry = plist.get("ExpirationDate")
    if not isinstance(expiry, datetime):
        fail("provisioning profile has no expiration date")
    if _as_utc(expiry) <= _as_utc(now):
        fail("provisioning profile is expired")
    platform = plist.get("Platform")
    if platform is not None:
        if not isinstance(platform, list) or not any(
            isinstance(item, str) and item in ("OSX", "macOS") for item in platform
        ):
            fail("provisioning profile is not a macOS profile")
    return team_id


def assert_signed_profile_bytes(data: bytes) -> None:
    if len(data) < 16:
        fail("provisioning profile is too small")
    if data.startswith((b"<?xml", b"-----", b"{", b"bplist")):
        fail("provisioning profile must be the signed file, not a decoded plist")
    if b"PRIVATE KEY" in data or b"BEGIN CERTIFICATE" in data:
        fail("provisioning profile is not a signed profile")


def embed_provisioning_profile(source: Path, dest: Path) -> None:
    if source.is_symlink() or not source.is_file():
        fail("provisioning profile is missing")
    data = source.read_bytes()
    assert_signed_profile_bytes(data)
    if dest.is_symlink():
        fail("embedded provisioning profile path is a symlink")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    dest.chmod(0o644)


def write_xml_plist(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_XML)


def load_entitlements_file(path: Path) -> dict:
    data = path.read_bytes()
    if data.strip() == b"":
        return {}
    try:
        loaded = plistlib.loads(data)
    except plistlib.InvalidFileException:
        fail("signed entitlements are not a plist")
    if not isinstance(loaded, dict):
        fail("signed entitlements are not a plist")
    return loaded


def assert_signed_keychain_entitlement(
    entitlements: dict, *, label: str, team_id: str | None
) -> None:
    if team_id is None:
        if "keychain-access-groups" in entitlements:
            fail(f"{label} must not include keychain-access-groups")
        return
    wanted = access_group_for_team(team_id)
    if entitlements.get("keychain-access-groups") != [wanted]:
        fail(f"{label} keychain-access-groups must be only the app team id and bundle id")


def _cmd_write_licensing(args: argparse.Namespace) -> None:
    sys.stdout.write(prepare_licensing(Path(args.dest)) + "\n")


def _cmd_check_sparkle_key(args: argparse.Namespace) -> None:
    check_sparkle_key(Path(args.info_plist), Path(args.key_file))


def _cmd_version_from_tag(args: argparse.Namespace) -> None:
    sys.stdout.write(version_from_tag(args.tag) + "\n")


def _cmd_signing_identity(args: argparse.Namespace) -> None:
    text = Path(args.from_file).read_text(encoding="utf-8", errors="replace")
    sys.stdout.write(developer_id_identity(text) + "\n")


def _cmd_resolve_notary(args: argparse.Namespace) -> None:
    if args.config_dir:
        config_dir = Path(args.config_dir).expanduser()
    else:
        config_dir = Path.home() / ".config" / "genv" / "notarize"
    for item in resolve_notary_auth(config_dir):
        if item == "" or "\n" in item:
            fail("notarytool argument is empty")
        sys.stdout.write(item + "\n")


def _cmd_assert_repo(args: argparse.Namespace) -> None:
    if args.remote:
        assert_repo(repo_from_remote(args.remote))
        return
    assert_repo(os.environ.get("GITHUB_REPOSITORY", ""))


def _cmd_render_appcast(args: argparse.Namespace) -> None:
    signature, length_text = parse_signature_line(Path(args.signature_file).read_text(encoding="utf-8"))
    dmg = Path(args.dmg)
    actual = dmg.stat().st_size
    if int(length_text) != actual:
        fail("sign_update length does not match the dmg")
    previous = Path(args.previous) if args.previous else None
    notes = None
    if args.notes_file:
        notes = Path(args.notes_file).read_text(encoding="utf-8")
    render_appcast(
        version=args.version,
        short_version=args.short_version,
        minimum=args.minimum,
        signature=signature,
        length=actual,
        previous=previous,
        output=Path(args.output),
        pubdate=args.pubdate or rfc822_now(),
        notes=notes,
    )


def _cmd_render_cask(args: argparse.Namespace) -> None:
    text = render_cask(args.version, args.sha256, draft_header=args.draft_header)
    Path(args.output).write_text(text, encoding="utf-8")


def _cmd_check_built_app(args: argparse.Namespace) -> None:
    check_built_app(Path(args.app), args.version, signed=args.signed)


def _cmd_resolve_provisioning_profile(_args: argparse.Namespace) -> None:
    sys.stdout.write(str(default_provisioning_profile()) + "\n")


def _cmd_check_keychain_entitlement_files(args: argparse.Namespace) -> None:
    build = load_plist(Path(args.build))
    developer = load_plist(Path(args.developer_id))
    check_keychain_entitlement_files(build, developer)


def _cmd_write_adhoc_app_entitlements(args: argparse.Namespace) -> None:
    template = load_plist(Path(args.template))
    write_xml_plist(Path(args.output), entitlements_for_adhoc(template))


def _cmd_write_developer_id_app_entitlements(args: argparse.Namespace) -> None:
    template = load_plist(Path(args.template))
    decoded = load_plist(Path(args.profile_plist))
    team = validate_developer_id_profile(decoded, datetime.now(timezone.utc))
    write_xml_plist(Path(args.output), entitlements_for_developer_id(template, team))
    embed_provisioning_profile(Path(args.profile), Path(args.embed))
    Path(args.team_output).write_text(team + "\n", encoding="utf-8")


def _cmd_check_signed_keychain_entitlement(args: argparse.Namespace) -> None:
    entitlements = load_entitlements_file(Path(args.plist))
    team = None if args.absent else args.team
    if team == "":
        fail("team id is empty")
    assert_signed_keychain_entitlement(entitlements, label=args.label, team_id=team)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="umbilical release helpers")
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write-licensing-xcconfig")
    write.add_argument("--dest", required=True)
    write.set_defaults(func=_cmd_write_licensing)

    key = sub.add_parser("check-sparkle-key")
    key.add_argument("--info-plist", required=True)
    key.add_argument("--key-file", required=True)
    key.set_defaults(func=_cmd_check_sparkle_key)

    tag = sub.add_parser("version-from-tag")
    tag.add_argument("--tag", required=True)
    tag.set_defaults(func=_cmd_version_from_tag)

    identity = sub.add_parser("signing-identity")
    identity.add_argument("--from-file", required=True)
    identity.set_defaults(func=_cmd_signing_identity)

    notary = sub.add_parser("resolve-notary")
    notary.add_argument("--config-dir")
    notary.set_defaults(func=_cmd_resolve_notary)

    repo = sub.add_parser("assert-repo")
    repo.add_argument("--remote")
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
    appcast.add_argument("--notes-file")
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

    profile = sub.add_parser("resolve-provisioning-profile")
    profile.set_defaults(func=_cmd_resolve_provisioning_profile)

    entitlement_files = sub.add_parser("check-keychain-entitlement-files")
    entitlement_files.add_argument("--build", required=True)
    entitlement_files.add_argument("--developer-id", required=True)
    entitlement_files.set_defaults(func=_cmd_check_keychain_entitlement_files)

    adhoc = sub.add_parser("write-adhoc-app-entitlements")
    adhoc.add_argument("--template", required=True)
    adhoc.add_argument("--output", required=True)
    adhoc.set_defaults(func=_cmd_write_adhoc_app_entitlements)

    developer = sub.add_parser("write-developer-id-app-entitlements")
    developer.add_argument("--template", required=True)
    developer.add_argument("--profile-plist", required=True)
    developer.add_argument("--profile", required=True)
    developer.add_argument("--output", required=True)
    developer.add_argument("--embed", required=True)
    developer.add_argument("--team-output", required=True)
    developer.set_defaults(func=_cmd_write_developer_id_app_entitlements)

    signed_ents = sub.add_parser("check-signed-keychain-entitlement")
    signed_ents.add_argument("--plist", required=True)
    signed_ents.add_argument("--label", required=True)
    signed_ents.add_argument("--team")
    signed_ents.add_argument("--absent", action="store_true")
    signed_ents.set_defaults(func=_cmd_check_signed_keychain_entitlement)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())

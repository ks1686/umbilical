#!/usr/bin/env python3
"""Fail if the Semgrep lock pins a known-vulnerable version again.

Also checks that .github/dependabot.yml keeps GitHub Actions updates
enabled and ignores pip in /requirements. Dependabot cannot resolve
the locally rebuilt semgrep wheel, so those bumps stay manual.

Usage:
  python3 scripts/ci/assert-semgrep-lock.py
  python3 scripts/ci/assert-semgrep-lock.py --installed
  python3 scripts/ci/assert-semgrep-lock.py --self-test
"""

from __future__ import annotations

import argparse
import importlib.metadata
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "requirements" / "semgrep.txt"
DEPENDABOT = ROOT / ".github" / "dependabot.yml"

# Floors that close the open (and previously open) Semgrep-lock advisories.
FLOORS = {
    "mcp": (1, 30, 0),
    "opentelemetry-api": (1, 45, 2),
    "wcmatch": (11, 2, 0),
}

PIN_RE = re.compile(r"^([A-Za-z0-9_.-]+)==(\S+)")


def normalize_name(name: str) -> str:
    return name.lower().replace("_", "-")


def release_tuple(version: str) -> tuple[int, ...]:
    release = re.split(r"[^\d.]", version, maxsplit=1)[0]
    parts = tuple(int(part) for part in release.split(".") if part)
    if not parts:
        raise ValueError(f"cannot parse version {version!r}")
    return parts


def cmp_tuples(left: tuple[int, ...], right: tuple[int, ...]) -> int:
    width = max(len(left), len(right))
    padded_left = left + (0,) * (width - len(left))
    padded_right = right + (0,) * (width - len(right))
    if padded_left < padded_right:
        return -1
    if padded_left > padded_right:
        return 1
    return 0


def parse_lock(text: str) -> dict[str, str]:
    pins: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", "--")):
            continue
        match = PIN_RE.match(line)
        if not match:
            continue
        pins[normalize_name(match.group(1))] = match.group(2).rstrip("\\").strip()
    return pins


def check_pins(pins: dict[str, str], source: str) -> None:
    missing = [name for name in FLOORS if name not in pins]
    if missing:
        raise SystemExit(f"{source} is missing pins: {', '.join(missing)}")
    problems: list[str] = []
    for name, floor in FLOORS.items():
        current = pins[name]
        if cmp_tuples(release_tuple(current), floor) < 0:
            pretty = ".".join(str(part) for part in floor)
            problems.append(f"{name}=={current} is below {pretty}")
    if problems:
        raise SystemExit(f"{source} has vulnerable pins: {'; '.join(problems)}")


def _strip_yaml_comment(line: str) -> str:
    in_quote = False
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if in_quote:
            if char == "\\":
                escaped = True
                continue
            if char == quote:
                in_quote = False
            continue
        if char in "'\"":
            in_quote = True
            quote = char
            continue
        if char == "#":
            return line[:index].rstrip()
    return line.rstrip()


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse_dependabot(text: str) -> dict[str, object]:
    version: int | None = None
    updates: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    in_updates = False
    in_ignore = False
    for raw in text.splitlines():
        line = _strip_yaml_comment(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if indent == 0 and stripped.startswith("version:"):
            version = int(stripped.split(":", 1)[1].strip())
            in_updates = False
            current = None
            in_ignore = False
            continue
        if indent == 0 and stripped == "updates:":
            in_updates = True
            current = None
            in_ignore = False
            continue
        if not in_updates:
            continue
        if indent == 2 and stripped.startswith("- "):
            current = {}
            updates.append(current)
            in_ignore = False
            stripped = stripped[2:].strip()
        if current is None:
            continue
        if indent == 4 and stripped == "ignore:":
            current["ignore"] = []
            in_ignore = True
            continue
        if in_ignore and indent == 6 and stripped.startswith("- "):
            body = stripped[2:].strip()
            if body.startswith("dependency-name:"):
                name = _unquote(body.split(":", 1)[1].strip())
                ignores = current.setdefault("ignore", [])
                if isinstance(ignores, list):
                    ignores.append(name)
            continue
        if in_ignore and indent <= 4 and not stripped.startswith("- "):
            in_ignore = False
        if ":" in stripped and not stripped.startswith("- "):
            key, value = stripped.split(":", 1)
            current[key.strip()] = _unquote(value.strip()) if value.strip() else current.get(key.strip())
    if version is None:
        raise SystemExit("dependabot.yml is missing version")
    return {"version": version, "updates": updates}


def check_dependabot(text: str, source: str) -> None:
    parsed = parse_dependabot(text)
    if parsed["version"] != 2:
        raise SystemExit(f"{source} must set version: 2")
    updates = parsed["updates"]
    if not isinstance(updates, list):
        raise SystemExit(f"{source} has no updates list")
    actions = None
    pip = None
    for update in updates:
        if not isinstance(update, dict):
            continue
        ecosystem = update.get("package-ecosystem")
        if ecosystem == "github-actions":
            actions = update
        elif ecosystem == "pip":
            pip = update
    if actions is None or actions.get("directory") != "/":
        raise SystemExit(f"{source} must configure github-actions at /")
    if pip is None or pip.get("directory") != "/requirements":
        raise SystemExit(f"{source} must configure pip at /requirements")
    ignores = pip.get("ignore")
    if not isinstance(ignores, list) or "*" not in ignores:
        raise SystemExit(f"{source} must ignore all pip packages in /requirements")
    if str(pip.get("open-pull-requests-limit")) != "0":
        raise SystemExit(f"{source} must set open-pull-requests-limit: 0 for pip")


def check_installed() -> None:
    pins = {
        name: importlib.metadata.version(name)
        for name in FLOORS
    }
    check_pins(pins, "installed environment")


def self_test() -> None:
    vulnerable = """
opentelemetry-api==1.45.1 \\
    --hash=sha256:00
wcmatch==8.5.2 \\
    --hash=sha256:01
mcp==1.30.0 \\
    --hash=sha256:02
"""
    pins = parse_lock(vulnerable)
    if pins != {
        "opentelemetry-api": "1.45.1",
        "wcmatch": "8.5.2",
        "mcp": "1.30.0",
    }:
        raise SystemExit(f"self-test parse_lock failed: {pins}")
    try:
        check_pins(pins, "fixture")
    except SystemExit as exc:
        message = str(exc)
        if "opentelemetry-api==1.45.1" not in message or "wcmatch==8.5.2" not in message:
            raise SystemExit(f"self-test missed a vulnerable pin: {message}") from exc
        if "mcp" in message:
            raise SystemExit(f"self-test flagged a safe mcp pin: {message}") from exc
    else:
        raise SystemExit("self-test expected check_pins to fail on 1.45.1 and 8.5.2")

    safe = parse_lock(
        "opentelemetry-api==1.45.2\nwcmatch==11.2\nmcp==1.30.0\n"
    )
    check_pins(safe, "fixture")

    good = """
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
  - package-ecosystem: "pip"
    directory: "/requirements"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
    open-pull-requests-limit: 0
    ignore:
      - dependency-name: "*"
"""
    check_dependabot(good, "fixture")

    try:
        check_dependabot(
            """
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
""",
            "fixture",
        )
    except SystemExit as exc:
        if "pip at /requirements" not in str(exc):
            raise SystemExit(f"self-test missed missing pip config: {exc}") from exc
    else:
        raise SystemExit("self-test expected dependabot check to fail without pip")

    try:
        check_dependabot(
            """
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
  - package-ecosystem: "pip"
    directory: "/requirements"
    open-pull-requests-limit: 0
    ignore:
      - dependency-name: "semgrep"
""",
            "fixture",
        )
    except SystemExit as exc:
        if "ignore all pip packages" not in str(exc):
            raise SystemExit(f"self-test missed narrow ignore: {exc}") from exc
    else:
        raise SystemExit("self-test expected dependabot check to require ignore *")

    print("assert-semgrep-lock self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--installed", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        if not args.installed and not LOCK.exists():
            return
    if not LOCK.is_file():
        raise SystemExit(f"missing lock file {LOCK}")
    if not DEPENDABOT.is_file():
        raise SystemExit(f"missing {DEPENDABOT}")
    check_pins(parse_lock(LOCK.read_text()), str(LOCK.relative_to(ROOT)))
    check_dependabot(DEPENDABOT.read_text(), str(DEPENDABOT.relative_to(ROOT)))
    if args.installed:
        check_installed()
    print("assert-semgrep-lock: ok")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"assert-semgrep-lock: {exc}", file=sys.stderr)
        raise

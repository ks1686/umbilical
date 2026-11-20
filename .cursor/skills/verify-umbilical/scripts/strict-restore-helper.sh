#!/bin/bash
# Strict Linux proof for scripts/restore-handler.swift.
# The stand-in, the exit codes, the hard limit, and the leftover check live here.
# Run from any directory. This script re-execs into a private /tmp.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${UMB_INSIDE_PRIVATE_TMP:-}" != "1" ]]; then
  if [[ -n "${SWIFTC:-}" ]]; then
    swiftc_path="$SWIFTC"
  elif [[ -x /opt/swift-6.2.1/usr/bin/swiftc ]]; then
    swiftc_path="/opt/swift-6.2.1/usr/bin/swiftc"
  elif [[ -x /opt/swift/usr/bin/swiftc ]]; then
    swiftc_path="/opt/swift/usr/bin/swiftc"
  else
    echo "FAIL: swiftc 6.2.1 is not installed" >&2
    exit 1
  fi
  # swiftc is a symlink to swift-driver. The driver reads argv[0], so keep the swiftc name.
  case "$swiftc_path" in
    /*) ;;
    *) swiftc_path="$(cd "$(dirname "$swiftc_path")" && pwd)/$(basename "$swiftc_path")" ;;
  esac
  exec "$SCRIPT_DIR/enter-private-tmp.sh" "$(readlink -f /proc/$$/exe)" "$0" "$swiftc_path"
fi

if [[ "$#" -ne 1 ]]; then
  echo "usage: strict-restore-helper.sh SWIFTC" >&2
  exit 2
fi

SWIFTC="$1"
SRC="$SCRIPT_DIR/restore-handler.swift"
STANDIN="$SCRIPT_DIR/AppKitStandIn.swift"
REPO_ROOT="$SCRIPT_DIR"
while [[ "$REPO_ROOT" != "/" && ! -f "$REPO_ROOT/.github/workflows/ci.yml" ]]; do
  REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
done
CI="$REPO_ROOT/.github/workflows/ci.yml"
PASSES=0
WORK=""
SHIP_HASH=""

fail() {
  echo "FAIL: $*" >&2
  echo "FAIL: $*"
  exit 1
}

pass() {
  PASSES=$((PASSES + 1))
  echo "PASS: $*"
}

process_lstart() {
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

stop_recorded() {
  local pid="$1"
  local mark="$2"
  local now attempt
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && -n "$mark" ]] || return 0
  now="$(process_lstart "$pid" || true)"
  [[ "$now" == "$mark" ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  attempt=0
  while [[ "$attempt" -lt 5 ]]; do
    now="$(process_lstart "$pid" || true)"
    [[ "$now" == "$mark" ]] || return 0
    sleep 0.2
    attempt=$((attempt + 1))
  done
  now="$(process_lstart "$pid" || true)"
  [[ "$now" == "$mark" ]] || return 0
  kill -KILL "$pid" 2>/dev/null || true
}

remember() {
  local pid="$1"
  local mark="$2"
  [[ -n "${WORK:-}" && -n "$pid" ]] || return 0
  mkdir -p "$WORK/children"
  printf '%s\n' "$mark" >"$WORK/children/$pid"
}

forget() {
  local pid="$1"
  [[ -n "${WORK:-}" && -n "$pid" ]] || return 0
  rm -f "$WORK/children/$pid"
}

stop_remembered() {
  local entry pid mark
  [[ -n "${WORK:-}" && -d "$WORK/children" ]] || return 0
  for entry in "$WORK"/children/*; do
    [[ -f "$entry" ]] || continue
    pid="$(basename "$entry")"
    mark="$(cat "$entry")"
    # Bash 3.2 prints "Terminated" unless the kill and the wait share a redirect.
    {
      stop_recorded "$pid" "$mark"
      wait "$pid" 2>/dev/null || true
    } 2>/dev/null
  done
}

offenders() {
  local pid comm exe
  [[ -n "${WORK:-}" ]] || return 0
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" -eq "$$" ]] && continue
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    case "$comm" in
      sleep | aria2c | umbilical | restore-handler)
        echo "$pid $comm"
        continue
        ;;
    esac
    case "$exe" in
      "$WORK"/*)
        echo "$pid $exe"
        ;;
    esac
  done
}

run_bounded() {
  local seconds="$1"
  shift
  local child="" mark="" now="" started attempt result=0 saved
  [[ "$seconds" =~ ^[0-9]+$ ]] || return 2
  saved="$-"
  set +m
  "$@" &
  child="$!"
  attempt=0
  while [[ "$attempt" -lt 5 ]]; do
    mark="$(process_lstart "$child" || true)"
    [[ -n "$mark" ]] && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  remember "$child" "$mark"
  started="$(date +%s)"
  while kill -0 "$child" 2>/dev/null; do
    now="$(date +%s)"
    if [[ $((now - started)) -ge "$seconds" ]]; then
      if [[ -z "$mark" ]]; then
        mark="$(process_lstart "$child" || true)"
        remember "$child" "$mark"
      fi
      if [[ -z "$mark" ]]; then
        result=125
      else
        stop_recorded "$child" "$mark"
        {
          wait "$child" || true
        } 2>/dev/null
        result=124
      fi
      break
    fi
    sleep 0.2
  done
  if [[ "$result" -eq 0 ]]; then
    wait "$child" || result=$?
  fi
  forget "$child"
  case "$saved" in
    *m*) set -m ;;
  esac
  return "$result"
}

cleanup() {
  local status=$?
  local found="" outside=""
  stop_remembered || true
  if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
    found="$(offenders || true)"
    if [[ -n "$found" ]]; then
      echo "FAIL: leftover process: $found" >&2
      status=1
    fi
    if [[ -n "${SHIP_HASH:-}" && -f "$SRC" ]]; then
      if [[ "$(sha256sum "$SRC" | awk '{ print $1 }')" != "$SHIP_HASH" ]]; then
        echo "FAIL: shipped restore helper changed during the test" >&2
        status=1
      fi
    fi
    outside="$(python3 - "$WORK/fs-before.txt" "$WORK/library-before.txt" "$WORK" <<'PY' || true
import os, sys
before_path, library_before_path, work = sys.argv[1:]
work = os.path.realpath(work)
extra = []
if os.path.isfile(before_path):
    before = set(open(before_path, encoding="utf-8").read().splitlines())
    after = []
    for root in ("/private/tmp", "/var/tmp"):
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            after.append(dirpath)
            for name in filenames:
                after.append(os.path.join(dirpath, name))
    for path in after:
        real = os.path.realpath(path)
        if real == work or real.startswith(work + os.sep):
            continue
        if path in before or real in before:
            continue
        extra.append(path)
home = os.environ.get("HOME", "")
library = os.path.join(home, "Library") if home else ""
before_library = set()
if os.path.isfile(library_before_path):
    before_library = set(open(library_before_path, encoding="utf-8").read().splitlines())
after_library = []
if library and os.path.isdir(library):
    for dirpath, dirnames, filenames in os.walk(library):
        after_library.append(dirpath)
        for name in filenames:
            after_library.append(os.path.join(dirpath, name))
for path in after_library:
    if path not in before_library:
        extra.append(path)
if extra:
    sys.stdout.write("\n".join(extra[:20]))
PY
)"
    if [[ -n "$outside" ]]; then
      echo "FAIL: write outside the run directory: $outside" >&2
      status=1
    fi
    case "$WORK" in
      /tmp/umb-strict.* | /private/tmp/umb-strict.*)
        rm -rf "$WORK"
        ;;
    esac
  fi
  exit "$status"
}
trap cleanup EXIT

[[ -x "$SWIFTC" ]] || fail "swiftc is missing at $SWIFTC"
version="$("$SWIFTC" --version)"
printf '%s\n' "$version" | grep -F 'Swift version 6.2.1' >/dev/null || fail "toolchain is not Swift 6.2.1: $version"
pass "swiftc is Swift 6.2.1"

[[ "$(readlink -f /tmp)" == "/private/tmp" ]] || fail "/tmp does not resolve to /private/tmp"
[[ -L /tmp ]] || fail "/tmp is not a symlink"
pass "/tmp is a symlink to /private/tmp"

python3 - "$0" <<'PY' || fail "shell harness is not bash 3.2 safe"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
words = ["map" + "file", "read" + "array", "pk" + "ill", "kill" + "all"]
for word in words:
    for lineno, line in enumerate(text.splitlines(), 1):
        if word in line:
            raise SystemExit("%s on line %s" % (word, lineno))
if re.search(r"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}", text):
    raise SystemExit("empty array expansion")
if re.search(r"(?m)^[^#\n]*\bdeclare\s+-A\b", text):
    raise SystemExit("associative array")
PY
pass "harness stays compatible with bash 3.2 under set -u"

[[ -f "$SRC" ]] || fail "restore helper is missing"
SHIP_HASH="$(sha256sum "$SRC" | awk '{ print $1 }')"
grep -q 'addingTimeInterval(60)' "$SRC" || fail "shipped deadline is not 60 seconds"
if grep -q 'addingTimeInterval(1)' "$SRC"; then
  fail "shipped helper contains a shortened deadline"
fi
if grep -q 'RunLoop.main.run()' "$SRC"; then
  fail "shipped helper uses the unbounded run loop"
fi
grep -q 'while !box.finished && Date() < deadline' "$SRC" || fail "shipped helper does not poll the run loop"
pass "shipped helper still defaults to 60 seconds and polls the run loop"

python3 - "$CI" <<'PY' || fail "Linux CI does not run this test"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
chunks = re.split(r"(?m)^(?=  [a-z0-9-]+:\n)", text)
engine = [chunk for chunk in chunks if chunk.startswith("  engine:\n")]
if len(engine) != 1:
    raise SystemExit("expected one engine job")
job = engine[0]
if "runs-on: ubuntu-24.04" not in job:
    raise SystemExit("engine job is not the Linux runner")
if "strict-restore-helper.sh" not in job:
    raise SystemExit("engine job does not run the strict helper test")
if "swift-6.2.1-RELEASE-ubuntu24.04.tar.gz" not in job:
    raise SystemExit("engine job does not install Swift 6.2.1")
if not re.search(r"[0-9a-f]{64}\s+/tmp/swift-6\.2\.1\.tar\.gz", job):
    raise SystemExit("Swift 6.2.1 checksum is not pinned")
index = job.find("strict-restore-helper.sh")
window = job[max(0, index - 400):index + 80]
if re.search(r"(?m)^\s+if:", window):
    raise SystemExit("helper test step is conditional")
if "continue-on-error" in window:
    raise SystemExit("helper test step ignores failure")
PY
pass "Linux CI job runs this test on Swift 6.2.1 and does not skip it"

[[ -f "$STANDIN" ]] || fail "AppKit stand-in is missing"
python3 - "$STANDIN" <<'PY' || fail "stand-in is not the real NSWorkspace surface"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
if text.count("#if !canImport(AppKit)") != 1:
    raise SystemExit("stand-in must be compiled only when AppKit is absent")
if "setDefaultApplicationAtURL" in text:
    raise SystemExit("stand-in mentions the error selector")
lines = text.splitlines()
depth = 0
decls = []

def line_depth(line, depth):
    start = depth
    i = 0
    while i < len(line):
        if line.startswith("//", i):
            break
        char = line[i]
        if char in ("'", '"'):
            quote = char
            i += 1
            while i < len(line):
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        i += 1
    return start, depth

for raw in lines:
    start, depth = line_depth(raw, depth)
    stripped = raw.strip()
    if start > 1 or not stripped or stripped.startswith("//"):
        continue
    if stripped.startswith("public ") or stripped.startswith("func ") or stripped.startswith("class ") or stripped.startswith("var ") or stripped.startswith("let "):
        decls.append(stripped)

expected = [
    "public final class NSWorkspace {",
    "public class var shared: NSWorkspace {",
    "public func setDefaultApplication(",
]
if decls != expected:
    raise SystemExit("exposed members %s" % decls)
urls = {
    "public final class NSWorkspace {": "https://developer.apple.com/documentation/appkit/nsworkspace",
    "public class var shared: NSWorkspace {": "https://developer.apple.com/documentation/appkit/nsworkspace/shared",
    "public func setDefaultApplication(": "https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)",
}
for index, raw in enumerate(lines):
    stripped = raw.strip()
    if stripped not in urls:
        continue
    previous = ""
    cursor = index - 1
    while cursor >= 0:
        previous = lines[cursor].strip()
        if previous:
            break
        cursor -= 1
    if previous != "// " + urls[stripped]:
        raise SystemExit("missing Apple doc for %s" % stripped)
func = text.split("public func setDefaultApplication(", 1)[1].split("{", 1)[0]
for token in (
    "at applicationURL: URL",
    "toOpenURLsWithScheme urlScheme: String",
    "completion completionHandler:",
    "(Error?) -> Void",
):
    if token not in func:
        raise SystemExit("signature missing %s" % token)
if not text.rstrip().endswith("#endif"):
    raise SystemExit("stand-in guard does not close the file")
PY
pass "stand-in exposes only the real NSWorkspace members and cites Apple docs"

command -v python3 >/dev/null 2>&1 || fail "python3 is missing"
fs_before="$(mktemp /tmp/umb-strict-before.XXXXXX)"
find /private/tmp /var/tmp -print | sort >"$fs_before"
WORK="$(mktemp -d /tmp/umb-strict.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in
  /private/tmp/umb-strict.*) ;;
  *) fail "unexpected work directory $WORK" ;;
esac
mv "$fs_before" "$WORK/fs-before.txt"
if [[ -n "${HOME:-}" && -d "$HOME/Library" ]]; then
  find "$HOME/Library" -print | sort >"$WORK/library-before.txt"
else
  : >"$WORK/library-before.txt"
fi
mkdir -p "$WORK/tmp" "$WORK/cache" "$WORK/home"
export TMPDIR="$WORK/tmp"
export CLANG_MODULE_CACHE_PATH="$WORK/cache"
export SWIFT_MODULECACHE_PATH="$WORK/cache"
export HOME="${HOME:-}"

compile_to() {
  local out="$1"
  shift
  local status=0
  set +e
  TMPDIR="$WORK/tmp" CLANG_MODULE_CACHE_PATH="$WORK/cache" SWIFT_MODULECACHE_PATH="$WORK/cache" \
    run_bounded 60 "$SWIFTC" -module-cache-path "$WORK/cache" "$@" -o "$out" >"$WORK/compile.out" 2>"$WORK/compile.err"
  status=$?
  set -e
  printf '%s\n' "$status"
}

mkdir -p "$WORK/plant-src" "$WORK/planted-src" "$WORK/hidden-src" "$WORK/ok-src" "$WORK/deadline-src" "$WORK/unbounded-src"
cat >"$WORK/plant-src/main.swift" <<'EOF'
import Foundation
func plant() {
    let missing = NSWorkspace.setDefaultApplicationAtURL(_:toOpenURLsWithScheme:error:) // setDefaultApplicationAtURL:toOpenURLsWithScheme:error:
    _ = missing
}
plant()
EOF
cp "$WORK/plant-src/main.swift" "$WORK/planted-src/main.swift"
plant_status="$(compile_to "$WORK/plant" "$STANDIN" "$WORK/plant-src/main.swift")"
[[ "$plant_status" -ne 0 ]] || fail "nonexistent error selector compiled"
grep -F 'setDefaultApplicationAtURL:toOpenURLsWithScheme:error:' "$WORK/compile.err" >/dev/null || fail "compile error did not name the selector: $(cat "$WORK/compile.err")"
grep -E 'no member|cannot find' "$WORK/compile.err" >/dev/null || fail "compile error was not a missing member: $(cat "$WORK/compile.err")"
pass "a planted error selector fails the build and the error names it"

python3 - "$STANDIN" "$WORK/standin-with-error.swift" <<'PY' || fail "could not plant the error selector into a copy"
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
needle = "    public func setDefaultApplication("
insert = (
    "    public func setDefaultApplicationAtURL(_ applicationURL: URL, toOpenURLsWithScheme urlScheme: String, error: Error?) {\n"
    "    }\n"
)
if needle not in text:
    raise SystemExit("missing method")
pathlib.Path(dest).write_text(text.replace(needle, insert + needle, 1))
PY
planted_status="$(compile_to "$WORK/planted" "$WORK/standin-with-error.swift" "$WORK/planted-src/main.swift")"
[[ "$planted_status" -eq 0 ]] || fail "adding the error selector still failed to compile: $(cat "$WORK/compile.err")"
pass "putting the error selector back makes the planted call compile"

python3 - "$STANDIN" "$WORK/standin-hidden.swift" <<'PY' || fail "could not invert the AppKit guard"
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
old = "#if !canImport(AppKit)"
if old not in text:
    raise SystemExit("missing guard")
pathlib.Path(dest).write_text(text.replace(old, "#if canImport(AppKit)", 1))
PY
cat >"$WORK/hidden-src/main.swift" <<'EOF'
import Foundation
func plant() {
    _ = NSWorkspace.shared
}
plant()
EOF
hidden_status="$(compile_to "$WORK/hidden" "$WORK/standin-hidden.swift" "$WORK/hidden-src/main.swift")"
[[ "$hidden_status" -ne 0 ]] || fail "stand-in stayed visible when AppKit can be imported"
grep -F 'NSWorkspace' "$WORK/compile.err" >/dev/null || fail "hidden stand-in error did not mention NSWorkspace: $(cat "$WORK/compile.err")"
pass "the stand-in is compiled only when AppKit cannot be imported"

# Linux has no AppKit module. This copy drops that one import so the stand-in
# supplies NSWorkspace. The shipped helper is not edited.
python3 - "$SRC" "$WORK/ok-src/main.swift" <<'PY' || fail "could not prepare the Linux helper copy"
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
needle = "import AppKit\n"
if text.count(needle) != 1:
    raise SystemExit("shipped helper no longer imports AppKit")
pathlib.Path(dest).write_text(text.replace(needle, "", 1))
PY
ok_status="$(compile_to "$WORK/restore-handler" "$STANDIN" "$WORK/ok-src/main.swift")"
[[ "$ok_status" -eq 0 && -x "$WORK/restore-handler" ]] || fail "helper failed to compile: $(cat "$WORK/compile.err")"
grep -q 'import AppKit' "$SRC" || fail "shipped helper lost its AppKit import"
pass "shipped helper compiles with the stand-in"

app_path="$WORK/Umbilical.app"
mkdir -p "$app_path"
run_helper() {
  local mode="$1"
  local limit="$2"
  local status=0
  : >"$WORK/helper.out"
  : >"$WORK/helper.err"
  set +e
  UMB_RESTORE_STANDIN="$mode" \
    run_bounded "$limit" "$WORK/restore-handler" "$app_path" umbilical >"$WORK/helper.out" 2>"$WORK/helper.err"
  status=$?
  set -e
  printf '%s\n' "$status"
}

started="$(date +%s)"
status="$(run_helper ok 10)"
ended="$(date +%s)"
[[ "$status" -eq 0 ]] || fail "completed restore exited $status, stderr [$(cat "$WORK/helper.err")]"
[[ $((ended - started)) -lt 10 ]] || fail "completed restore took $((ended - started))s"
pass "completed restore exits 0"

status="$(run_helper error 10)"
[[ "$status" -eq 1 ]] || fail "workspace error exited $status, stderr [$(cat "$WORK/helper.err")]"
grep -F 'workspace refused the handler' "$WORK/helper.err" >/dev/null || fail "workspace error text missing [$(cat "$WORK/helper.err")]"
pass "workspace error exits 1"

python3 - "$SRC" "$WORK/deadline-src/main.swift" <<'PY' || fail "could not build the deadline override"
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
needle = "import AppKit\n"
old = "addingTimeInterval(60)"
if text.count(needle) != 1 or text.count(old) != 1:
    raise SystemExit("expected one AppKit import and one 60 second deadline")
text = text.replace(needle, "", 1).replace(old, "addingTimeInterval(2)", 1)
pathlib.Path(dest).write_text(text)
PY
deadline_status="$(compile_to "$WORK/restore-deadline" "$STANDIN" "$WORK/deadline-src/main.swift")"
[[ "$deadline_status" -eq 0 ]] || fail "deadline override failed to compile: $(cat "$WORK/compile.err")"
if grep -q 'addingTimeInterval(2)' "$SRC"; then
  fail "deadline override was written into the shipped helper"
fi
started="$(date +%s)"
set +e
UMB_RESTORE_STANDIN=hang \
  run_bounded 8 "$WORK/restore-deadline" "$app_path" umbilical >"$WORK/helper.out" 2>"$WORK/helper.err"
status=$?
set -e
ended="$(date +%s)"
[[ "$status" -eq 1 ]] || fail "missed deadline exited $status, stderr [$(cat "$WORK/helper.err")]"
grep -F 'handler restore timed out waiting for NSWorkspace' "$WORK/helper.err" >/dev/null || fail "deadline message missing [$(cat "$WORK/helper.err")]"
[[ $((ended - started)) -ge 1 && $((ended - started)) -lt 8 ]] || fail "deadline elapsed $((ended - started))s"
grep -q 'addingTimeInterval(60)' "$SRC" || fail "shipped deadline changed"
pass "a test-only shortened deadline exits 1 and the shipped default stays 60 seconds"

python3 - "$SRC" "$WORK/unbounded-src/main.swift" <<'PY' || fail "could not plant the unbounded run loop"
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
needle = "import AppKit\n"
if text.count(needle) != 1:
    raise SystemExit("shipped helper no longer imports AppKit")
text = text.replace(needle, "", 1)
start = text.find("while !box.finished && Date() < deadline {")
if start < 0:
    raise SystemExit("missing poll")
end = text.find("\n}", start)
if end < 0:
    raise SystemExit("missing poll end")
text = text[:start] + "RunLoop.main.run()\n" + text[end + 2:]
pathlib.Path(dest).write_text(text)
PY
unbounded_status="$(compile_to "$WORK/restore-unbounded" "$STANDIN" "$WORK/unbounded-src/main.swift")"
[[ "$unbounded_status" -eq 0 ]] || fail "unbounded helper failed to compile: $(cat "$WORK/compile.err")"
sleep 30 &
bystander="$!"
bystander_mark="$(process_lstart "$bystander" || true)"
remember "$bystander" "$bystander_mark"
[[ -n "$bystander_mark" ]] || fail "could not identify the bystander sleep"
set +e
UMB_RESTORE_STANDIN=ok \
  run_bounded 3 "$WORK/restore-unbounded" "$app_path" umbilical >"$WORK/helper.out" 2>"$WORK/helper.err"
status=$?
set -e
[[ "$status" -eq 124 ]] || fail "unbounded run loop exited $status, so this check would stay green"
now_mark="$(process_lstart "$bystander" || true)"
[[ "$now_mark" == "$bystander_mark" ]] || fail "timeout kill touched the bystander sleep"
kill -0 "$bystander" 2>/dev/null || fail "bystander sleep is gone"
pass "planting RunLoop.main.run() does not exit 0 and the kill leaves another sleep alone"
{
  stop_recorded "$bystander" "$bystander_mark"
  wait "$bystander" 2>/dev/null || true
} 2>"$WORK/stop.err"
if grep -q 'Terminated' "$WORK/stop.err"; then
  fail "job control message leaked: $(cat "$WORK/stop.err")"
fi
forget "$bystander"

sleep 30 &
leaked="$!"
leaked_mark="$(process_lstart "$leaked" || true)"
remember "$leaked" "$leaked_mark"
found="$(offenders || true)"
printf '%s\n' "$found" | grep -F 'sleep' >/dev/null || fail "planted sleep was invisible to the leftover check"
pass "a planted sleep makes the leftover check fail"
{
  stop_recorded "$leaked" "$leaked_mark"
  wait "$leaked" 2>/dev/null || true
} 2>"$WORK/stop.err"
if grep -q 'Terminated' "$WORK/stop.err"; then
  fail "job control message leaked: $(cat "$WORK/stop.err")"
fi
forget "$leaked"
found="$(offenders || true)"
[[ -z "$found" ]] || fail "leftover after the planted sleep was stopped: $found"
pass "stopping the recorded pid clears the leftover check"

[[ "$(sha256sum "$SRC" | awk '{ print $1 }')" == "$SHIP_HASH" ]] || fail "shipped helper changed"
pass "the shipped helper was not modified"

echo "strict-restore-helper tests: $PASSES"
[[ "$PASSES" -gt 0 ]] || fail "test count is 0"

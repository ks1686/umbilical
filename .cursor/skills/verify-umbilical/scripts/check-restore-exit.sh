#!/usr/bin/env bash
# The restore helper must exit after a successful restore. The old no-argument
# main run loop does not, and this script fails if that form comes back.
# It also checks that the harness stops a child it started, and only that child.
set -euo pipefail
umask 077

if [[ "$#" -ne 2 ]]; then
  echo "usage: check-restore-exit.sh RESTORE_SWIFT HARNESS" >&2
  exit 2
fi

SRC="$1"
HARNESS="$2"
[[ -f "$SRC" && -f "$HARNESS" ]] || {
  echo "FAIL: restore helper or harness is missing" >&2
  exit 1
}

WORK=""
BYSTANDER=""
BYSTANDER_START=""
BYSTANDER_EXE=""

stop_owned_children() {
  local pid exe
  for pid in $(pgrep -P "$$" || true); do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  if [[ -z "${WORK:-}" || ! -d "$WORK" ]]; then
    return 0
  fi
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in
      "$WORK"/*)
        kill -TERM "$pid" 2>/dev/null || true
        ;;
    esac
  done
}

cleanup() {
  stop_owned_children || true
  if [[ -n "${BYSTANDER:-}" && -n "${BYSTANDER_START:-}" ]]; then
    local now_start now_exe
    now_start="$(ps -o lstart= -p "$BYSTANDER" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    now_exe="$(readlink -f "/proc/$BYSTANDER/exe" 2>/dev/null || true)"
    if [[ "$now_start" == "$BYSTANDER_START" && -n "$BYSTANDER_EXE" && "$now_exe" == "$BYSTANDER_EXE" ]]; then
      kill -TERM "$BYSTANDER" 2>/dev/null || true
    fi
  fi
  if [[ -n "${WORK:-}" ]]; then
    case "$WORK" in
      /tmp/umb-restore-exit.*|/private/tmp/umb-restore-exit.*)
        rm -rf "$WORK"
        ;;
    esac
  fi
  return 0
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "PASS: $*"
}

WORK="$(mktemp -d /tmp/umb-restore-exit.XXXXXX)"
case "$WORK" in
  /tmp/umb-restore-exit.*) ;;
  *) fail "unexpected work directory $WORK" ;;
esac

if [[ -x /opt/swift/usr/bin/swiftc ]]; then
  SWIFTC=/opt/swift/usr/bin/swiftc
elif command -v swiftc >/dev/null 2>&1; then
  SWIFTC="$(command -v swiftc)"
else
  fail "swiftc is not available"
fi
command -v timeout >/dev/null 2>&1 || fail "timeout is not available"
command -v python3 >/dev/null 2>&1 || fail "python3 is not available"

grep -q 'while !box.finished && Date() < deadline' "$SRC" || fail "helper has no deadline loop"
grep -q 'addingTimeInterval(60)' "$SRC" || fail "helper deadline is not 60 seconds"
grep -q 'RunLoop.main.run(mode: .default, before:' "$SRC" || fail "helper does not poll the main run loop"
if grep -q 'RunLoop.main.run()' "$SRC"; then
  fail "helper uses the unbounded run loop"
fi
grep -q 'run_bounded 75' "$HARNESS" || fail "swift helper call site has no 75s limit"

compile_helper() {
  local mode="$1"
  local out="$2"
  local cache="$WORK/cache-$mode"
  local tmp="$WORK/tmp-$mode"
  local home="$WORK/home-$mode"
  local swift="$WORK/$mode.swift"
  mkdir -p "$cache" "$tmp" "$home"
  python3 - "$SRC" "$swift" "$mode" <<'PY' || fail "could not prepare $mode helper"
import pathlib, sys
src, dest, mode = sys.argv[1:]
text = pathlib.Path(src).read_text()
if "import AppKit\n" not in text:
    raise SystemExit("missing AppKit import")
success_stub = '''import Foundation
class NSWorkspace {
    static let shared = NSWorkspace()
    func setDefaultApplication(at url: URL, toOpenURLsWithScheme scheme: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            completion(nil)
        }
    }
}
'''
silent_stub = '''import Foundation
class NSWorkspace {
    static let shared = NSWorkspace()
    func setDefaultApplication(at url: URL, toOpenURLsWithScheme scheme: String, completion: @escaping (Error?) -> Void) {
    }
}
'''
if mode == "success":
    stub = success_stub
elif mode == "timeout":
    if "addingTimeInterval(60)" not in text:
        raise SystemExit("missing 60s deadline")
    text = text.replace("addingTimeInterval(60)", "addingTimeInterval(1)", 1)
    stub = silent_stub
elif mode == "unbounded":
    start = text.find("while !box.finished && Date() < deadline {")
    if start < 0:
        raise SystemExit("missing deadline loop")
    end = text.find("\n}", start)
    if end < 0:
        raise SystemExit("missing loop end")
    text = text[:start] + "RunLoop.main.run()\n" + text[end + 2:]
    stub = success_stub
else:
    raise SystemExit("unknown mode")
text = text.replace("import AppKit\n", stub, 1)
pathlib.Path(dest).write_text(text)
PY
  HOME="$home" TMPDIR="$tmp" CLANG_MODULE_CACHE_PATH="$cache" SWIFT_MODULECACHE_PATH="$cache" \
    "$SWIFTC" -module-cache-path "$cache" "$swift" -o "$out" || fail "could not compile $mode helper"
}

HELPER_STATUS=0
ELAPSED=0
run_helper() {
  local bin="$1"
  local limit="$2"
  local started ended
  : >"$WORK/helper.out"
  : >"$WORK/helper.err"
  started="$(date +%s)"
  set +e
  timeout "$limit" "$bin" /tmp/Umbilical.app umbilical >"$WORK/helper.out" 2>"$WORK/helper.err"
  HELPER_STATUS=$?
  set -e
  ended="$(date +%s)"
  ELAPSED=$((ended - started))
}

compile_helper success "$WORK/ok"
run_helper "$WORK/ok" 10
[[ "$HELPER_STATUS" -eq 0 ]] || fail "helper exit $HELPER_STATUS after restore, stderr [$(cat "$WORK/helper.err")]"
[[ "$ELAPSED" -lt 10 ]] || fail "helper took ${ELAPSED}s after restore"
pass "restore helper exited 0 in ${ELAPSED}s after restore"

set +e
"$WORK/ok" /tmp/Umbilical.app http >"$WORK/scheme.out" 2>"$WORK/scheme.err"
scheme_status=$?
set -e
[[ "$scheme_status" -eq 2 ]] || fail "wrong scheme exit $scheme_status"
pass "restore helper rejects a scheme other than umbilical"

compile_helper unbounded "$WORK/old"
run_helper "$WORK/old" 3
[[ "$HELPER_STATUS" -eq 124 ]] || fail "unbounded run loop exit $HELPER_STATUS, wanted a timeout"
if [[ -d /proc ]]; then
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [[ "$exe" == "$WORK/old" ]] && fail "unbounded helper pid $pid is still running"
  done
fi
pass "unbounded run loop was still running after 3s and was stopped"

compile_helper timeout "$WORK/late"
run_helper "$WORK/late" 8
[[ "$HELPER_STATUS" -eq 1 ]] || fail "deadline exit $HELPER_STATUS, stderr [$(cat "$WORK/helper.err")]"
grep -q "handler restore timed out waiting for NSWorkspace" "$WORK/helper.err" || fail "deadline message missing [$(cat "$WORK/helper.err")]"
[[ "$ELAPSED" -ge 1 && "$ELAPSED" -lt 8 ]] || fail "deadline elapsed ${ELAPSED}s"
pass "restore helper exits 1 when its deadline passes (${ELAPSED}s)"

python3 - "$HARNESS" "$WORK/bounded.bash" <<'PY' || fail "could not extract run_bounded"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
names = ["process_exe", "process_lstart", "stop_bounded_child", "run_bounded"]
parts = []
for name in names:
    match = re.search(r"(?m)^%s\(\) \{\n(?:.*\n)*?^\}" % re.escape(name), text)
    if not match:
        raise SystemExit("missing " + name)
    parts.append(match.group(0))
pathlib.Path(sys.argv[2]).write_text("\n".join(parts) + "\n")
PY
# shellcheck disable=SC1091
source "$WORK/bounded.bash"

sleep 60 &
BYSTANDER=$!
disown "$BYSTANDER" 2>/dev/null || true
attempt=0
while [[ "$attempt" -lt 10 ]]; do
  BYSTANDER_START="$(process_lstart "$BYSTANDER" || true)"
  BYSTANDER_EXE="$(process_exe "$BYSTANDER" || true)"
  [[ -n "$BYSTANDER_START" && -n "$BYSTANDER_EXE" ]] && break
  sleep 0.05
  attempt=$((attempt + 1))
done
[[ -n "$BYSTANDER_START" && -n "$BYSTANDER_EXE" ]] || fail "could not identify the bystander sleep"

started="$(date +%s)"
set +e
run_bounded 3 sleep 60
bounded_status=$?
set -e
ended="$(date +%s)"
[[ "$bounded_status" -eq 124 ]] || fail "stuck child exit $bounded_status, wanted 124"
[[ $((ended - started)) -lt 8 ]] || fail "stuck child was still waited on after $((ended - started))s"
now_start="$(process_lstart "$BYSTANDER" || true)"
now_exe="$(process_exe "$BYSTANDER" || true)"
[[ "$now_start" == "$BYSTANDER_START" && "$now_exe" == "$BYSTANDER_EXE" ]] || fail "bystander sleep was signaled"
kill -0 "$BYSTANDER" 2>/dev/null || fail "bystander sleep is gone"
sleeps=0
for pid in $(pgrep -P "$$" || true); do
  exe="$(process_exe "$pid" || true)"
  case "$exe" in
    */sleep) sleeps=$((sleeps + 1)) ;;
  esac
done
[[ "$sleeps" -eq 1 ]] || fail "expected one sleep child, found $sleeps"
pass "harness stops a stuck child in $((ended - started))s and leaves another sleep alone"
pass "restore helper exits and the call site is bounded"

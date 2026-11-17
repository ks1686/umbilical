#!/usr/bin/env bash
# The restore helper must exit after a successful restore. The old no-argument
# main run loop does not, and this script fails if that form comes back.
# It also checks that the harness stops a child it started, and only that child,
# and that a child exit of 1 is returned as 1.
set -euo pipefail
umask 077

if [[ "$#" -ne 2 ]]; then
  echo "usage: check-restore-exit.sh RESTORE_SWIFT HARNESS" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(readlink -f "$1")"
HARNESS="$(readlink -f "$2")"
[[ -f "$SRC" && -f "$HARNESS" ]] || {
  echo "FAIL: restore helper or harness is missing" >&2
  exit 1
}
if [[ "${UMB_INSIDE_PRIVATE_TMP:-}" != "1" ]]; then
  exec "$SCRIPT_DIR/enter-private-tmp.sh" "$(readlink -f /proc/$$/exe)" "$SCRIPT_DIR/check-restore-exit.sh" "$SRC" "$HARNESS"
fi

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
  if [[ -n "${WORK:-}" && -f "${WORK}/leftover-ids" ]]; then
    local pid start now
    while IFS=$'\t' read -r pid start; do
      [[ -z "$pid" ]] && continue
      now="$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
      if [[ -n "$now" && "$now" == "$start" ]]; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done <"${WORK}/leftover-ids"
  fi
  if [[ -n "${WORK:-}" && -f "${WORK}/active-hold" ]]; then
    local shell_pid scratch sleep_pid sleep_start parent
    shell_pid="$(sed -n '1p' "${WORK}/active-hold")"
    scratch="$(sed -n '2p' "${WORK}/active-hold")"
    sleep_pid="$(sed -n '3p' "${WORK}/active-hold")"
    sleep_start="$(sed -n '4p' "${WORK}/active-hold")"
    if [[ "$shell_pid" =~ ^[0-9]+$ ]]; then
      kill -KILL "$shell_pid" 2>/dev/null || true
    fi
    if [[ "$sleep_pid" =~ ^[0-9]+$ && -n "$sleep_start" ]]; then
      now="$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$sleep_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
      if [[ -n "$now" && "$now" == "$sleep_start" ]]; then
        kill -KILL "$sleep_pid" 2>/dev/null || true
      fi
    fi
    case "$scratch" in
      /tmp/umbilical-verify.*/scratch-*|/private/tmp/umbilical-verify.*/scratch-*)
        parent="$(dirname "$scratch")"
        case "$parent" in
          /tmp/umbilical-verify.*|/private/tmp/umbilical-verify.*)
            rm -rf "$parent"
            ;;
        esac
        ;;
    esac
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
on_signal() {
  trap - INT TERM EXIT
  cleanup || true
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
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
names = [
    "process_exe",
    "process_lstart",
    "tree_pid_known",
    "tree_remember",
    "tree_remember_root",
    "tree_matches",
    "tree_collect",
    "tree_note_descendants",
    "tree_signal_matching",
    "tree_any_alive",
    "escalate_recorded_tree",
    "stop_bounded_child",
    "run_bounded",
]
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

python3 - "$HARNESS" <<'PY' || fail "run_bounded removes the child from the job table"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"(?m)^run_bounded\(\) \{\n(?:.*\n)*?^\}", text)
if not match:
    raise SystemExit("missing run_bounded")
if re.search(r"(?m)^\s*disown\b", match.group(0)):
    raise SystemExit("disown is inside run_bounded")
PY

had_m=0
case $- in
  *m*) had_m=1 ;;
esac
set +e
run_bounded 5 "$BASH" -c 'exit 1'
child_status=$?
set -e
has_m=0
case $- in
  *m*) has_m=1 ;;
esac
[[ "$had_m" -eq "$has_m" ]] || fail "run_bounded changed monitor mode"
[[ "$child_status" -eq 1 ]] || fail "child exit 1 came back as $child_status"
pass "run_bounded returns 1 when the child exits 1"

set +e
run_bounded 5 "$BASH" -c 'exit 0'
child_status=$?
set -e
[[ "$child_status" -eq 0 ]] || fail "child exit 0 came back as $child_status"
pass "run_bounded returns 0 when the child exits 0"

python3 - "$WORK/bounded.bash" "$WORK/bounded-disown.bash" <<'PY' || fail "could not build the disown copy"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
old = "run_bounded() {"
if old not in text:
    raise SystemExit("missing run_bounded")
text = text.replace(old, "run_bounded_disown() {", 1)
needle = "  child=$!\n"
if needle not in text:
    raise SystemExit("missing child assignment")
text = text.replace(needle, needle + "  disown \"$child\" 2>/dev/null || true\n", 1)
pathlib.Path(sys.argv[2]).write_text(text)
PY
# shellcheck disable=SC1091
source "$WORK/bounded-disown.bash"
set +e
run_bounded_disown 5 "$BASH" -c 'exit 1'
disown_status=$?
set -e
[[ "$disown_status" -eq 0 ]] || fail "disown copy returned $disown_status for exit 1, so this check would stay green"
pass "putting disown back makes a failing child look successful"

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
bounded_status=0
set +e
{
  run_bounded 3 sleep 60
  bounded_status=$?
  echo after-return
} >"$WORK/bounded.out" 2>"$WORK/bounded.err"
set -e
if grep -q 'Terminated' "$WORK/bounded.err"; then
  fail "job control message leaked: $(cat "$WORK/bounded.err")"
fi
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

python3 - "$WORK/bounded.bash" "$WORK/bounded-loud.bash" <<'PY' || fail "could not build the loud kill copy"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
old = """      {
        stop_bounded_child "$child" "$start_mark" "$exe_mark"
        wait "$child" || true
      } 2>/dev/null
"""
new = """      stop_bounded_child "$child" "$start_mark" "$exe_mark"
      wait "$child" || true
"""
if old not in text:
    raise SystemExit("missing redirected kill")
text = text.replace("run_bounded() {", "run_bounded_loud() {", 1)
text = text.replace(old, new, 1)
pathlib.Path(sys.argv[2]).write_text(text)
PY
cat >"$WORK/loud-runner.sh" <<EOF
set +e
source "$WORK/bounded-loud.bash"
run_bounded_loud 1 sleep 30
echo status:\$?
EOF
"$BASH" "$WORK/loud-runner.sh" >"$WORK/loud.out" 2>"$WORK/loud.err" || fail "loud runner failed"
grep -qx 'status:124' "$WORK/loud.out" || fail "loud kill copy status [$(cat "$WORK/loud.out")]"
if [[ "$BASH_VERSION" == 3.2* ]]; then
  grep -q 'Terminated' "$WORK/loud.err" || fail "loud kill copy did not print Terminated [$(cat "$WORK/loud.err")], so this check would stay green"
  pass "dropping the kill redirect prints Terminated"
else
  pass "bash $BASH_VERSION loud kill path exited 124"
fi

: >"$WORK/leftover-ids"
cat >"$WORK/ignore-term.sh" <<'EOF'
trap '' TERM
outer_file="$1"
bash_bin="$2"
sleep_file="$3"
mid_file="$4"
stamp() {
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
printf '%s\t%s\n' "$$" "$(stamp "$$")" >"$outer_file"
"$bash_bin" -c 'trap "" TERM
sleep 120 &
sp=$!
st=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$sp" 2>/dev/null | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
printf "%s\t%s\n" "$sp" "$st" >"$1"
wait' _ "$sleep_file" &
mid=$!
printf '%s\t%s\n' "$mid" "$(stamp "$mid")" >"$mid_file"
wait
EOF

remember_ids() {
  local file line
  for file in "$@"; do
    [[ -s "$file" ]] || fail "missing process id file $file"
    line="$(cat "$file")"
    printf '%s\n' "$line" >>"$WORK/leftover-ids"
  done
}

same_id() {
  local file="$1"
  local pid start now
  pid="$(awk -F '\t' '{ print $1; exit }' "$file")"
  start="$(awk -F '\t' '{ print $2; exit }' "$file")"
  [[ -n "$pid" && -n "$start" ]] || return 1
  now="$(process_lstart "$pid" || true)"
  [[ -n "$now" && "$now" == "$start" ]]
}

python3 - "$WORK/bounded.bash" "$WORK/bounded-direct.bash" <<'PY' || fail "could not build the direct-only kill copy"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.find("stop_bounded_child() {")
end = text.find("\nrun_bounded() {")
if start < 0 or end < 0:
    raise SystemExit("missing stop_bounded_child")
old = '''stop_bounded_child() {
  local target="$1"
  local mark_start="$2"
  local mark_exe="$3"
  local now_start now_exe ppid attempt
  ppid="$(ps -o ppid= -p "$target" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$ppid" == "$$" ]] || return 0
  now_start="$(process_lstart "$target" || true)"
  now_exe="$(process_exe "$target" || true)"
  if [[ -n "$mark_start" && "$now_start" != "$mark_start" ]]; then
    return 0
  fi
  if [[ -n "$mark_exe" && "$now_exe" != "$mark_exe" ]]; then
    return 0
  fi
  kill -TERM "$target" 2>/dev/null || true
  attempt=0
  while [[ "$attempt" -lt 5 ]]; do
    kill -0 "$target" 2>/dev/null || return 0
    sleep 0.2
    attempt=$((attempt + 1))
  done
  ppid="$(ps -o ppid= -p "$target" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$ppid" == "$$" ]] || return 0
  now_start="$(process_lstart "$target" || true)"
  now_exe="$(process_exe "$target" || true)"
  if [[ -n "$mark_start" && "$now_start" != "$mark_start" ]]; then
    return 0
  fi
  if [[ -n "$mark_exe" && "$now_exe" != "$mark_exe" ]]; then
    return 0
  fi
  kill -KILL "$target" 2>/dev/null || true
}
'''
text = text[:start] + old + "\n" + text[end + 1:]
text = text.replace("run_bounded() {", "run_bounded_direct_only() {", 1)
pathlib.Path(sys.argv[2]).write_text(text)
PY

direct_status=0
set +e
{
  # shellcheck disable=SC1091
  source "$WORK/bounded-direct.bash"
  run_bounded_direct_only 2 "$BASH" "$WORK/ignore-term.sh" "$WORK/direct-outer.id" "$BASH" "$WORK/direct-sleep.id" "$WORK/direct-mid.id"
  direct_status=$?
  echo after-return
} >"$WORK/direct.out" 2>"$WORK/direct.err"
set -e
# shellcheck disable=SC1091
source "$WORK/bounded.bash"
[[ "$direct_status" -eq 124 ]] || fail "direct-only kill exit $direct_status, wanted 124"
remember_ids "$WORK/direct-outer.id" "$WORK/direct-sleep.id" "$WORK/direct-mid.id"
if same_id "$WORK/direct-mid.id" && same_id "$WORK/direct-sleep.id"; then
  pass "TERM then KILL of only the child leaves the grandchild"
else
  fail "direct-only kill reaped the grandchild, so this check would stay green"
fi
if same_id "$WORK/direct-outer.id"; then
  fail "direct-only kill left the child running"
fi

tree_status=0
set +e
{
  run_bounded 2 "$BASH" "$WORK/ignore-term.sh" "$WORK/tree-outer.id" "$BASH" "$WORK/tree-sleep.id" "$WORK/tree-mid.id"
  tree_status=$?
  echo after-return
} >"$WORK/tree.out" 2>"$WORK/tree.err"
set -e
[[ "$tree_status" -eq 124 ]] || fail "tree kill exit $tree_status, wanted 124"
if grep -q 'Terminated' "$WORK/tree.err"; then
  fail "tree kill printed Terminated: $(cat "$WORK/tree.err")"
fi
remember_ids "$WORK/tree-outer.id" "$WORK/tree-sleep.id" "$WORK/tree-mid.id"
if same_id "$WORK/tree-outer.id" || same_id "$WORK/tree-mid.id" || same_id "$WORK/tree-sleep.id"; then
  fail "grandchild that ignores TERM is still running"
fi
now_start="$(process_lstart "$BYSTANDER" || true)"
now_exe="$(process_exe "$BYSTANDER" || true)"
[[ "$now_start" == "$BYSTANDER_START" && "$now_exe" == "$BYSTANDER_EXE" ]] || fail "tree kill signaled the bystander"
kill -0 "$BYSTANDER" 2>/dev/null || fail "tree kill removed the bystander"
pass "KILL after the grace period reaps a grandchild that ignores TERM"

[[ "$(readlink -f /tmp)" == "/private/tmp" ]] || fail "not in the macOS /tmp layout"
mkdir -p "$WORK/signal-bystander"

run_signal_hold() {
  local harness="$1"
  local sig="$2"
  local expect_cleanup="$3"
  local marker shell_pid scratch sleep_pid sleep_start attempt parent
  marker="$(mktemp "$WORK/hold-marker.XXXXXX")"
  : >"$marker"
  cp "$marker" "$WORK/active-hold"
  # setsid ignores SIGINT, so bash would refuse the INT trap. A new session
  # started by python keeps the default SIGINT disposition.
  python3 - "$BASH" "$harness" "$marker" "$WORK/hold.out" "$WORK/hold.err" <<'PY' || fail "could not start the signal hold"
import os, subprocess, sys
bash, harness, marker, out_path, err_path = sys.argv[1:]
env = os.environ.copy()
env["UMB_VERIFY_SIGNAL_HOLD"] = marker
proc = subprocess.Popen(
    [bash, harness, "doctor"],
    stdout=open(out_path, "w"),
    stderr=open(err_path, "w"),
    stdin=subprocess.DEVNULL,
    env=env,
    start_new_session=True,
)
proc.poll()
PY
  shell_pid=""
  scratch=""
  sleep_pid=""
  sleep_start=""
  attempt=0
  while [[ "$attempt" -lt 50 ]]; do
    if [[ -s "$marker" ]]; then
      shell_pid="$(sed -n '1p' "$marker")"
      scratch="$(sed -n '2p' "$marker")"
      sleep_pid="$(sed -n '3p' "$marker")"
      sleep_start="$(sed -n '4p' "$marker")"
      if [[ -n "$shell_pid" && -n "$scratch" ]]; then
        cp "$marker" "$WORK/active-hold"
        break
      fi
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -n "$shell_pid" && -n "$scratch" ]] || fail "signal hold did not start for $sig"
  kill "-$sig" "$shell_pid" 2>/dev/null || true
  attempt=0
  while [[ "$attempt" -lt 50 ]]; do
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$shell_pid" 2>/dev/null; then
    if [[ "$expect_cleanup" == "yes" ]]; then
      fail "signal hold ignored $sig"
    fi
    kill -KILL "$shell_pid" 2>/dev/null || true
  fi
  parent="$(dirname "$scratch")"
  if [[ "$expect_cleanup" == "yes" ]]; then
    grep -qx "signal ${sig_status}" "$marker" || fail "signal $sig did not run the teardown ($(cat "$marker"))"
    [[ ! -e "$scratch" ]] || fail "signal $sig left scratch $scratch"
    [[ ! -e "$parent" ]] || fail "signal $sig left $parent"
  else
    if grep -q "signal " "$marker"; then
      fail "removing the trap still ran the signal teardown"
    fi
    [[ -d "$scratch" ]] || fail "removing the trap still deleted the scratch, so this check would stay green"
    case "$parent" in
      /tmp/umbilical-verify.*|/private/tmp/umbilical-verify.*)
        rm -rf "$parent"
        ;;
    esac
  fi
  [[ -d "$WORK/signal-bystander" ]] || fail "signal teardown removed the bystander directory"
  if [[ "$sleep_pid" =~ ^[0-9]+$ && -n "$sleep_start" ]]; then
    local now
    now="$(process_lstart "$sleep_pid" || true)"
    if [[ -n "$now" && "$now" == "$sleep_start" ]]; then
      kill -KILL "$sleep_pid" 2>/dev/null || true
    fi
  fi
  rm -f "$WORK/active-hold"
}

# sig_status is the exit the trap uses. kill -INT delivers signal 2.
run_signal_hold_int() {
  sig_status=130
  run_signal_hold "$@"
}
run_signal_hold_term() {
  sig_status=143
  run_signal_hold "$@"
}

python3 - "$HARNESS" "$WORK/harness-no-trap" <<'PY' || fail "could not drop the signal traps"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
kept = []
removed = 0
for line in text.splitlines(True):
    if line in ("trap 'on_signal 130' INT\n", "trap 'on_signal 143' TERM\n"):
        removed += 1
        continue
    kept.append(line)
if removed != 2:
    raise SystemExit("removed %s trap lines" % removed)
pathlib.Path(sys.argv[2]).write_text("".join(kept))
PY
run_signal_hold_term "$WORK/harness-no-trap" TERM no
pass "without the signal trap, TERM leaves the scratch directory"
run_signal_hold_int "$HARNESS" INT yes
pass "INT runs the same teardown as die"
run_signal_hold_term "$HARNESS" TERM yes
pass "TERM runs the same teardown as die"
now_start="$(process_lstart "$BYSTANDER" || true)"
now_exe="$(process_exe "$BYSTANDER" || true)"
[[ "$now_start" == "$BYSTANDER_START" && "$now_exe" == "$BYSTANDER_EXE" ]] || fail "signal teardown signaled the bystander"
kill -0 "$BYSTANDER" 2>/dev/null || fail "signal teardown removed the bystander"
pass "restore helper exits and the call site is bounded"

#!/tmp/bash-3.2.57/bash
# Linux proof for verify-umbilical. The harness runs under HARNESS_BASH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS:-$SCRIPT_DIR/verify-umbilical}"
BASH32="${HARNESS_BASH:-/tmp/bash-3.2.57/bash}"
PROOF_ROOT="$(mktemp -d /tmp/umb-proof.XXXXXX)"
EVIDENCE="$PROOF_ROOT/evidence"
ARTIFACTS="/opt/cursor/artifacts/verify-umbilical"
STATE="$PROOF_ROOT/state.env"
REAL_UNAME="$(/usr/bin/uname -s)"
REAL_PREFS="$(getent passwd "$(id -un)" | awk -F: '{ print $6 }')/Library/Preferences/me.peapod.umbilical.plist"
PIDFILE="$PROOF_ROOT/pids"
export UMB_VERIFY_EVIDENCE="$EVIDENCE"
export UMB_VERIFY_STATE="$STATE"

rm -rf /tmp/umbilical-verify-marker /tmp/payload-real-target /tmp/payload-link-dir /tmp/payload-real /tmp/victim-payload /tmp/notes-about-verify-umbilical-payload.py /tmp/evidence-link /tmp/evidence-target /tmp/umb-ev-custom /tmp/umb-ev-cleanup /tmp/early-ev /tmp/u31-home /tmp/u31-downloads /tmp/link-to-parent /tmp/umb-payload-real /tmp/link-outside
mkdir -p "$EVIDENCE"
printf 'kept after cleanup\n' >"$EVIDENCE/kept.txt"
: >"$EVIDENCE/proof.log"
: >"$PIDFILE"
echo "proof root $PROOF_ROOT" | tee -a "$EVIDENCE/proof.log"

fail() {
  echo "FAIL: $*" | tee -a "$EVIDENCE/proof.log" >&2
  exit 1
}

pass() {
  echo "PASS: $*" | tee -a "$EVIDENCE/proof.log"
}

track() {
  printf '%s\n' "$1" >>"$PIDFILE"
}

stop_tracked() {
  local pid
  if [[ -f "$PIDFILE" ]]; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done <"$PIDFILE"
  fi
}
copy_evidence() {
  mkdir -p "$ARTIFACTS" 2>/dev/null || true
  if [[ -d "$EVIDENCE" ]]; then
    cp -f "$EVIDENCE/proof.log" "$EVIDENCE/commands.log" "$EVIDENCE/kept.txt" "$ARTIFACTS/" 2>/dev/null || true
  fi
}
trap 'stop_tracked; copy_evidence' EXIT

run_harness() {
  "$BASH32" "$HARNESS" "$@"
}

run_expect() {
  local want="$1"
  local label="$2"
  shift 2
  local out err status
  out="$(mktemp)"
  err="$(mktemp)"
  set +e
  "$@" >"$out" 2>"$err"
  status=$?
  set -e
  if [[ "$status" != "$want" ]]; then
    {
      echo "command: $*"
      cat "$err"
      cat "$out"
    } >>"$EVIDENCE/proof.log"
    rm -f "$out" "$err"
    fail "$label wanted exit $want, got $status"
  fi
  LAST_OUT="$(cat "$out")"
  LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  pass "$label (exit $status)"
}

assert_contains() {
  local hay="$1"
  local needle="$2"
  local label="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    fail "$label missing [$needle] in [$hay]"
  fi
  pass "$label"
}

assert_absent() {
  local hay="$1"
  local needle="$2"
  local label="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    fail "$label unexpectedly contained [$needle]"
  fi
  pass "$label"
}

prefs_fingerprint() {
  if [[ -e "$REAL_PREFS" || -L "$REAL_PREFS" ]]; then
    stat -c '%d:%i:%Y:%s' "$REAL_PREFS"
    sha256sum "$REAL_PREFS" | awk '{ print $1 }'
  else
    printf 'ABSENT\n'
  fi
}

PREFS_BEFORE="$(prefs_fingerprint)"

write_plist() {
  local path="$1"
  local ident="$2"
  local version="$3"
  local polar="$4"
  python3 - "$path" "$ident" "$version" "$polar" <<'PY'
import plistlib
import sys
info = {
    "CFBundleIdentifier": sys.argv[2],
    "CFBundleExecutable": "umbilical",
    "CFBundleShortVersionString": sys.argv[3],
}
if sys.argv[4] != "-":
    info["PolarOrganizationID"] = sys.argv[4]
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(info, handle)
PY
}

make_app() {
  local dest="$1"
  local ident="$2"
  local version="$3"
  local polar="$4"
  local bin="${5:-holder}"
  rm -rf "$dest"
  mkdir -p "$dest/Contents/MacOS"
  if [[ "$bin" == "holder" ]]; then
    cp -a /tmp/umb-holder "$dest/Contents/MacOS/umbilical"
  elif [[ "$bin" == "sleep" ]]; then
    cp -a "$(readlink -f "$(command -v sleep)")" "$dest/Contents/MacOS/umbilical"
  fi
  chmod 755 "$dest/Contents/MacOS/umbilical" >/dev/null 2>&1 || true
  write_plist "$dest/Contents/Info.plist" "$ident" "$version" "$polar"
}

lstart_of() {
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

start_holder() {
  local exe="$1"
  local home="$2"
  nohup env HOME="$home" CFFIXED_USER_HOME="$home" __CFPREFERENCES_AVOID_DAEMON=1 \
    "$exe" >/tmp/umb-holder.out 2>&1 &
  local pid="$!"
  track "$pid"
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "fixture $pid exited"
  printf '%s\n' "$pid"
}

new_scratch() {
  local run_id="$1"
  local parent
  parent="$(mktemp -d /tmp/umbilical-verify.XXXXXX)"
  chmod 700 "$parent"
  mktemp -d "$parent/scratch-${run_id}-XXXXXX"
}

list_verify_parents() {
  local root
  for root in /tmp /private/tmp; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 1 -name 'umbilical-verify.*' -printf '%p\n'
  done | LC_ALL=C sort
}

plant_plist() {
  local home="$1"
  mkdir -p "$home/Library/Preferences" "$home/../umbilical-verify-downloads"
  printf '{}\n' >"$home/Library/Preferences/me.peapod.umbilical.plist"
}

emit_state() {
  local run_id="$1"
  local pid="$2"
  local app="$3"
  local scratch="$4"
  local version="$5"
  local lstart="$6"
  local sha="${7:-}"
  local mtime="${8:-}"
  local settings="${9:-0}"
  local freeze_out snap_sha snap_mtime parent meta
  parent="$(dirname "$scratch")"
  meta="$PROOF_ROOT/freeze-$run_id"
  if [[ ! -f "$parent/account-$run_id.snap" ]]; then
    freeze_out="$(UMB_VERIFY_STATE="$PROOF_ROOT/no-such-freeze-state.env" UMB_VERIFY_PARENT="$parent" "$BASH32" "$HARNESS" freeze-account "$run_id")"
    printf '%s\n' "$freeze_out" >"$meta"
  fi
  snap_sha="$(sed -n 's/^prefs_sha=//p' "$meta")"
  snap_mtime="$(sed -n 's/^prefs_mtime=//p' "$meta")"
  [[ -n "$sha" ]] || sha="$snap_sha"
  [[ -n "$mtime" ]] || mtime="$snap_mtime"
  cat >"$STATE" <<EOF
run_id=$run_id
pid=$pid
app_path=$app
executable=$app/Contents/MacOS/umbilical
home=$scratch/home
scratch=$scratch
downloads=$scratch/umbilical-verify-downloads
evidence=$EVIDENCE
version=$version
server_pid=
lstart=$lstart
prefs_sha=$sha
prefs_mtime=$mtime
settings_written=$settings
handler_path=skipped
verify_parent=$parent
EOF
  chmod 600 "$STATE"
}

mode_of() {
  stat -c '%a' "$1"
}

# The inner bash must expand its own version. The single quotes are intentional.
# shellcheck disable=SC2016
echo "host $(uname -s) $(uname -m) bash $($BASH32 -c 'echo $BASH_VERSION')" | tee -a "$EVIDENCE/proof.log"
# shellcheck disable=SC2016
runner_version="$($BASH32 -c 'echo $BASH_VERSION')"
[[ "$runner_version" == 3.2* || "$runner_version" == 5.* ]] || fail "harness runner is $runner_version"
pass "harness runner is bash $runner_version"
run_expect 1 "false returns 1" false

run_expect 2 "no args" run_harness
assert_contains "$LAST_ERR" "usage:" "usage text"
run_expect 2 "launch missing app" run_harness launch
run_expect 2 "unknown command" run_harness dance
run_expect 2 "drive missing feature" run_harness drive
run_expect 2 "empty url flag" run_harness drive add-download --url ""
assert_contains "$LAST_ERR" "missing value for --url" "empty url flag message"
run_expect 2 "file url" run_harness drive add-download --url "file:///tmp/x"
assert_contains "$LAST_ERR" "That URL scheme is not allowed (file)." "file scheme message"
run_expect 2 "userinfo url" run_harness drive add-download --url "https://user:password@example.com/a"
assert_contains "$LAST_ERR" "URLs that include a username or password are rejected." "userinfo message"
run_expect 2 "option url" run_harness drive add-download --url "-o"
assert_contains "$LAST_ERR" "cannot be used as a command option" "option message"
run_expect 1 "drive without instance" run_harness drive add-download
assert_contains "$LAST_ERR" "no verification instance" "drive doctor failure"
run_expect 1 "doctor without instance" run_harness doctor
run_expect 0 "cleanup with nothing" run_harness cleanup
assert_contains "$LAST_OUT" "nothing to clean" "cleanup idle text"
run_expect 2 "doctor rejects discard" run_harness doctor --discard
assert_contains "$LAST_ERR" "--discard is only valid for cleanup" "doctor discard message"
run_expect 2 "freeze rejects discard" run_harness freeze-account --discard 20260101T000000Z-abcdef01
assert_contains "$LAST_ERR" "--discard is only valid for cleanup" "freeze discard message"
python3 "$SCRIPT_DIR/check-handler-call.py" "$HARNESS" "$SCRIPT_DIR/restore-handler.swift" || fail "handler call check"
call_tmp="$(mktemp)"
printf '%s\n' '// setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler(appURL, "umbilical", function(error) {})' >"$call_tmp"
python3 "$SCRIPT_DIR/check-handler-call.py" "$call_tmp" && fail "a comment was accepted as the handler call"
printf '%s\n' 'var name = "setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler";' >"$call_tmp"
python3 "$SCRIPT_DIR/check-handler-call.py" "$call_tmp" && fail "a string was accepted as the handler call"
printf '%s\n' '$.NSWorkspace.sharedWorkspace.setDefaultApplicationAtURLToOpenURLsWithSchemeError(appURL, "umbilical", function(error) {});' >"$call_tmp"
python3 "$SCRIPT_DIR/check-handler-call.py" "$call_tmp" && fail "the old error selector was accepted"
rm -f "$call_tmp"
pass "handler call is parsed"

GOOD="/tmp/umb-fixtures/Umbilical.app"
rm -rf /tmp/umb-fixtures
mkdir -p /tmp/evidence-target /tmp/umb-fixtures
ln -s /tmp/evidence-target /tmp/evidence-link
make_app "$GOOD" "me.peapod.umbilical" "1.0.2" "-" holder
# evidence symlink is checked before the parent. Parent can be absent.
run_expect 1 "evidence symlink" run_harness launch --app "$GOOD" --evidence /tmp/evidence-link
assert_contains "$LAST_ERR" "symlink" "evidence symlink message"
if [[ -e /tmp/evidence-target/commands.log ]]; then
  fail "evidence symlink was followed"
fi
pass "evidence symlink was not followed"

mkdir -p /tmp/umb-parent-target
printf 'marker\n' > /tmp/umb-parent-target/marker
ln -sfn /tmp/umb-parent-target /tmp/umbilical-verify.badlink
UMB_VERIFY_PARENT=/tmp/umbilical-verify.badlink run_expect 1 "parent symlink" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "symlink" "parent symlink message"
if [[ -d /tmp/umb-parent-target/scratch-anything ]]; then
  fail "parent symlink received a scratch directory"
fi
[[ -f /tmp/umb-parent-target/marker ]] || fail "parent symlink target marker missing"
pass "parent symlink target was left alone"
rm -f /tmp/umbilical-verify.badlink

mkdir -m 755 /tmp/umbilical-verify.badmode
UMB_VERIFY_PARENT=/tmp/umbilical-verify.badmode run_expect 1 "parent mode" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "mode is 755, expected 700" "parent mode message"
rm -rf /tmp/umbilical-verify.badmode

rm -rf /tmp/early-ev
if [[ "$REAL_UNAME" == "Linux" ]]; then
  parents_before="$(list_verify_parents)"
  run_expect 3 "launch on linux" run_harness launch --app "$GOOD" --evidence /tmp/early-ev
  assert_contains "$LAST_ERR" "needs macOS" "launch platform message"
  assert_absent "$LAST_ERR" "codesign" "launch did not read a signature"
  [[ ! -f "$STATE" ]] || fail "launch created a state file"
  if pgrep -x umbilical >/dev/null; then
    fail "launch started a process"
  fi
  pass "launch started no process"
  [[ "$(list_verify_parents)" == "$parents_before" ]] || fail "linux launch created a verification parent"
  [[ ! -e /tmp/early-ev ]] || fail "linux launch created the evidence directory"
  pass "linux launch created no directories"
fi

PLACE="/tmp/umb-fixtures/Placeholder.app"
WRONG="/tmp/umb-fixtures/Wrong.app"
INVALID="/tmp/umb-fixtures/Invalid.app"
PRESENT="/tmp/umb-fixtures/Present.app"
NOEXE="/tmp/umb-fixtures/NoExe.app"
# shellcheck disable=SC2016
make_app "$PLACE" "me.peapod.umbilical" "1.0.2" '$(POLAR_ORGANIZATION_ID)' sleep
make_app "$WRONG" "com.example.other" "1.0.2" "-" sleep
make_app "$INVALID" "me.peapod.umbilical" "1.0.2" "not-a-uuid" sleep
make_app "$PRESENT" "me.peapod.umbilical" "1.0.2" "11111111-1111-1111-1111-111111111111" sleep
make_app "$NOEXE" "me.peapod.umbilical" "1.0.2" "-" none

run_expect 0 "inspect absent polar" run_harness inspect-app --app "$GOOD"
assert_contains "$LAST_OUT" "polar=absent" "absent class"
assert_contains "$LAST_OUT" "launch=ok" "absent can launch"
run_expect 0 "inspect placeholder polar" run_harness inspect-app --app "$PLACE"
assert_contains "$LAST_OUT" "polar=absent" "placeholder is absent"
assert_absent "$LAST_OUT$LAST_ERR" "POLAR_ORGANIZATION_ID" "placeholder value hidden"
run_expect 1 "inspect wrong bundle" run_harness inspect-app --app "$WRONG"
run_expect 1 "inspect invalid polar" run_harness inspect-app --app "$INVALID"
assert_contains "$LAST_OUT" "polar=invalid" "invalid class"
assert_contains "$LAST_OUT" "launch=refused" "invalid refused"
run_expect 0 "inspect present polar" run_harness inspect-app --app "$PRESENT"
assert_contains "$LAST_OUT" "polar=present" "present class"
assert_contains "$LAST_OUT" "needs-debug-signature" "present needs debug signature"
assert_absent "$LAST_OUT$LAST_ERR" "11111111-1111-1111-1111-111111111111" "uuid hidden"
run_expect 1 "inspect missing executable" run_harness inspect-app --app "$NOEXE"
run_expect 1 "launch invalid polar" run_harness launch --app "$INVALID"
assert_contains "$LAST_ERR" "does not launch" "invalid launch refusal"
if pgrep -x umbilical >/dev/null; then
  fail "invalid launch started a process"
fi
pass "invalid launch started no process"

mkdir -p /tmp/fake-codesign
cat > /tmp/fake-codesign/codesign <<'EOF'
#!/bin/sh
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>keychain-access-groups</key>
<array><string>hidden</string></array>
</dict></plist>
PLIST
EOF
chmod 755 /tmp/fake-codesign/codesign
PATH="/tmp/fake-codesign:$PATH" run_expect 1 "keychain entitlement" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "keychain-access-groups" "keychain refusal"
assert_absent "$LAST_ERR" "hidden" "keychain value hidden"
if pgrep -x umbilical >/dev/null; then
  fail "keychain refusal started a process"
fi
pass "keychain refusal started no process"

cat > /tmp/fake-codesign/codesign <<'EOF'
#!/bin/sh
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
</dict></plist>
PLIST
EOF
PATH="/tmp/fake-codesign:$PATH" run_expect 1 "release without get-task-allow" run_harness launch --app "$PRESENT"
assert_contains "$LAST_ERR" "get-task-allow" "release refusal"
if pgrep -x umbilical >/dev/null; then
  fail "release refusal started a process"
fi
pass "release refusal started no process"

# A string that merely contains the key name is not the entitlement.
cat > /tmp/fake-codesign/codesign <<'EOF'
#!/bin/sh
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.get-task-allow</key>
<true/>
<key>note</key>
<string>keychain-access-groups is mentioned here only</string>
</dict></plist>
PLIST
EOF
PATH="/tmp/fake-codesign:$PATH" run_expect 3 "entitlement text is not a key" run_harness launch --app "$GOOD"
assert_absent "$LAST_ERR" "keychain-access-groups" "substring was not treated as the entitlement"
assert_contains "$LAST_ERR" "needs macOS" "parsed entitlements still reach the platform check"
pass "entitlement parser ignored a substring"

cat > /tmp/fake-codesign/codesign <<'EOF'
#!/bin/sh
exit 0
EOF
PATH="/tmp/fake-codesign:$PATH" run_expect 1 "empty entitlements" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "no entitlements" "empty entitlements message"
if pgrep -x umbilical >/dev/null; then
  fail "empty entitlements started a process"
fi
pass "empty entitlements started no process"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-aabbccdd"
SCRATCH="$(new_scratch "$RUN_ID")"
mkdir -p "$SCRATCH/home" "$SCRATCH/umbilical-verify-downloads"
plant_plist "$SCRATCH/home"
APP_EXE="$GOOD/Contents/MacOS/umbilical"
PID="$(start_holder "$APP_EXE" "$SCRATCH/home")"
COMM="$(ps -p "$PID" -o comm= | tr -d ' ')"
[[ "$COMM" == "umbilical" ]] || fail "fixture comm is $COMM"
pass "fixture comm is umbilical"
CHILD="$(pgrep -P "$PID" || true)"
CHILD="${CHILD%%$'\n'*}"
[[ -n "$CHILD" ]] || fail "fixture has no child"
pass "fixture child $CHILD"

run_expect 1 "launch while umbilical is running" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already running" "running refusal"
if ! kill -0 "$PID" 2>/dev/null; then
  fail "running refusal killed the fixture"
fi
pass "running refusal left the fixture alive"
[[ ! -f "$STATE" ]] || fail "launch created a state file while a process was running"
pass "launch created no state file while a process was running"

LSTART="$(lstart_of "$PID")"
[[ -n "$LSTART" ]] || fail "could not read lstart"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
run_expect 4 "doctor identity on linux" run_harness doctor
assert_contains "$LAST_ERR" "UI readiness needs macOS" "doctor platform message"
assert_contains "$LAST_ERR" "Not worth driving." "doctor not worth driving"
[[ "$(mode_of "$EVIDENCE")" == "700" ]] || fail "evidence mode $(mode_of "$EVIDENCE")"
[[ "$(mode_of "$EVIDENCE/commands.log")" == "600" ]] || fail "commands.log mode $(mode_of "$EVIDENCE/commands.log")"
pass "evidence directory 700 and commands.log 600"
run_expect 4 "drive add-download on linux" run_harness drive add-download
assert_contains "$LAST_ERR" "Not worth driving." "drive stops at doctor"
run_expect 4 "ui click stops at doctor" run_harness ui click --name "Add Download"
assert_contains "$LAST_ERR" "Not worth driving." "ui stops at doctor"

# Plain doctor uses the evidence path stored in the state file.
CUSTOM="/tmp/umb-ev-custom"
mkdir -m 700 "$CUSTOM"
SAVED_EVIDENCE="$UMB_VERIFY_EVIDENCE"
unset UMB_VERIFY_EVIDENCE
python3 - "$STATE" "$CUSTOM" <<'PY'
import sys
path, custom = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out = []
for line in lines:
    if line.startswith("evidence="):
        out.append("evidence=" + custom)
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY
run_expect 4 "doctor without evidence flag" run_harness doctor --state "$STATE"
assert_contains "$LAST_ERR" "Not worth driving." "plain doctor still reaches the platform limit"
if [[ ! -f "$CUSTOM/commands.log" ]]; then
  fail "plain doctor did not write the state evidence log"
fi
assert_absent "$LAST_ERR" "does not match" "plain doctor did not reject the stored evidence path"
pass "plain doctor used the stored evidence path"
# Cleanup with no --evidence and no UMB_VERIFY_EVIDENCE uses the stored path.
# A dead pid keeps this from signaling the live fixture.
CLEAN_EVIDENCE="/tmp/umb-ev-cleanup"
CLEAN_STATE="$PROOF_ROOT/cleanup-evidence.env"
CLEAN_RUN="20260101T000000Z-abcdef01"
mkdir -m 700 "$CLEAN_EVIDENCE"
CLEAN_SCRATCH="$(new_scratch "$CLEAN_RUN")"
chmod 700 "$CLEAN_SCRATCH"
mkdir -p "$CLEAN_SCRATCH/home" "$CLEAN_SCRATCH/umbilical-verify-downloads"
FREEZE_OUT="$(UMB_VERIFY_STATE="$PROOF_ROOT/no-such-freeze-state.env" UMB_VERIFY_PARENT="$(dirname "$CLEAN_SCRATCH")" "$BASH32" "$HARNESS" freeze-account "$CLEAN_RUN")"
cat >"$CLEAN_STATE" <<EOF
run_id=$CLEAN_RUN
pid=999999
app_path=$GOOD
executable=$GOOD/Contents/MacOS/umbilical
home=$CLEAN_SCRATCH/home
scratch=$CLEAN_SCRATCH
downloads=$CLEAN_SCRATCH/umbilical-verify-downloads
evidence=$CLEAN_EVIDENCE
version=1.0.2
server_pid=
lstart=Wed Jan 1 00:00:00 1970
prefs_sha=$(printf '%s\n' "$FREEZE_OUT" | sed -n 's/^prefs_sha=//p')
prefs_mtime=$(printf '%s\n' "$FREEZE_OUT" | sed -n 's/^prefs_mtime=//p')
settings_written=0
handler_path=skipped
verify_parent=$(dirname "$CLEAN_SCRATCH")
EOF
chmod 600 "$CLEAN_STATE"
run_expect 0 "cleanup without evidence flag" run_harness cleanup --state "$CLEAN_STATE"
assert_contains "$LAST_OUT" "$CLEAN_EVIDENCE" "cleanup reported the stored evidence path"
[[ ! -e "$CLEAN_SCRATCH" ]] || fail "cleanup did not remove the disposable scratch"
[[ ! -e "$CLEAN_STATE" ]] || fail "cleanup did not remove the disposable state"
[[ -f "$CLEAN_EVIDENCE/commands.log" ]] || fail "cleanup did not write the stored evidence log"
assert_contains "$(cat "$CLEAN_EVIDENCE/commands.log")" "cleanup removed scratch" "cleanup log is in the stored evidence directory"
[[ "$(mode_of "$CLEAN_EVIDENCE")" == "700" ]] || fail "stored evidence directory mode is not 700"
[[ "$(mode_of "$CLEAN_EVIDENCE/commands.log")" == "600" ]] || fail "stored evidence log mode is not 600"
kill -0 "$PID" 2>/dev/null || fail "cleanup without --evidence signaled the live fixture"
[[ -f "$STATE" ]] || fail "cleanup without --evidence removed the live state"
pass "cleanup without --evidence left the live instance alone"
export UMB_VERIFY_EVIDENCE="$SAVED_EVIDENCE"
# Restore the evidence path for later cleanup checks.
python3 - "$STATE" "$EVIDENCE" <<'PY'
import sys
path, evidence = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out = []
for line in lines:
    if line.startswith("evidence="):
        out.append("evidence=" + evidence)
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY

run_expect 1 "dump outside evidence" run_harness ui dump --path /tmp/evil-dump.txt
assert_contains "$LAST_ERR" "inside the evidence directory" "dump path refusal"
[[ ! -e /tmp/evil-dump.txt ]] || fail "dump wrote outside evidence"
pass "dump did not write outside evidence"
run_expect 1 "screenshot outside evidence" run_harness ui screenshot --path /tmp/evil-shot.png
assert_contains "$LAST_ERR" "inside the evidence directory" "screenshot path refusal"
[[ ! -e /tmp/evil-shot.png ]] || fail "screenshot wrote outside evidence"
pass "screenshot did not write outside evidence"

# The scratch plist is not required until a folder has been chosen.
rm -f "$SCRATCH/home/Library/Preferences/me.peapod.umbilical.plist"
run_expect 4 "missing scratch plist before settings" run_harness doctor
assert_contains "$LAST_ERR" "Not worth driving." "missing scratch plist still reaches the platform limit"
plant_plist "$SCRATCH/home"
# After a settings write, the scratch plist is required.
python3 - "$STATE" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out = []
for line in lines:
    if line.startswith("settings_written="):
        out.append("settings_written=1")
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY
rm -f "$SCRATCH/home/Library/Preferences/me.peapod.umbilical.plist"
run_expect 1 "missing scratch plist after settings" run_harness doctor
assert_contains "$LAST_ERR" "scratch preferences plist is missing" "scratch plist message"
plant_plist "$SCRATCH/home"
python3 - "$STATE" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out = []
for line in lines:
    if line.startswith("settings_written="):
        out.append("settings_written=0")
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY

# Account plist hash mismatch fails and does not create the account file.
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "1"
run_expect 1 "account plist mismatch" run_harness doctor
assert_contains "$LAST_ERR" "account preferences plist" "account plist message"
[[ "$(prefs_fingerprint)" == "$PREFS_BEFORE" ]] || fail "account plist changed during mismatch test"
pass "account plist unchanged after mismatch"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"

# CFFIXED_USER_HOME is required, not just HOME.
kill -TERM "$PID" 2>/dev/null || true
sleep 0.2
nohup env HOME="$SCRATCH/home" "$APP_EXE" >/tmp/umb-holder.out 2>&1 &
PID="$!"
track "$PID"
sleep 0.3
LSTART="$(lstart_of "$PID")"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
run_expect 1 "missing CFFIXED_USER_HOME" run_harness doctor
assert_contains "$LAST_ERR" "CFFIXED_USER_HOME" "CFFIXED message"
kill -TERM "$PID" 2>/dev/null || true
sleep 0.2

# Restore a fully isolated holder for the remaining identity tests.
PID="$(start_holder "$APP_EXE" "$SCRATCH/home")"
CHILD="$(pgrep -P "$PID" || true)"
CHILD="${CHILD%%$'\n'*}"
LSTART="$(lstart_of "$PID")"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"

python3 - "$GOOD/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
info["CFBundleShortVersionString"] = "9.9.9"
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PY
run_expect 1 "doctor version mismatch" run_harness doctor
assert_contains "$LAST_ERR" "9.9.9" "version mismatch text"
python3 - "$GOOD/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
info["CFBundleShortVersionString"] = "1.0.2"
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PY

run_expect 1 "relaunch while alive" run_harness relaunch
assert_contains "$LAST_ERR" "still running" "relaunch alive text"
if ! kill -0 "$PID" 2>/dev/null; then
  fail "relaunch killed the live pid"
fi
pass "relaunch left the live pid"

# Unrelated pid and its child survive cleanup when identity does not match.
nohup bash -c 'sleep 240 & wait' >/tmp/unrelated.out 2>&1 &
UNRELATED="$!"
track "$UNRELATED"
sleep 0.3
UNRELATED_CHILD="$(pgrep -P "$UNRELATED" || true)"
UNRELATED_CHILD="${UNRELATED_CHILD%%$'\n'*}"
[[ -n "$UNRELATED_CHILD" ]] || fail "unrelated process has no child"
UNRELATED_LSTART="$(lstart_of "$UNRELATED")"
emit_state "$RUN_ID" "$UNRELATED" "$GOOD" "$SCRATCH" "1.0.2" "$UNRELATED_LSTART"
run_expect 1 "cleanup unrelated pid" run_harness cleanup
assert_contains "$LAST_ERR" "Signaled nothing" "cleanup mismatch message"
if ! kill -0 "$UNRELATED" 2>/dev/null; then
  fail "cleanup killed the unrelated pid"
fi
if ! kill -0 "$UNRELATED_CHILD" 2>/dev/null; then
  fail "cleanup killed the unrelated child"
fi
pass "unrelated pid and child survived cleanup"
# The recorded holder must also still be alive. Cleanup must not have guessed.
if ! kill -0 "$PID" 2>/dev/null; then
  fail "cleanup killed the real fixture while refusing the unrelated pid"
fi
pass "real fixture survived the refused cleanup"
[[ -d "$SCRATCH" ]] || fail "mismatch cleanup deleted scratch"
[[ -f "$STATE" ]] || fail "mismatch cleanup deleted state"
pass "mismatch cleanup left scratch and state"

# Start time mismatch also signals nothing.
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "Wed Jan 1 00:00:00 1970"
run_expect 1 "cleanup start time mismatch" run_harness cleanup
assert_contains "$LAST_ERR" "start time" "start time mismatch text"
assert_contains "$LAST_ERR" "Signaled nothing" "start time signaled nothing"
if ! kill -0 "$PID" 2>/dev/null; then
  fail "start time mismatch killed the fixture"
fi
if ! kill -0 "$CHILD" 2>/dev/null; then
  fail "start time mismatch killed the fixture child"
fi
pass "start time mismatch left the fixture and its child"
run_expect 1 "discard refuses a start time mismatch" run_harness cleanup --discard
assert_contains "$LAST_ERR" "Signaled nothing" "discard mismatch signaled nothing"
if ! kill -0 "$PID" 2>/dev/null; then
  fail "discard mismatch killed the fixture"
fi
[[ -f "$STATE" ]] || fail "discard mismatch removed the state file"
[[ -d "$SCRATCH" ]] || fail "discard mismatch removed the scratch directory"
pass "discard refused before an identity mismatch"

emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
kill -TERM "$PID" 2>/dev/null || true
sleep 0.2
run_expect 3 "relaunch on linux" run_harness relaunch
assert_contains "$LAST_ERR" "needs macOS" "relaunch platform message"
if pgrep -x umbilical >/dev/null; then
  fail "relaunch started a process"
fi
pass "relaunch started no process"

# Home and exe mismatches.
PID="$(start_holder "$APP_EXE" "/tmp")"
LSTART="$(lstart_of "$PID")"
# State home stays the scratch home, so HOME=/tmp mismatches.
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
run_expect 1 "doctor home mismatch" run_harness doctor
assert_contains "$LAST_ERR" "HOME is /tmp" "home mismatch text"
kill -TERM "$PID" 2>/dev/null || true
sleep 0.2

nohup env HOME="$SCRATCH/home" CFFIXED_USER_HOME="$SCRATCH/home" __CFPREFERENCES_AVOID_DAEMON=1 \
  /bin/sleep 120 >/tmp/umb-sleep.out 2>&1 &
PID="$!"
track "$PID"
sleep 0.2
LSTART="$(lstart_of "$PID")"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
run_expect 1 "doctor exe mismatch" run_harness doctor
assert_contains "$LAST_ERR" "executable is" "exe mismatch text"
kill -TERM "$PID" 2>/dev/null || true

emit_state "$RUN_ID" "999999" "$GOOD" "$SCRATCH" "1.0.2" "Wed Jan 1 00:00:00 1970"
if kill -0 999999 2>/dev/null; then
  fail "pid 999999 is alive"
fi
run_expect 1 "doctor dead pid" run_harness doctor
assert_contains "$LAST_ERR" "not running" "dead pid text"

PID="$(start_holder "$APP_EXE" "$SCRATCH/home")"
EXTRA="$(start_holder "$APP_EXE" "$SCRATCH/home")"
LSTART="$(lstart_of "$PID")"
emit_state "$RUN_ID" "$PID" "$GOOD" "$SCRATCH" "1.0.2" "$LSTART"
run_expect 1 "doctor second process" run_harness doctor
assert_contains "$LAST_ERR" "another process named umbilical" "second process text"
kill -TERM "$EXTRA" 2>/dev/null || true
sleep 0.2

# Matching cleanup kills the recorded pid and its child, and keeps evidence.
CHILD="$(pgrep -P "$PID" || true)"
CHILD="${CHILD%%$'\n'*}"
[[ -n "$CHILD" ]] || fail "recorded fixture lost its child"
run_expect 0 "cleanup recorded pid" run_harness cleanup
if kill -0 "$PID" 2>/dev/null; then
  fail "cleanup left the recorded pid"
fi
if kill -0 "$CHILD" 2>/dev/null; then
  fail "cleanup left the recorded child"
fi
pass "cleanup stopped the recorded pid and its child"
if kill -0 "$UNRELATED" 2>/dev/null; then
  pass "unrelated pid still alive after the matching cleanup"
else
  fail "matching cleanup killed the unrelated pid"
fi
if kill -0 "$UNRELATED_CHILD" 2>/dev/null; then
  pass "unrelated child still alive after the matching cleanup"
else
  fail "matching cleanup killed the unrelated child"
fi
[[ ! -d "$SCRATCH" ]] || fail "cleanup left scratch"
[[ ! -f "$STATE" ]] || fail "cleanup left state"
[[ -f "$EVIDENCE/kept.txt" ]] || fail "cleanup removed kept.txt"
grep -q "cleanup removed scratch" "$EVIDENCE/commands.log" || fail "commands.log missing cleanup line"
pass "cleanup kept evidence"

# Symlink scratch is not deleted.
RUN_LINK="$(date -u +%Y%m%dT%H%M%SZ)-bbccddee"
LINK_PARENT="$(mktemp -d /tmp/umbilical-verify.XXXXXX)"
chmod 700 "$LINK_PARENT"
LINK="$LINK_PARENT/scratch-${RUN_LINK}-abcdef"
ln -s /tmp/umbilical-verify-marker "$LINK"
mkdir -p /tmp/umbilical-verify-marker
printf 'marker\n' > /tmp/umbilical-verify-marker/marker
: >"$LINK_PARENT/account-$RUN_LINK.snap"
chmod 600 "$LINK_PARENT/account-$RUN_LINK.snap"
cat >"$STATE" <<EOF
run_id=$RUN_LINK
pid=999999
app_path=$GOOD
executable=$GOOD/Contents/MacOS/umbilical
home=$LINK/home
scratch=$LINK
downloads=$LINK/umbilical-verify-downloads
evidence=$EVIDENCE
version=1.0.2
server_pid=
lstart=Wed Jan 1 00:00:00 1970
prefs_sha=absent
prefs_mtime=absent
settings_written=0
handler_path=skipped
verify_parent=$LINK_PARENT
EOF
chmod 600 "$STATE"
run_expect 1 "cleanup refuses symlink" run_harness cleanup
assert_contains "$LAST_ERR" "symlink" "scratch symlink message"
[[ -f /tmp/umbilical-verify-marker/marker ]] || fail "cleanup followed the scratch symlink"
pass "cleanup did not follow the scratch symlink"
rm -f "$STATE"
rm -rf "$LINK_PARENT"

# Payload symlink and exact identity.
mkdir -p /tmp/payload-real-target
ln -s /tmp/payload-real-target /tmp/payload-link-dir
run_expect 1 "payload directory symlink" run_harness payload start --directory /tmp/payload-link-dir --name verify-payload.txt --body umbilical-verify-payload
assert_contains "$LAST_ERR" "symlink" "payload symlink message"
if [[ -e /tmp/payload-real-target/verify-umbilical-payload.py || -e /tmp/payload-real-target/www/verify-payload.txt ]]; then
  fail "payload start followed a directory symlink"
fi
pass "payload start did not follow a directory symlink"

mkdir -p /tmp/payload-real/www
printf 'SAFE\n' > /tmp/victim-payload
ln -s /tmp/victim-payload /tmp/payload-real/www/verify-payload.txt
run_expect 1 "payload file symlink" run_harness payload start --directory /tmp/payload-real --name verify-payload.txt --body CLOBBER
assert_contains "$LAST_ERR" "symlink" "payload file symlink message"
[[ "$(cat /tmp/victim-payload)" == "SAFE" ]] || fail "payload file symlink was overwritten"
pass "payload file symlink was not overwritten"
rm -f /tmp/payload-real/www/verify-payload.txt

PAYLOAD_DIR="/tmp/umbilical-payload-proof"
run_expect 0 "payload start" run_harness payload start --directory "$PAYLOAD_DIR" --name verify-payload.txt --body umbilical-verify-payload
PAYLOAD_URL="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^url=//p')"
PAYLOAD_PID="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^pid=//p')"
[[ "$PAYLOAD_URL" == http://127.0.0.1:*/verify-payload.txt ]] || fail "payload url $PAYLOAD_URL"
BODY="$(curl --fail --silent --show-error "$PAYLOAD_URL")"
[[ "$BODY" == "umbilical-verify-payload" ]] || fail "payload body [$BODY]"
pass "payload served the body"
PORT="${PAYLOAD_URL#http://127.0.0.1:}"
PORT="${PORT%%/*}"
python3 - "$PORT" <<'PY'
import sys
port = int(sys.argv[1])

def rows(path):
    found = []
    with open(path) as handle:
        for row in handle.read().splitlines()[1:]:
            local = row.split()[1]
            host, hexport = local.split(":")
            if int(hexport, 16) == port:
                found.append(host)
    return found

found = rows("/proc/net/tcp")
if not found or any(host != "0100007F" for host in found):
    raise SystemExit("tcp listeners %s" % found)
if rows("/proc/net/tcp6"):
    raise SystemExit("tcp6 listeners present")
PY
pass "payload listens on 127.0.0.1 only"

printf 'import time\ntime.sleep(180)\n' > /tmp/notes-about-verify-umbilical-payload.py
nohup python3 /tmp/notes-about-verify-umbilical-payload.py >/tmp/notes-payload.out 2>&1 &
NOTES_PID="$!"
track "$NOTES_PID"
sleep 0.2
run_expect 1 "payload stop refuses lookalike" run_harness payload stop --pid "$NOTES_PID"
assert_contains "$LAST_ERR" "Not killing it" "lookalike message"
if ! kill -0 "$NOTES_PID" 2>/dev/null; then
  fail "payload stop killed the lookalike pid"
fi
pass "lookalike pid still alive"
kill -TERM "$NOTES_PID" 2>/dev/null || true

run_expect 0 "payload stop" run_harness payload stop --pid "$PAYLOAD_PID"
if kill -0 "$PAYLOAD_PID" 2>/dev/null; then
  fail "payload server still running"
fi
pass "payload server stopped"

mkdir -p /private/tmp/umbilical-verify/payload-private
PRIVATE_PAYLOAD="/private/tmp/umbilical-verify/payload-private"
run_expect 0 "payload start under /private/tmp" run_harness payload start --directory "$PRIVATE_PAYLOAD" --name verify-payload.txt --body private-tmp
PRIVATE_PAYLOAD_PID="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^pid=//p')"
run_expect 0 "payload stop under /private/tmp" run_harness payload stop --pid "$PRIVATE_PAYLOAD_PID"
assert_absent "$LAST_ERR" "not a verify-umbilical payload server" "private tmp payload was ours"
pass "payload stop accepted /private/tmp"
rm -rf "$PRIVATE_PAYLOAD"

# python3 failure must not leave the inspect temp file.
BEFORE_TMP="$(find /tmp -maxdepth 1 -name 'tmp.*' -printf '%f\n' | sort)"
mkdir -p /tmp/badpy
cat > /tmp/badpy/python3 <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 /tmp/badpy/python3
PATH="/tmp/badpy:$PATH" run_expect 1 "inspect without python3" run_harness inspect-app --app "$GOOD"
assert_contains "$LAST_ERR" "could not read" "python failure message"
AFTER_TMP="$(find /tmp -maxdepth 1 -name 'tmp.*' -printf '%f\n' | sort)"
if [[ "$BEFORE_TMP" != "$AFTER_TMP" ]]; then
  fail "python failure left a temp file"
fi
pass "python failure left no temp file"

# shasum fallback, using the function from the harness.
awk '
  /^file_sha256\(\)/ { printing = 1 }
  printing { print }
  printing && /^}$/ { exit }
' "$HARNESS" > /tmp/sha-fn.sh
mkdir -p /tmp/sha-bin
cp "$(command -v awk)" /tmp/sha-bin/awk
REAL_SHA="$(command -v sha256sum)"
python3 - "$REAL_SHA" <<'PY'
import sys
path = sys.argv[1]
open("/tmp/sha-bin/shasum", "w").write(
    "#!/bin/sh\nfile=\"\"\nfor arg in \"$@\"; do\n  file=\"$arg\"\ndone\nexec %s \"$file\"\n" % path
)
PY
chmod 755 /tmp/sha-bin/shasum
SUM_OUT="$(PATH="/tmp/sha-bin" "$BASH32" -c 'set -euo pipefail; source /tmp/sha-fn.sh; die() { echo "die $*" >&2; exit 1; }; file_sha256 /etc/hostname')"
EXPECT_SUM="$(sha256sum /etc/hostname | awk '{ print $1 }')"
[[ "$SUM_OUT" == "$EXPECT_SUM" ]] || fail "shasum fallback produced $SUM_OUT"
pass "shasum fallback matches sha256sum"

# Symlinked grandparent must not escape /tmp.
rm -rf /var/tmp/u31-out /tmp/u31gp /var/tmp/u31-pay /tmp/paygp
mkdir -p /var/tmp/u31-out /var/tmp/u31-pay/sub
ln -s /var/tmp/u31-out /tmp/u31gp
ln -s /var/tmp/u31-pay /tmp/paygp
run_expect 1 "evidence symlink grandparent" run_harness launch --app "$GOOD" --evidence /tmp/u31gp/ev
assert_contains "$LAST_ERR" "evidence directory must stay under" "symlink evidence refusal"
[[ ! -e /var/tmp/u31-out/ev ]] || fail "evidence symlink escaped"
pass "evidence symlink stayed inside the guard"
run_expect 1 "payload symlink grandparent" run_harness payload start --directory /tmp/paygp/sub/payload --name verify-payload.txt --body hi
assert_contains "$LAST_ERR" "payload directory must stay under" "symlink payload refusal"
[[ ! -e /var/tmp/u31-pay/sub/payload ]] || fail "payload symlink escaped"
pass "payload symlink stayed inside the guard"
rm -f /tmp/u31gp /tmp/paygp
rm -rf /var/tmp/u31-out /var/tmp/u31-pay

mkdir -p /tmp/umb-payload-real
ln -sfn /tmp/umb-payload-real /tmp/link-to-parent
run_expect 0 "payload parent symlink under /tmp" run_harness payload start --directory /tmp/link-to-parent/child --name verify-payload.txt --body through-link
LINK_PAYLOAD_PID="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^pid=//p')"
[[ -f /tmp/umb-payload-real/child/www/verify-payload.txt ]] || fail "payload parent symlink was not resolved"
run_expect 0 "payload stop after parent symlink" run_harness payload stop --pid "$LINK_PAYLOAD_PID"
pass "payload start resolved a parent symlink under /tmp"
ln -sfn /var/tmp /tmp/link-outside
run_expect 1 "payload parent symlink leaves /tmp" run_harness payload start --directory /tmp/link-outside/umb-escaped --name verify-payload.txt --body hi
[[ ! -e /var/tmp/umb-escaped ]] || fail "payload parent symlink wrote outside /tmp"
pass "payload parent symlink outside /tmp wrote nothing"
rm -rf /tmp/umb-payload-real /tmp/link-to-parent
rm -f /tmp/link-outside

# Fake macOS layer. The real account home is never the target.
FAKE_HOME=/tmp/u31-home
export FAKE_HOME
export FAKE_APP_EXE="$GOOD/Contents/MacOS/umbilical"
rm -rf /tmp/fake-darwin "$FAKE_HOME" /tmp/fake-handler /tmp/fake-handler-flip /tmp/fake-open-second /tmp/fake-second-pid /tmp/open-was-called /tmp/fake-umb-fault-target
mkdir -p /tmp/fake-darwin
cat > /tmp/fake-darwin/uname <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-s" || $# -eq 0 ]]; then
  printf 'Darwin\n'
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
cat > /tmp/fake-darwin/dscl <<'EOF'
#!/bin/bash
printf 'NFSHomeDirectory: %s\n' "${FAKE_HOME:?}"
EOF
cat > /tmp/fake-darwin/codesign <<'EOF'
#!/bin/sh
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.get-task-allow</key>
<true/>
</dict></plist>
PLIST
EOF
cat > /tmp/fake-darwin/open <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/open-was-called
exit 1
EOF
cp "$SCRIPT_DIR/fake-osascript.sh" /tmp/fake-darwin/osascript
chmod 755 /tmp/fake-darwin/uname /tmp/fake-darwin/dscl /tmp/fake-darwin/codesign /tmp/fake-darwin/open /tmp/fake-darwin/osascript
printf '/Applications/Original.app\n' > /tmp/fake-handler

reset_fake_home() {
  chmod -R u+rwx "$FAKE_HOME" 2>/dev/null || true
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
}

# Unreadable account plist fails the snapshot before a process exists.
reset_fake_home
rm -f "$STATE"
mkdir -p "$FAKE_HOME/Library/Preferences"
printf 'locked' > "$FAKE_HOME/Library/Preferences/me.peapod.umbilical.plist"
chmod 000 "$FAKE_HOME/Library/Preferences/me.peapod.umbilical.plist"
parents_before="$(list_verify_parents)"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "unreadable account plist" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "could not hash" "unreadable plist message"
[[ ! -f "$STATE" ]] || fail "unreadable plist wrote state"
if pgrep -x umbilical >/dev/null; then
  fail "unreadable plist started a process"
fi
pass "unreadable plist started no process"
[[ "$(list_verify_parents)" == "$parents_before" ]] || fail "unreadable plist left a verification parent"
pass "unreadable plist removed its scratch dir"
chmod 644 "$FAKE_HOME/Library/Preferences/me.peapod.umbilical.plist" 2>/dev/null || true

# Start time is UTC0, so a later cleanup in another zone still matches.
reset_fake_home
rm -f "$STATE" /tmp/fake-umb-fault-target
PATH="/tmp/fake-darwin:$PATH" TZ=America/New_York run_expect 0 "launch under America/New_York" run_harness launch --app "$GOOD"
PATH="/tmp/fake-darwin:$PATH" TZ=Pacific/Auckland run_expect 0 "cleanup under Pacific/Auckland" run_harness cleanup
if pgrep -x umbilical >/dev/null; then
  fail "timezone cleanup left the app"
fi
pass "timezone cleanup removed the app"
[[ "$(list_verify_parents)" == "$parents_before" ]] || fail "timezone cleanup left a verification parent"
pass "timezone cleanup removed scratch"

# Every extra account path, a second pid, and a post-quit write.
reset_fake_home
rm -f "$STATE" /tmp/fake-handler-flip /tmp/fake-open-second /tmp/fake-second-pid /tmp/open-was-called /tmp/fake-deliver-nil /tmp/fake-deliver-fail /tmp/fake-handler-restore-fail
write_real_dscl() {
  cat > /tmp/fake-darwin/dscl <<EOF
#!/bin/bash
printf 'NFSHomeDirectory: %s\n' "${FAKE_HOME:?}"
EOF
  chmod 755 /tmp/fake-darwin/dscl
}
cat > /tmp/fake-darwin/dscl <<'EOF'
#!/bin/bash
exit 1
EOF
chmod 755 /tmp/fake-darwin/dscl
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "failing dscl refuses launch" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "could not resolve the account home" "failing dscl message"
if pgrep -x umbilical >/dev/null; then
  fail "failing dscl started a process"
fi
pass "failing dscl started no process"
cat > /tmp/fake-darwin/dscl <<'EOF'
#!/bin/bash
printf 'NFSHomeDirectory: relative/home\n'
EOF
chmod 755 /tmp/fake-darwin/dscl
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "relative home refuses launch" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "could not resolve the account home" "relative home message"
write_real_dscl
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch before dscl dies" run_harness launch --app "$GOOD"
cat > /tmp/fake-darwin/dscl <<'EOF'
#!/bin/bash
exit 1
EOF
chmod 755 /tmp/fake-darwin/dscl
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "doctor after dscl dies" run_harness doctor
assert_contains "$LAST_ERR" "could not resolve the account home" "doctor dscl message"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "cleanup after dscl dies" run_harness cleanup
assert_contains "$LAST_ERR" "could not resolve the account home" "cleanup dscl message"
assert_absent "$LAST_OUT" "cleaned" "dscl cleanup did not say cleaned"
assert_absent "$LAST_ERR" "cleaned" "dscl cleanup error did not say cleaned"
[[ -f "$STATE" ]] || fail "dscl cleanup removed the state file"
write_real_dscl
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after dscl returns" run_harness cleanup
[[ ! -f "$STATE" ]] || fail "dscl recovery left state"
pass "failing dscl keeps doctor and cleanup nonzero"

mkdir -p "$FAKE_HOME/Library/Caches/me.peapod.umbilical"
chmod 000 "$FAKE_HOME/Library/Caches/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "unreadable top dir refuses launch" run_harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "could not hash" "unreadable top dir message"
assert_absent "$LAST_ERR" "Traceback" "unreadable top dir has no traceback"
if pgrep -x umbilical >/dev/null; then
  fail "unreadable top dir started a process"
fi
[[ ! -f "$STATE" ]] || fail "unreadable top dir wrote state"
chmod 755 "$FAKE_HOME/Library/Caches/me.peapod.umbilical"
rm -rf "$FAKE_HOME/Library/Caches/me.peapod.umbilical"
pass "unreadable top dir started no process"

mkdir -p "$FAKE_HOME/Library/Application Support/me.peapod.umbilical/locked"
printf 'kept\n' > "$FAKE_HOME/Library/Application Support/me.peapod.umbilical/locked/file"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "fake darwin launch" run_harness launch --app "$GOOD"
grep -qx '/Applications/Original.app' "$EVIDENCE/launch/handler-before.txt" || fail "handler was not recorded before launch"
grep -q 'app=absent' "$EVIDENCE/launch/accessibility-host.txt" || fail "accessibility host did not record app=absent"
chmod 000 "$FAKE_HOME/Library/Application Support/me.peapod.umbilical/locked"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "mode 000 subdir" run_harness doctor
assert_contains "$LAST_ERR" "could not hash" "mode 000 message"
assert_absent "$LAST_ERR" "Traceback" "mode 000 has no traceback"
chmod 755 "$FAKE_HOME/Library/Application Support/me.peapod.umbilical/locked"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "mode 000 restored" run_harness doctor
pass "unreadable account entries fail closed"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after mode 000" run_harness cleanup
reset_fake_home
rm -f "$STATE"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch for path checks" run_harness launch --app "$GOOD"
check_one_path() {
  local rel="$1"
  local root="$2"
  mkdir -p "$FAKE_HOME/$(dirname "$rel")"
  if [[ "$rel" == "Library/Preferences/${BUNDLE_ID:-me.peapod.umbilical}.plist" || "$rel" == "Library/Preferences/me.peapod.umbilical.plist" ]]; then
    python3 - "$FAKE_HOME/$rel" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({}, handle)
PY
  else
    printf 'changed\n' > "$FAKE_HOME/$rel"
  fi
  run_expect 1 "path appeared $root" run_harness doctor
  assert_contains "$LAST_ERR" "$FAKE_HOME/$root" "path message $root"
  rm -rf "${FAKE_HOME:?}/${root:?}"
  run_expect 0 "path restored $root" run_harness doctor
}
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Preferences/me.peapod.umbilical.plist" "Library/Preferences/me.peapod.umbilical.plist"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Preferences/ByHost/me.peapod.umbilical.ABC.plist" "Library/Preferences/ByHost/me.peapod.umbilical.ABC.plist"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Saved Application State/me.peapod.umbilical.savedState/windows.plist" "Library/Saved Application State/me.peapod.umbilical.savedState"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Containers/me.peapod.umbilical/Data" "Library/Containers/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Group Containers/me.peapod.umbilical/x" "Library/Group Containers/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Group Containers/TEAM.me.peapod.umbilical/x" "Library/Group Containers/TEAM.me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Application Support/me.peapod.umbilical/x" "Library/Application Support/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/Caches/me.peapod.umbilical/x" "Library/Caches/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" check_one_path "Library/HTTPStorages/me.peapod.umbilical/x" "Library/HTTPStorages/me.peapod.umbilical"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "paths clear again" run_harness doctor

printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler-flip
rm -f /tmp/open-was-called
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "open-url restores handler" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
[[ ! -f /tmp/open-was-called ]] || fail "open-url called open"
grep -qx '/Applications/Original.app' "$EVIDENCE/open-url/handler-restored.txt" || fail "handler was not restored"
cmp "$EVIDENCE/launch/handler-before.txt" "$EVIDENCE/open-url/handler-before.txt" || fail "open-url reread the handler"
grep -qx '/Applications/Original.app' /tmp/fake-handler || fail "handler file was not restored"
pass "open-url restored the handler path without open"
rm -f /tmp/fake-handler-flip

touch /tmp/fake-deliver-nil
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "nil url delivery" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
assert_contains "$LAST_ERR" "could not deliver" "nil delivery message"
grep -qx '/Applications/Original.app' /tmp/fake-handler || fail "nil delivery moved the handler"
pass "nil url delivery failed"
rm -f /tmp/fake-deliver-nil

printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler-flip
touch /tmp/fake-deliver-fail
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "delivery failure restores handler" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
assert_contains "$LAST_ERR" "could not deliver" "delivery failure message"
grep -qx '/Applications/Original.app' /tmp/fake-handler || fail "delivery failure left the handler moved"
grep -qx '/Applications/Original.app' "$EVIDENCE/open-url/handler-restored.txt" || fail "delivery failure did not record the restore"
pass "delivery failure restored the handler"
rm -f /tmp/fake-handler-flip /tmp/fake-deliver-fail

touch /tmp/fake-open-second
rm -f /tmp/open-was-called /tmp/fake-second-pid
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "open-url second pid" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
[[ ! -f /tmp/open-was-called ]] || fail "second pid path called open"
assert_contains "$LAST_ERR" "second umbilical pid" "second pid message"
grep -q 'CFFIXED_USER_HOME=unset' "$EVIDENCE/open-url/second-pid-env.txt" || fail "second pid env was not recorded"
LIVE="$(pgrep -x umbilical || true)"
LIVE="${LIVE%%$'\n'*}"
[[ -n "$LIVE" ]] || fail "second pid check stopped the original"
pass "second pid left the original running"
if [[ -f /tmp/fake-second-pid ]] && kill -0 "$(cat /tmp/fake-second-pid)" 2>/dev/null; then
  fail "second pid is still running"
fi
pass "second pid was stopped"
rm -f /tmp/fake-open-second
printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler-flip
touch /tmp/fake-open-second /tmp/fake-handler-restore-fail
rm -f /tmp/fake-second-pid
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "second pid is recorded before a handler failure" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
assert_contains "$LAST_ERR" "could not restore" "handler failure still reports the restore"
grep -q '^pid=' "$EVIDENCE/open-url/second-pid.txt" || fail "handler failure skipped the second pid scan"
if [[ -f /tmp/fake-second-pid ]] && kill -0 "$(cat /tmp/fake-second-pid)" 2>/dev/null; then
  fail "handler failure left the second pid running"
fi
pass "second pid scan finished before the handler failure"
rm -f /tmp/fake-open-second /tmp/fake-handler-flip /tmp/fake-handler-restore-fail
printf '/Applications/Original.app\n' > /tmp/fake-handler

# A write that lands after quit must fail cleanup and keep the scratch.
PREFS_PATH="$FAKE_HOME/Library/Preferences/me.peapod.umbilical.plist"
mkdir -p "$(dirname "$PREFS_PATH")"
printf '%s\n' "$PREFS_PATH" > /tmp/fake-umb-fault-target
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "post-quit account write" run_harness cleanup
assert_contains "$LAST_ERR" "$PREFS_PATH" "post-quit path"
assert_absent "$LAST_OUT" "cleaned" "post-quit did not say cleaned"
assert_absent "$LAST_ERR" "cleaned" "post-quit error did not say cleaned"
[[ -f "$STATE" ]] || fail "post-quit removed the state file"
post_scratch="$(sed -n 's/^scratch=//p' "$STATE")"
[[ -d "$post_scratch" ]] || fail "post-quit removed scratch $post_scratch"
pass "post-quit kept state and scratch"
rm -f /tmp/fake-umb-fault-target "$PREFS_PATH"
printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup restores the handler" run_harness cleanup
grep -qx '/Applications/Original.app' /tmp/fake-handler || fail "cleanup left the handler moved"
grep -qx '/tmp/umb-fixtures/Umbilical.app' "$EVIDENCE/cleanup/handler-after.txt" || fail "cleanup did not record the moved handler"
grep -qx '/Applications/Original.app' "$EVIDENCE/cleanup/handler-restored.txt" || fail "cleanup did not record the restored handler"
[[ ! -f "$STATE" ]] || fail "final fake cleanup left state"
pass "cleanup restored the handler and matched the account home"

# A configured download folder records size, mtime, and a head and tail sample hash.
reset_fake_home
rm -f "$STATE"
DOWNLOADS=/tmp/u31-downloads
rm -rf "$DOWNLOADS"
mkdir -p "$DOWNLOADS"
printf 'marker\n' > "$DOWNLOADS/marker"
printf 'old\n' > "$DOWNLOADS/.DS_Store"
mkdir -p "$DOWNLOADS/child"
printf 'nested\n' > "$DOWNLOADS/child/keep"
truncate -s 2G "$DOWNLOADS/sparse"
python3 - "$FAKE_HOME" "$DOWNLOADS" <<'PY'
import json, os, plistlib, sys
home, folder = sys.argv[1], sys.argv[2]
path = os.path.join(home, "Library", "Preferences", "me.peapod.umbilical.plist")
os.makedirs(os.path.dirname(path), exist_ok=True)
payload = json.dumps({"downloadDirectoryPath": folder}).encode()
with open(path, "wb") as handle:
    plistlib.dump({"umb.settings": payload}, handle)
PY
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch with a recorded download folder" run_harness launch --app "$GOOD"
touch "$DOWNLOADS/.DS_Store"
DL_START="$(date +%s%N)"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "ds_store touch stays clean" run_harness doctor
DL_END="$(date +%s%N)"
DL_MS=$(( (DL_END - DL_START) / 1000000 ))
echo "download folder check took ${DL_MS}ms" | tee -a "$EVIDENCE/proof.log"
[[ "$DL_MS" -lt 2000 ]] || fail "download folder check took ${DL_MS}ms"
pass "download folder check took ${DL_MS}ms"
mkdir -p "$DOWNLOADS/child"
printf 'finder\n' > "$DOWNLOADS/child/.DS_Store"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "nested ds_store stays clean" run_harness doctor
cp -a "$DOWNLOADS/marker" "$PROOF_ROOT/marker.stamp"
touch "$DOWNLOADS/marker"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "download mtime change" run_harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/marker" "download mtime names the file"
cp -a "$PROOF_ROOT/marker.stamp" "$DOWNLOADS/marker"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "download mtime restored" run_harness doctor
printf 'XXXXXX\n' > "$DOWNLOADS/marker"
touch -r "$PROOF_ROOT/marker.stamp" "$DOWNLOADS/marker"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "same-size overwrite" run_harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/marker" "same-size overwrite names the file"
cp -a "$PROOF_ROOT/marker.stamp" "$DOWNLOADS/marker"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "same-size overwrite restored" run_harness doctor
printf 'appledouble\n' > "$DOWNLOADS/._old.zip"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "appledouble name" run_harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/._old.zip" "appledouble name"
rm -f "$DOWNLOADS/._old.zip"
printf 'inside\n' > "$DOWNLOADS/child/new"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "file inside a child folder" run_harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/child/new" "child file name"
rm -f "$DOWNLOADS/child/new"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "download folder restored" run_harness doctor
printf 'from-the-app\n' > "$DOWNLOADS/extra"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "new download name" run_harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/extra" "new download name"
rm -f "$DOWNLOADS/extra"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "removed download name" run_harness doctor
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after the new name is gone" run_harness cleanup
[[ ! -f "$STATE" ]] || fail "download cleanup left state"
pass "a removed download name lets cleanup finish"
rm -rf "$DOWNLOADS"

# Absent handler, restore failure, freeze-account, and discard.
reset_fake_home
rm -f "$STATE"
printf 'absent\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch with an absent handler" run_harness launch --app "$GOOD"
grep -qx 'absent' "$EVIDENCE/launch/handler-before.txt" || fail "absent handler was not recorded"
printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler-flip
rm -f "$EVIDENCE/open-url/handler-restored.txt" "$EVIDENCE/open-url/handler-after.txt"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "absent handler becomes an app" run_harness ui open-url --url "umbilical://download?url=https%3A%2F%2Fexample.com%2Ffile"
assert_contains "$LAST_ERR" "absent" "absent handler message"
assert_contains "$LAST_ERR" "/tmp/umb-fixtures/Umbilical.app" "absent handler names the new path"
if [[ -f "$EVIDENCE/open-url/handler-restored.txt" ]] && grep -qx 'unchanged' "$EVIDENCE/open-url/handler-restored.txt"; then
  fail "absent handler was reported unchanged"
fi
pass "absent to an app is a change"
rm -f /tmp/fake-handler-flip
printf 'absent\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup while the handler is absent again" run_harness cleanup

reset_fake_home
rm -f "$STATE"
DOWNLOADS=/tmp/u31-downloads
rm -rf "$DOWNLOADS"
mkdir -p "$DOWNLOADS"
python3 - "$FAKE_HOME" "$DOWNLOADS" <<'PY'
import json, os, plistlib, sys
home, folder = sys.argv[1], sys.argv[2]
path = os.path.join(home, "Library", "Preferences", "me.peapod.umbilical.plist")
os.makedirs(os.path.dirname(path), exist_ok=True)
payload = json.dumps({"downloadDirectoryPath": folder}).encode()
with open(path, "wb") as handle:
    plistlib.dump({"umb.settings": payload}, handle)
PY
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch for discard" run_harness launch --app "$GOOD"
printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler
touch /tmp/fake-handler-restore-fail
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "cleanup cannot restore the handler" run_harness cleanup
assert_contains "$LAST_ERR" "/Applications/Original.app" "restore failure names the recorded path"
assert_contains "$LAST_ERR" "/tmp/umb-fixtures/Umbilical.app" "restore failure names the current path"
assert_absent "$LAST_OUT" "cleaned" "restore failure did not say cleaned"
[[ -f "$STATE" ]] || fail "restore failure removed the state file"
[[ -f "$EVIDENCE/cleanup/account-after.txt" ]] || fail "handler failure did not write account-after"
[[ -f "$EVIDENCE/cleanup/handler-error.txt" ]] || fail "handler failure did not write handler-error"
pass "handler failure still wrote the account check"
rm -f /tmp/fake-handler-restore-fail
printf 'stuck\n' > "$DOWNLOADS/extra"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "cleanup still names the new file" run_harness cleanup
assert_contains "$LAST_ERR" "$DOWNLOADS/extra" "discard setup names the file"
RUN_FOR_FREEZE="$(sed -n 's/^run_id=//p' "$STATE")"
LIVE_PARENT="$(sed -n 's/^verify_parent=//p' "$STATE")"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "freeze-account refuses a live state file" run_harness freeze-account "$RUN_FOR_FREEZE"
assert_contains "$LAST_ERR" "does not re-baseline" "freeze-account refusal"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "freeze-account --state before the run id" run_harness freeze-account --state "$STATE" "$RUN_FOR_FREEZE"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "freeze-account --state after the run id" run_harness freeze-account "$RUN_FOR_FREEZE" --state "$STATE"
saved_state="$UMB_VERIFY_STATE"
parents_before="$(list_verify_parents)"
unset UMB_VERIFY_STATE
unset UMB_VERIFY_PARENT
PATH="/tmp/fake-darwin:$PATH" run_expect 2 "freeze-account without a parent" run_harness freeze-account "$RUN_FOR_FREEZE"
export UMB_VERIFY_STATE="$saved_state"
assert_contains "$LAST_ERR" "does not create a directory" "freeze-account creates nothing"
[[ "$(list_verify_parents)" == "$parents_before" ]] || fail "freeze-account created a parent"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "doctor still sees the new file" run_harness doctor
printf '/tmp/umb-fixtures/Umbilical.app\n' > /tmp/fake-handler
touch /tmp/fake-handler-restore-fail
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "cleanup discard after contamination" run_harness cleanup --discard
assert_contains "$LAST_ERR" "cleanup --discard removed the run" "discard failure message"
assert_contains "$LAST_ERR" "/Applications/Original.app" "discard names the recorded handler"
assert_contains "$LAST_ERR" "/tmp/umb-fixtures/Umbilical.app" "discard names the handler to fix"
assert_absent "$LAST_OUT" "discarded" "contaminated discard did not say discarded"
assert_absent "$LAST_OUT" "cleaned" "contaminated discard did not say cleaned"
[[ -f "$EVIDENCE/cleanup/account-after.txt" ]] || fail "discard did not write account-after"
[[ -f "$EVIDENCE/cleanup/account-diff.txt" ]] || fail "discard did not write account-diff"
grep -q "$DOWNLOADS/extra" "$EVIDENCE/cleanup/account-diff.txt" || fail "discard diff omitted the new file"
[[ ! -f "$STATE" ]] || fail "discard left the state file"
[[ ! -d "$LIVE_PARENT" ]] || fail "discard left the verification parent"
pass "cleanup discard records the mismatch and unlocks the run"
rm -f /tmp/fake-handler-restore-fail
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch after a failed discard" run_harness launch --app "$GOOD"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "clean discard" run_harness cleanup --discard
assert_contains "$LAST_OUT" "discarded" "clean discard output"
assert_absent "$LAST_OUT" "cleaned" "clean discard did not say cleaned"
[[ ! -f "$STATE" ]] || fail "clean discard left the state file"
pass "a later launch is not locked"
rm -rf "$DOWNLOADS"

# A directory symlink inside an account folder is part of the snapshot.
reset_fake_home
rm -f "$STATE"
mkdir -p "$FAKE_HOME/Library/Application Support/me.peapod.umbilical" /tmp/umb-link-a /tmp/umb-link-b
ln -s /tmp/umb-link-a "$FAKE_HOME/Library/Application Support/me.peapod.umbilical/linked"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch with a directory symlink" run_harness launch --app "$GOOD"
support_dir="$FAKE_HOME/Library/Application Support/me.peapod.umbilical"
support_mtime="$(python3 -c 'import os,sys; print(os.lstat(sys.argv[1]).st_mtime_ns)' "$support_dir")"
ln -sfn /tmp/umb-link-b "$support_dir/linked"
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "directory symlink retarget" run_harness doctor
assert_contains "$LAST_ERR" "$support_dir" "directory symlink message"
ln -sfn /tmp/umb-link-a "$support_dir/linked"
python3 -c 'import os,sys; os.utime(sys.argv[1], ns=(int(sys.argv[2]), int(sys.argv[2])))' "$support_dir" "$support_mtime"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "directory symlink restored" run_harness doctor
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after directory symlink" run_harness cleanup
pass "directory symlink targets are checked"

# A failing dscl during discard still leaves evidence and unlocks the run.
reset_fake_home
rm -f "$STATE"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch before discard dscl" run_harness launch --app "$GOOD"
DSCL_PARENT="$(sed -n 's/^verify_parent=//p' "$STATE")"
cat > /tmp/fake-darwin/dscl <<'EOF'
#!/bin/bash
exit 1
EOF
chmod 755 /tmp/fake-darwin/dscl
PATH="/tmp/fake-darwin:$PATH" run_expect 1 "discard while dscl fails" run_harness cleanup --discard
assert_contains "$LAST_ERR" "cleanup --discard removed the run" "dscl discard message"
assert_absent "$LAST_OUT" "discarded" "dscl discard did not say discarded"
[[ -f "$EVIDENCE/cleanup/account-error.txt" ]] || fail "dscl discard wrote no account error"
[[ ! -f "$STATE" ]] || fail "dscl discard left the state file"
write_real_dscl
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "launch after dscl discard" run_harness launch --app "$GOOD"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after dscl discard" run_harness cleanup
[[ ! -d "$DSCL_PARENT" ]] || fail "dscl discard left its parent"
pass "discard survives a failing dscl"

# The accessibility walk names the nearest bundle, not the shortest path.
reset_fake_home
rm -f "$STATE"
OUTER_ROOT="$(mktemp -d /tmp/umb-outer.XXXXXX)"
A_BASH="$OUTER_ROOT/A.app/Contents/MacOS/bash"
HELPER="$OUTER_ROOT/VeryLongApplicationName.app/Contents/Frameworks/Helper.app/Contents/MacOS/bash"
mkdir -p "$(dirname "$A_BASH")" "$(dirname "$HELPER")"
real_bash="$(readlink -f /bin/bash)"
cp -a "$real_bash" "$A_BASH"
cp -a "$real_bash" "$HELPER"
chmod 755 "$A_BASH" "$HELPER"
cat >"$OUTER_ROOT/run-nearest.sh" <<EOF
#!/bin/bash
"$HELPER" -c "\"$BASH32\" \"$HARNESS\" launch --app \"$GOOD\"; status=\\\$?; exit \\\$status"
status=\$?
exit \$status
EOF
chmod 755 "$OUTER_ROOT/run-nearest.sh"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" "$A_BASH" "$OUTER_ROOT/run-nearest.sh" >"$PROOF_ROOT/outer.out" 2>"$PROOF_ROOT/outer.err" || fail "nearest app launch failed: $(cat "$PROOF_ROOT/outer.err")"
app_bundle="$(sed -n 's/^app_bundle=//p' "$EVIDENCE/launch/accessibility-host.txt")"
[[ "$(basename "$app_bundle")" == "Helper.app" ]] || fail "nearest bundle was not recorded: $(cat "$EVIDENCE/launch/accessibility-host.txt")"
grep -q '/A.app/' "$EVIDENCE/launch/accessibility-host.txt" || fail "shorter ancestor was missing from the walk: $(cat "$EVIDENCE/launch/accessibility-host.txt")"
pass "accessibility host names the nearest app"
PATH="/tmp/fake-darwin:$PATH" run_expect 0 "cleanup after nearest app" run_harness cleanup
rm -rf "$OUTER_ROOT"

# mktemp may return the /private/tmp real path.
reset_fake_home
rm -f "$STATE"
mkdir -p /tmp/fake-mktemp /private/tmp
cat > /tmp/fake-mktemp/mktemp <<'EOF'
#!/bin/bash
template=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
  esac
  template="$arg"
done
base="$(basename "$template")"
suffix="$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
if [[ "$base" == "umbilical-verify.XXXXXX" ]]; then
  dir="/private/tmp/umbilical-verify.${suffix}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf '%s\n' "$dir"
  exit 0
fi
if [[ "$base" == scratch-*XXXXXX ]]; then
  dir="${template%XXXXXX}${suffix}"
  case "$dir" in
    /tmp/*) dir="/private/tmp/${dir#/tmp/}" ;;
  esac
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf '%s\n' "$dir"
  exit 0
fi
exec /usr/bin/mktemp "$@"
EOF
chmod 755 /tmp/fake-mktemp/mktemp
PATH="/tmp/fake-mktemp:/tmp/fake-darwin:$PATH" run_expect 0 "launch with /private/tmp scratch" run_harness launch --app "$GOOD"
PRIVATE_SCRATCH="$(sed -n 's/^scratch=//p' "$STATE")"
PRIVATE_PARENT="$(sed -n 's/^verify_parent=//p' "$STATE")"
[[ "$PRIVATE_PARENT" == /private/tmp/umbilical-verify.* ]] || fail "parent path $PRIVATE_PARENT"
[[ "$PRIVATE_SCRATCH" == "$PRIVATE_PARENT"/scratch-* ]] || fail "scratch path $PRIVATE_SCRATCH"
[[ -d "$PRIVATE_SCRATCH" ]] || fail "private scratch missing"
pass "launch accepted /private/tmp scratch"
PATH="/tmp/fake-mktemp:/tmp/fake-darwin:$PATH" run_expect 0 "cleanup /private/tmp scratch" run_harness cleanup
[[ ! -d "$PRIVATE_SCRATCH" ]] || fail "private scratch remained"
pass "cleanup removed /private/tmp scratch"

if [[ "$(prefs_fingerprint)" != "$PREFS_BEFORE" ]]; then
  fail "account preferences plist changed during the proof"
fi
pass "account preferences plist unchanged"
[[ -f "$EVIDENCE/kept.txt" && -f "$EVIDENCE/commands.log" && -f "$EVIDENCE/proof.log" ]] || fail "evidence missing"
pass "evidence still present"
echo "PROOF GREEN" | tee -a "$EVIDENCE/proof.log"

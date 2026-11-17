#!/usr/bin/env bash
# Round-6 regressions for verify-umbilical. Run from any directory.
# The harness runs under the same bash that executes this script.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR/verify-umbilical"
CHECK="$SCRIPT_DIR/check-handler-call.py"
STUB="$SCRIPT_DIR/fake-osascript.sh"
WORK="$(mktemp -d /tmp/umb-regress.XXXXXX)"
EVIDENCE="$WORK/evidence"
LOG="$WORK/regress.log"
FAKE_HOME="$WORK/home"
GOOD="$WORK/Umbilical.app"
DOWNLOADS="$WORK/downloads"
mkdir -p "$EVIDENCE"
: >"$LOG"

pass() { echo "PASS: $*" | tee -a "$LOG"; }
fail() { echo "FAIL: $*" | tee -a "$LOG" >&2; exit 1; }

copy_log() {
  local ver="${BASH_VERSION%%\(*}"
  local dest="/opt/cursor/artifacts/verify-umbilical/regress-bash-${ver}.log"
  mkdir -p /opt/cursor/artifacts/verify-umbilical 2>/dev/null || true
  cp -f "$LOG" "$dest" 2>/dev/null || true
  cp -f "$LOG" "/tmp/regress-bash-${ver}.log" 2>/dev/null || true
}
stop_apps() {
  local pid child
  if pgrep -x umbilical >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      if pgrep -P "$pid" >/dev/null 2>&1; then
        while IFS= read -r child; do
          [[ -z "$child" ]] && continue
          kill -TERM "$child" 2>/dev/null || true
        done < <(pgrep -P "$pid" || true)
      fi
      kill -TERM "$pid" 2>/dev/null || true
    done < <(pgrep -x umbilical || true)
  fi
}
trap 'stop_apps; copy_log' EXIT

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
    } >>"$LOG"
    rm -f "$out" "$err"
    fail "$label wanted exit $want, got $status"
  fi
  LAST_OUT="$(cat "$out")"
  LAST_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  pass "$label (exit $status)"
}

assert_contains() {
  local hay="$1" needle="$2" label="$3"
  [[ "$hay" == *"$needle"* ]] || fail "$label missing [$needle] in [$hay]"
  pass "$label"
}

parents() {
  local root entry
  for root in /tmp /private/tmp; do
    [[ -d "$root" ]] || continue
    for entry in "$root"/umbilical-verify.*; do
      if [[ -e "$entry" || -L "$entry" ]]; then
        printf '%s\n' "$entry"
      fi
    done
  done | LC_ALL=C sort
}

stamp_of() {
  stat -c '%a %s' "$1"
  sha256sum "$1" | awk '{ print $1 }'
}

harness() {
  "$BASH" "$HARNESS" "$@"
}

echo "regress bash $BASH_VERSION work $WORK" | tee -a "$LOG"

python3 "$CHECK" "$HARNESS" "$SCRIPT_DIR/restore-handler.swift" | tee -a "$LOG"
call_tmp="$(mktemp)"
printf '%s\n' '// setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler(appURL, "umbilical", function(error) {})' >"$call_tmp"
python3 "$CHECK" "$call_tmp" && fail "a comment was accepted as the handler call"
printf '%s\n' 'var name = "setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler";' >"$call_tmp"
python3 "$CHECK" "$call_tmp" && fail "a string was accepted as the handler call"
printf '%s\n' '$.NSWorkspace.sharedWorkspace.setDefaultApplicationAtURLToOpenURLsWithSchemeError(appURL, "umbilical", function(error) {});' >"$call_tmp"
python3 "$CHECK" "$call_tmp" && fail "the old error selector was accepted"
rm -f "$call_tmp"
mutate_call() {
  local label="$1"
  local which="$2"
  local old="$3"
  local new="$4"
  local copy swift
  copy="$(mktemp)"
  swift="$(mktemp)"
  mv "$swift" "$swift.swift"
  swift="$swift.swift"
  cp "$HARNESS" "$copy"
  cp "$SCRIPT_DIR/restore-handler.swift" "$swift"
  python3 - "$which" "$copy" "$swift" "$old" "$new" <<'PY' || fail "could not apply $label"
import pathlib, sys
which, harness, swift, old, new = sys.argv[1:]
path = pathlib.Path(harness if which == "harness" else swift)
text = path.read_text()
if old not in text:
    raise SystemExit(2)
path.write_text(text.replace(old, new, 1))
PY
  python3 "$CHECK" "$copy" "$swift" && fail "$label was accepted"
  rm -f "$copy" "$swift"
  pass "$label is rejected"
}
mutate_call "M2 receiver" harness ".sharedWorkspace.setDefaultApplicationAtURL" ".setDefaultApplicationAtURL"
mutate_call "M3 extra argument" harness 'appURL, "umbilical", function' 'appURL, "umbilical", "extra", function'
mutate_call "M5 lookup name" harness "URLForApplicationToOpenURL(" "URLForApplicationToOpenURLX("
mutate_call "M6 delivery name" harness "sendWithOptionsTimeoutError(" "sendWithOptionsTimeout("
pass "handler call is parsed"
awk '/^die\(\)/,/^}/' "$HARNESS" | grep -q 'remove_scratch_dir' || fail "die does not use remove_scratch_dir"
awk '/^die\(\)/,/^}/' "$HARNESS" | grep -q 'rm -rf' && fail "die still uses rm -rf"
grep -q 'xcode-select -p' "$HARNESS" || fail "swift helper does not check xcode-select"
grep -q 'module-cache-path' "$HARNESS" || fail "swift helper does not set a module cache"
grep -q 'semaphore.wait(timeout:' "$SCRIPT_DIR/restore-handler.swift" || fail "swift helper does not wait with a timeout"
pass "die and the swift helper stay inside the run"
grep -E -n 'umbilical-verify-state|\.tmp\.\$\$' "$HARNESS" && fail "shared state path or predictable temp is still in the harness"
pass "harness has no shared state path"

# Planted symlinks are refused before a parent or a victim write.
VICTIM="$WORK/victim"
printf 'SAFE\n' >"$VICTIM"
chmod 644 "$VICTIM"
VICTIM_STAMP="$(stamp_of "$VICTIM")"
before="$(parents)"

linkdir="$WORK/state-link"
mkdir -p "$WORK/state-real"
chmod 700 "$WORK/state-real"
ln -s "$WORK/state-real" "$linkdir"
run_expect 1 "symlink state directory" \
  harness launch --app /tmp/not-an-app --state "$linkdir/state.env" --evidence "$EVIDENCE"
assert_contains "$LAST_ERR" "symlink" "symlink state directory message"
[[ ! -e "$WORK/state-real/state.env" ]] || fail "symlink state directory was followed"
[[ "$(parents)" == "$before" ]] || fail "symlink state directory created a parent"
[[ "$(stamp_of "$VICTIM")" == "$VICTIM_STAMP" ]] || fail "symlink state directory wrote the victim"

filedir="$WORK/state-file"
mkdir -p "$filedir"
chmod 700 "$filedir"
ln -s "$VICTIM" "$filedir/state.env"
run_expect 1 "symlink state file" \
  harness launch --app /tmp/not-an-app --state "$filedir/state.env" --evidence "$EVIDENCE"
assert_contains "$LAST_ERR" "symlink" "symlink state file message"
[[ -L "$filedir/state.env" ]] || fail "symlink state file was replaced"
[[ "$(parents)" == "$before" ]] || fail "symlink state file created a parent"
[[ "$(stamp_of "$VICTIM")" == "$VICTIM_STAMP" ]] || fail "symlink state file wrote the victim"

tempdir="$WORK/state-temp"
mkdir -p "$tempdir"
chmod 700 "$tempdir"
ln -s "$VICTIM" "$tempdir/state.env.tmp.$$"
ln -s "$VICTIM" "$tempdir/state.AAAAAA"
pid_cursor=$$
pid_end=$((pid_cursor + 30))
while [[ "$pid_cursor" -le "$pid_end" ]]; do
  ln -sfn "$VICTIM" "$tempdir/state.env.tmp.$pid_cursor"
  pid_cursor=$((pid_cursor + 1))
done
run_expect 1 "symlink state temp" \
  harness launch --app /tmp/not-an-app --state "$tempdir/state.env" --evidence "$EVIDENCE"
assert_contains "$LAST_ERR" "symlink" "symlink state temp message"
[[ ! -e "$tempdir/state.env" ]] || fail "temp symlink still produced a state file"
[[ "$(parents)" == "$before" ]] || fail "temp symlink created a parent"
[[ "$(stamp_of "$VICTIM")" == "$VICTIM_STAMP" ]] || fail "temp symlink wrote the victim"
pass "planted state symlinks wrote nothing outside"

unset UMB_VERIFY_STATE
unset UMB_VERIFY_PARENT
run_expect 2 "freeze-account without a parent" \
  harness freeze-account 20260101T000000Z-abcdef01
assert_contains "$LAST_ERR" "does not create a directory" "freeze-account creates nothing"
[[ "$(parents)" == "$before" ]] || fail "freeze-account created a parent"
pass "freeze-account left no directory"

# Fake Darwin. The real account home is never touched.
export FAKE_HOME
export FAKE_APP_EXE="$GOOD/Contents/MacOS/umbilical"
rm -rf /tmp/fake-darwin
mkdir -p /tmp/fake-darwin "$FAKE_HOME"
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
cp "$STUB" /tmp/fake-darwin/osascript
chmod 755 /tmp/fake-darwin/uname /tmp/fake-darwin/dscl /tmp/fake-darwin/codesign /tmp/fake-darwin/open /tmp/fake-darwin/osascript
cc -o "$WORK/umb-holder" "$SCRIPT_DIR/holder.c" || fail "could not build the holder"
rm -rf "$GOOD"
mkdir -p "$GOOD/Contents/MacOS"
cp -a "$WORK/umb-holder" "$GOOD/Contents/MacOS/umbilical"
chmod 755 "$GOOD/Contents/MacOS/umbilical"
python3 - "$GOOD/Contents/Info.plist" <<'PY'
import plistlib, sys
info = {
    "CFBundleIdentifier": "me.peapod.umbilical",
    "CFBundleExecutable": "umbilical",
    "CFBundleShortVersionString": "1.0.2",
}
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(info, handle)
PY
printf '/Applications/Original.app\n' > /tmp/fake-handler
export PATH="/tmp/fake-darwin:$PATH"

STATE="$WORK/explicit-state/state.env"
mkdir -p "$(dirname "$STATE")"
chmod 700 "$(dirname "$STATE")"
export UMB_VERIFY_EVIDENCE="$EVIDENCE"
export UMB_VERIFY_STATE="$STATE"
run_expect 0 "launch writes a regular state file" harness launch --app "$GOOD"
state_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^state=//p')"
parent_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^verify_parent=//p')"
[[ "$state_line" == "$STATE" ]] || fail "explicit state was not printed: $LAST_OUT"
[[ -f "$STATE" && ! -L "$STATE" ]] || fail "state file is not a regular file"
[[ "$(stat -c '%a' "$STATE")" == "600" ]] || fail "state file mode is not 600"
[[ "$(stamp_of "$VICTIM")" == "$VICTIM_STAMP" ]] || fail "successful write changed the victim"
run_expect 0 "cleanup after explicit state" harness cleanup
[[ ! -d "$parent_line" ]] || fail "cleanup left the verification parent"
pass "explicit state write did not follow a symlink"

rm -f "$STATE"
unset UMB_VERIFY_STATE
shared_before=0
[[ -e /tmp/umbilical-verify-state || -L /tmp/umbilical-verify-state ]] && shared_before=1
run_expect 0 "launch keeps state inside the parent" harness launch --app "$GOOD"
state_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^state=//p')"
parent_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^verify_parent=//p')"
[[ "$state_line" == "$parent_line/state.env" ]] || fail "default state is not inside the parent: $state_line"
[[ -f "$state_line" && ! -L "$state_line" ]] || fail "default state file is not regular"
if [[ "$shared_before" == "0" ]]; then
  [[ ! -e /tmp/umbilical-verify-state && ! -L /tmp/umbilical-verify-state ]] || fail "launch created /tmp/umbilical-verify-state"
fi
run_expect 0 "cleanup finds the only state file" harness cleanup
assert_contains "$LAST_OUT" "cleaned" "single state cleanup text"
if pgrep -x umbilical >/dev/null 2>&1; then
  fail "single state cleanup left the app"
fi
[[ ! -d "$parent_line" ]] || fail "single state cleanup left the parent"
run_expect 0 "second launch for two state files" harness launch --app "$GOOD"
state_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^state=//p')"
parent_line="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^verify_parent=//p')"
decoy="$(mktemp -d /tmp/umbilical-verify.XXXXXX)"
chmod 700 "$decoy"
printf 'other\n' > "$decoy/state.env"
chmod 600 "$decoy/state.env"
run_expect 1 "cleanup refuses two state files" harness cleanup
assert_contains "$LAST_ERR" "$state_line" "names the live state"
assert_contains "$LAST_ERR" "$decoy/state.env" "names the other state"
if printf '%s\n' "$LAST_OUT" | grep -q "nothing to clean"; then
  fail "two states said nothing to clean"
fi
if ! pgrep -x umbilical >/dev/null 2>&1; then
  fail "two-state cleanup stopped the app"
fi
rm -rf "$decoy"
run_expect 0 "cleanup after the extra state is gone" harness cleanup
[[ ! -d "$parent_line" ]] || fail "cleanup left the parent after the extra state"
export UMB_VERIFY_STATE="$STATE"

printf '%s\n' "$GOOD" > /tmp/fake-handler
before="$(parents)"
run_expect 1 "handler already points at this build" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already opens this verification build" "self handler message"
assert_contains "$LAST_ERR" "was not started" "self handler did not start"
if pgrep -x umbilical >/dev/null 2>&1; then
  fail "self handler started a process"
fi
[[ "$(parents)" == "$before" ]] || fail "self handler left a parent"
[[ ! -f "$STATE" ]] || fail "self handler wrote a state file"
printf '%s/\n' "$GOOD" > /tmp/fake-handler
run_expect 1 "handler trailing slash" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already opens this verification build" "trailing slash message"
printf '%s/./Umbilical.app\n' "$WORK" > /tmp/fake-handler
run_expect 1 "handler dot slash" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already opens this verification build" "dot slash message"
ln -s "$GOOD" "$WORK/link.app"
printf '%s\n' "$WORK/link.app" > /tmp/fake-handler
run_expect 1 "handler symlink" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already opens this verification build" "symlink handler message"
mkdir -p /private/tmp/umb-j2-target
ln -sfn "$GOOD" /private/tmp/umb-j2-target/Umbilical.app
ln -sfn /private/tmp/umb-j2-target /tmp/umb-j2-link
printf '/private/tmp/umb-j2-target/Umbilical.app\n' > /tmp/fake-handler
run_expect 1 "handler private tmp form" harness launch --app /tmp/umb-j2-link/Umbilical.app
assert_contains "$LAST_ERR" "already opens this verification build" "private tmp message"
rm -rf "$WORK/Copy.app"
cp -a "$GOOD" "$WORK/Copy.app"
printf '%s\n' "$WORK/Copy.app" > /tmp/fake-handler
run_expect 1 "handler is a copy of this build" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "already opens this verification build" "copy message"
printf '/tmp/foo/../Original.app\n' > /tmp/fake-handler
before="$(parents)"
run_expect 1 "handler path with dotdot" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "not usable" "dotdot handler message"
[[ "$(parents)" == "$before" ]] || fail "dotdot handler left a parent"
if pgrep -x umbilical >/dev/null 2>&1; then
  fail "dotdot handler started a process"
fi
printf '/Applications/Original.app\n' > /tmp/fake-handler
rm -rf /tmp/umb-j2-link /private/tmp/umb-j2-target "$WORK/link.app" "$WORK/Copy.app"
pass "a discarded build cannot become the next baseline"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/mktemp" <<'EOF'
#!/bin/bash
template=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
  esac
  template="$arg"
done
base="$(basename "$template")"
if [[ "$base" == scratch-* ]]; then
  exit 1
fi
exec /usr/bin/mktemp "$@"
EOF
chmod 755 "$WORK/bin/mktemp"
before="$(parents)"
PATH="$WORK/bin:/tmp/fake-darwin:$PATH" run_expect 1 "scratch mktemp failure" harness launch --app "$GOOD"
assert_contains "$LAST_ERR" "could not create the scratch directory" "scratch failure message"
[[ "$(parents)" == "$before" ]] || fail "scratch failure left a parent: $(parents)"
pass "early launch failure left no parent"
export PATH="/tmp/fake-darwin:$PATH"

rm -f "$STATE"
printf '/Applications/Original.app\n' > /tmp/fake-handler
run_expect 0 "launch before a late restore" harness launch --app "$GOOD"
printf '%s\n' "$GOOD" > /tmp/fake-handler
touch /tmp/fake-handler-late
run_expect 0 "late handler restore is reread" harness cleanup
grep -qx '/Applications/Original.app' /tmp/fake-handler || fail "late restore did not write the recorded path"
rm -f /tmp/fake-handler-late
pass "a late restore is not reported as a failure"

rm -f "$STATE"
printf '/Applications/Original.app\n' > /tmp/fake-handler
run_expect 0 "launch before a failed restore" harness launch --app "$GOOD"
printf '%s\n' "$GOOD" > /tmp/fake-handler
touch /tmp/fake-handler-restore-fail
run_expect 1 "failed restore names the current handler" harness cleanup
assert_contains "$LAST_ERR" "It is $GOOD" "failed restore names the reread path"
assert_contains "$LAST_ERR" "/Applications/Original.app" "failed restore names the recorded path"
[[ -f "$STATE" ]] || fail "failed restore removed the state file"
rm -f /tmp/fake-handler-restore-fail
printf '/Applications/Original.app\n' > /tmp/fake-handler
run_expect 0 "discard after the failed restore" harness cleanup --discard

rm -rf "$DOWNLOADS"
mkdir -p "$DOWNLOADS"
python3 - "$DOWNLOADS" "$FAKE_HOME" <<'PY'
import os, plistlib, sys
folder, home = sys.argv[1], sys.argv[2]
marker = os.path.join(folder, "marker")
with open(marker, "w", encoding="utf-8") as handle:
    handle.write("marker\n")
wide = os.path.join(folder, "wide")
fd = os.open(wide, os.O_CREAT | os.O_WRONLY, 0o644)
os.ftruncate(fd, 2 * 1024 * 1024)
os.close(fd)
os.mkfifo(os.path.join(folder, "pipe"))
for index in range(50000):
    path = os.path.join(folder, "f%05d" % index)
    fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o644)
    os.write(fd, b"x")
    os.close(fd)
prefs = os.path.join(home, "Library", "Preferences", "me.peapod.umbilical.plist")
os.makedirs(os.path.dirname(prefs), exist_ok=True)
payload = ('{"downloadDirectoryPath":"%s"}' % folder).encode()
with open(prefs, "wb") as handle:
    plistlib.dump({"umb.settings": payload}, handle)
PY
cp -a "$DOWNLOADS/marker" "$WORK/marker.stamp"
printf '/Applications/Original.app\n' > /tmp/fake-handler
run_expect 0 "launch with 50000 download files" timeout 60 "$BASH" "$HARNESS" launch --app "$GOOD"
start_ns="$(date +%s%N)"
run_expect 0 "doctor walks 50000 files" harness doctor
end_ns="$(date +%s%N)"
doctor_ms=$(( (end_ns - start_ns) / 1000000 ))
echo "doctor at 50000 files took ${doctor_ms}ms" | tee -a "$LOG"
[[ "$doctor_ms" -lt 2000 ]] || fail "doctor at 50000 files took ${doctor_ms}ms"
printf 'XXXXXX\n' > "$DOWNLOADS/marker"
touch -r "$WORK/marker.stamp" "$DOWNLOADS/marker"
run_expect 1 "same-size overwrite" harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/marker" "same-size overwrite names the file"
cp -a "$WORK/marker.stamp" "$DOWNLOADS/marker"
run_expect 0 "same-size overwrite restored" harness doctor
cp -a "$DOWNLOADS/wide" "$WORK/wide.stamp"
python3 - "$DOWNLOADS/wide" <<'PY'
import sys
with open(sys.argv[1], "r+b") as handle:
    handle.seek(1024 * 1024)
    handle.write(b"Z")
PY
touch -r "$WORK/wide.stamp" "$DOWNLOADS/wide"
run_expect 1 "mid-file edit past 128KiB" harness doctor
assert_contains "$LAST_ERR" "$DOWNLOADS/wide" "mid-file edit names the file"
cp -a "$WORK/wide.stamp" "$DOWNLOADS/wide"
run_expect 0 "mid-file edit restored" harness doctor
run_expect 0 "cleanup after the download walk" harness cleanup

rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
rm -f "$STATE"
OUTER="$WORK/outer"
A_BASH="$OUTER/A.app/Contents/MacOS/bash"
HELPER="$OUTER/VeryLongApplicationName.app/Contents/Frameworks/Helper.app/Contents/MacOS/bash"
mkdir -p "$(dirname "$A_BASH")" "$(dirname "$HELPER")"
real_bash="$(readlink -f /bin/bash)"
cp -a "$real_bash" "$A_BASH"
cp -a "$real_bash" "$HELPER"
chmod 755 "$A_BASH" "$HELPER"
cat >"$OUTER/run-nearest.sh" <<EOF
#!/bin/bash
"$HELPER" -c "\"$BASH\" \"$HARNESS\" launch --app \"$GOOD\"; status=\\\$?; exit \\\$status"
status=\$?
exit \$status
EOF
chmod 755 "$OUTER/run-nearest.sh"
printf '/Applications/Original.app\n' > /tmp/fake-handler
PATH="/tmp/fake-darwin:$PATH" "$A_BASH" "$OUTER/run-nearest.sh" >"$WORK/nearest.out" 2>"$WORK/nearest.err" || fail "nearest app launch failed: $(cat "$WORK/nearest.err")"
app_bundle="$(sed -n 's/^app_bundle=//p' "$EVIDENCE/launch/accessibility-host.txt")"
[[ "$(basename "$app_bundle")" == "VeryLongApplicationName.app" ]] || fail "outer bundle was not recorded: $(cat "$EVIDENCE/launch/accessibility-host.txt")"
grep -q '/Helper.app/' "$EVIDENCE/launch/accessibility-host.txt" || fail "inner helper missing: $(cat "$EVIDENCE/launch/accessibility-host.txt")"
grep -q '/A.app/' "$EVIDENCE/launch/accessibility-host.txt" || fail "shorter ancestor missing: $(cat "$EVIDENCE/launch/accessibility-host.txt")"
pass "outer bundle of the nearest process"
run_expect 0 "cleanup after nearest app" harness cleanup

echo "REGRESS GREEN bash $BASH_VERSION" | tee -a "$LOG"

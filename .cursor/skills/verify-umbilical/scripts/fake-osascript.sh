#!/bin/bash
# Stub for the Linux proof. It accepts only the exact handler call the harness sends.
# A handler call inside an AppleScript tell block must be prefixed with "my".
set -eu
if [[ -z "${UMB_FAKE_DIR:-}" ]]; then
  echo "UMB_FAKE_DIR is not set" >&2
  exit 1
fi
mkdir -p "$UMB_FAKE_DIR"

script_rejects_bare_handler() {
  local script="$1"
  [[ -f "$script" ]] || return 0
  python3 - "$script" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
depth = 0
handlers = ("collectLines", "lineFor", "clickIn", "writeIn", "readIn")
call = re.compile(r"(?<!my )(?<![\w.])(?:%s)\(" % "|".join(handlers))
for raw in text.splitlines():
    line = raw.split("--", 1)[0]
    stripped = line.strip()
    if re.match(r"tell\b", stripped):
        depth += 1
    if depth > 0 and call.search(line):
        sys.exit(1)
    if re.match(r"end tell\b", stripped) and depth:
        depth -= 1
sys.exit(0)
PY
}

for arg in "$@"; do
  case "$arg" in
    *.applescript)
      if ! script_rejects_bare_handler "$arg"; then
        echo "handler call inside tell is missing my" >&2
        exit 1
      fi
      ;;
  esac
done

script=""
if [[ "${1:-}" == "-l" ]]; then
  script="$(cat)"
fi
if printf '%s\n' "$script" | grep -F -q 'sharedWorkspace.URLForApplicationToOpenURL('; then
  if [[ -f "$UMB_FAKE_DIR/fake-handler" ]]; then
    cat "$UMB_FAKE_DIR/fake-handler"
  else
    printf 'absent\n'
  fi
  exit 0
fi
if printf '%s\n' "$script" | grep -F -q 'setDefaultApplicationAtURLToOpenURLsWithSchemeError'; then
  exit 1
fi
if printf '%s\n' "$script" | grep -F -q 'sharedWorkspace.setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler(appURL, "umbilical", function'; then
  if [[ -f "$UMB_FAKE_DIR/fake-handler-late" ]]; then
    printf '%s\n' "$4" > "$UMB_FAKE_DIR/fake-handler"
    exit 1
  fi
  if [[ -f "$UMB_FAKE_DIR/fake-handler-restore-fail" ]]; then
    exit 1
  fi
  printf '%s\n' "$4" > "$UMB_FAKE_DIR/fake-handler"
  printf 'restored\n'
  exit 0
fi
if printf '%s\n' "$script" | grep -F -q 'sendWithOptionsTimeoutError('; then
  if [[ -f "$UMB_FAKE_DIR/fake-deliver-nil" ]]; then
    if printf '%s\n' "$script" | grep -q "returned nil"; then
      exit 1
    fi
    printf 'sent\n'
    exit 0
  fi
  if [[ -f "$UMB_FAKE_DIR/fake-handler-flip" ]]; then
    cat "$UMB_FAKE_DIR/fake-handler-flip" > "$UMB_FAKE_DIR/fake-handler"
  fi
  if [[ -f "$UMB_FAKE_DIR/fake-deliver-fail" ]]; then
    exit 1
  fi
  if [[ -f "$UMB_FAKE_DIR/fake-open-second" ]]; then
    nohup "$FAKE_APP_EXE" >"$UMB_FAKE_DIR/fake-second.out" 2>&1 &
    printf '%s\n' "$!" > "$UMB_FAKE_DIR/fake-second-pid"
  fi
  printf 'sent\n'
  exit 0
fi
cmd=""
for arg in "$@"; do
  case "$arg" in
    read-text|quit-pid|screenshot) cmd="$arg" ;;
  esac
done
if [[ "$cmd" == "quit-pid" ]]; then
  kill -TERM "${@: -1}" 2>/dev/null || true
  printf 'quit\n'
  exit 0
fi
if [[ "$cmd" == "read-text" ]]; then
  printf '%s\n' "Choose a download folder" "Unofficial build. License checks are off." "Add Download"
  exit 0
fi
if [[ "$cmd" == "screenshot" ]]; then
  printf 'png' > "${@: -1}"
  printf 'shot\n'
  exit 0
fi
printf 'unhandled %s\n' "$*" >> "$UMB_FAKE_DIR/osascript.log"
exit 1

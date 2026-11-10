#!/bin/bash
# Stub for the Linux proof. It accepts only the exact handler call the harness sends.
script=""
if [[ "${1:-}" == "-l" ]]; then
  script="$(cat)"
fi
if printf '%s\n' "$script" | grep -q URLForApplicationToOpenURL; then
  if [[ -f /tmp/fake-handler ]]; then
    cat /tmp/fake-handler
  else
    printf 'absent\n'
  fi
  exit 0
fi
if printf '%s\n' "$script" | grep -F -q 'setDefaultApplicationAtURLToOpenURLsWithSchemeError'; then
  exit 1
fi
if printf '%s\n' "$script" | grep -F -q 'setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler'; then
  if [[ -f /tmp/fake-handler-late ]]; then
    printf '%s\n' "$4" > /tmp/fake-handler
    exit 1
  fi
  if [[ -f /tmp/fake-handler-restore-fail ]]; then
    exit 1
  fi
  printf '%s\n' "$4" > /tmp/fake-handler
  printf 'restored\n'
  exit 0
fi
if printf '%s\n' "$script" | grep -q descriptorWithProcessIdentifier; then
  if [[ -f /tmp/fake-deliver-nil ]]; then
    if printf '%s\n' "$script" | grep -q "returned nil"; then
      exit 1
    fi
    printf 'sent\n'
    exit 0
  fi
  if [[ -f /tmp/fake-handler-flip ]]; then
    cat /tmp/fake-handler-flip > /tmp/fake-handler
  fi
  if [[ -f /tmp/fake-deliver-fail ]]; then
    exit 1
  fi
  if [[ -f /tmp/fake-open-second ]]; then
    nohup "$FAKE_APP_EXE" >/tmp/fake-second.out 2>&1 &
    printf '%s\n' "$!" > /tmp/fake-second-pid
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
printf 'unhandled %s\n' "$*" >> /tmp/fake-osascript.log
exit 1

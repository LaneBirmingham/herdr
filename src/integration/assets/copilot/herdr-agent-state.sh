#!/bin/sh
# installed by herdr
# safe to edit. this hook only activates inside herdr-managed panes.
# HERDR_INTEGRATION_ID=copilot
# HERDR_INTEGRATION_VERSION=1

set -eu

action="${1:-}"
hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-copilot-hook.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

case "$action" in
  working|idle|blocked|release|notification|pre_tool_use) ;;
  *) exit 0 ;;
esac

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_ACTION="$action" HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY'
import json
import os
import random
import socket
import time

source = "herdr:copilot"
action = os.environ.get("HERDR_ACTION", "")
pane_id = os.environ.get("HERDR_PANE_ID")
socket_path = os.environ.get("HERDR_SOCKET_PATH")
hook_input_file = os.environ.get("HERDR_HOOK_INPUT_FILE")

if not pane_id or not socket_path:
    raise SystemExit(0)

hook_input = {}
if hook_input_file:
    try:
        with open(hook_input_file, encoding="utf-8") as handle:
            content = handle.read()
        if content.strip():
            hook_input = json.loads(content)
    except Exception:
        hook_input = {}

if action == "notification":
    notification_type = hook_input.get("notification_type") or hook_input.get("notificationType")
    if notification_type in ("permission_prompt", "elicitation_dialog"):
        action = "blocked"
    elif notification_type == "agent_idle":
        action = "idle"
    else:
        raise SystemExit(0)
elif action == "pre_tool_use":
    tool_name = hook_input.get("toolName") or hook_input.get("tool_name")
    if tool_name == "ask_user":
        action = "blocked"
    else:
        action = "working"

request_id = f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"
report_seq = time.time_ns()
if action == "release":
    request = {
        "id": request_id,
        "method": "pane.release_agent",
        "params": {
            "pane_id": pane_id,
            "source": source,
            "agent": "copilot",
            "seq": report_seq,
        },
    }
else:
    request = {
        "id": request_id,
        "method": "pane.report_agent",
        "params": {
            "pane_id": pane_id,
            "source": source,
            "agent": "copilot",
            "state": action,
            "seq": report_seq,
        },
    }

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(socket_path)
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        client.recv(4096)
    except Exception:
        pass
    client.close()
except Exception:
    pass
PY

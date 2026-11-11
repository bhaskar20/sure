#!/usr/bin/env bash
# Run Sure Desktop in dev mode against runtime/ in place.
#
#   npm run dev:local   human mode: Sure on the default port (SURE_HUMAN_PORT,
#                       3000). A Sure app already on that port is stopped
#                       first; the window then lists accounts to sign in as.
#   npm run dev:agent   agent mode (coding agents): the first free port from
#                       SURE_AGENT_PORT (3100) up, never the human port, and
#                       separate data, so the human's app is never disturbed.
#
# The frontend dev server takes the first free port from 1420 (human) or 1500
# (agent), so dev apps from several checkouts can run side by side.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-human}"
human_port="${SURE_HUMAN_PORT:-3000}"

listener() { lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }

first_free_port() { # start [skip]
  local port="$1"
  while [ -n "$(listener "$port")" ] || [ "$port" = "${2:-}" ]; do port=$((port + 1)); done
  echo "$port"
}

# The process to stop for the Sure server listening on $1: its desktop app if it
# has one, else the server itself. Prints nothing if it isn't a Sure server.
sure_process_on() {
  local pid cmd parent parent_cmd cwd
  pid="$(listener "$1")"
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$cmd" == puma* ]] || return 0
  parent="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  parent_cmd="$(ps -o command= -p "$parent" 2>/dev/null || true)"
  if [[ "$parent_cmd" == *sure-desktop* || "$parent_cmd" == *Sure.app* ]]; then
    echo "$parent"
    return 0
  fi
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  [[ "$cwd" == */runtime/app ]] && echo "$pid"
  return 0
}

if [ "$mode" = "human" ]; then
  web_port="$human_port"
  if [ -n "$(listener "$web_port")" ]; then
    target="$(sure_process_on "$web_port")"
    if [ -z "$target" ]; then
      echo "Port $web_port is used by another program: $(ps -o command= -p "$(listener "$web_port")")" >&2
      echo "Stop it, or use another port: SURE_HUMAN_PORT=3001 npm run dev:local" >&2
      exit 1
    fi
    echo "Stopping the Sure app on port $web_port (pid $target)…"
    kill -TERM "$target"
    for _ in $(seq 1 30); do
      [ -z "$(listener "$web_port")" ] && break
      sleep 1
    done
    if [ -n "$(listener "$web_port")" ]; then
      echo "It is still running; stop it and try again." >&2
      exit 1
    fi
  fi
  frontend_port="$(first_free_port 1420)"
elif [ "$mode" = "agent" ]; then
  web_port="$(first_free_port "${SURE_AGENT_PORT:-3100}" "$human_port")"
  frontend_port="$(first_free_port 1500)"
else
  echo "usage: dev-local.sh [human|agent]" >&2
  exit 1
fi

echo "Sure ($mode mode): http://127.0.0.1:$web_port  (frontend dev server on $frontend_port)"
export SURE_DEV_MODE="$mode" SURE_WEB_PORT="$web_port" SURE_DEV_PORT="$frontend_port"
export SURE_RUNTIME_DIR="${SURE_RUNTIME_DIR:-$PWD/runtime}"
exec npx tauri dev --config "{\"build\":{\"devUrl\":\"http://localhost:$frontend_port\"}}"

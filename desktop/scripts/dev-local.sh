#!/usr/bin/env bash
# `npm run dev:local`: run the app in dev mode against runtime/ in place.
# Picks a free port for the frontend dev server (1420 upwards), so several
# checkouts (worktrees) can run their dev apps side by side.
set -euo pipefail
cd "$(dirname "$0")/.."

port="${SURE_DEV_PORT:-1420}"
while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
  port=$((port + 1))
done
echo "Frontend dev server on port $port"

export SURE_DEV_PORT="$port"
export SURE_RUNTIME_DIR="${SURE_RUNTIME_DIR:-$PWD/runtime}"
exec npx tauri dev --config "{\"build\":{\"devUrl\":\"http://localhost:$port\"}}" "$@"

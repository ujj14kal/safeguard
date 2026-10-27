#!/usr/bin/env bash
# Live stream in one command: a free Cloudflare quick tunnel (no account)
# plus the backend, with PUBLIC_BASE_URL set to the tunnel so the live link
# in every alert opens on any phone, on any network.
#
# Needs: `brew install cloudflared`, backend/.venv, and your keys in the
# environment or in a git-ignored .env at the repo root (META_MODEL_API_KEY,
# SAFEGUARD_APP_TOKEN, TELEGRAM_BOT_TOKEN). Ctrl+C stops both.
# Usage: ./scripts/live.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "cloudflared is not installed. Install it with: brew install cloudflared" >&2
  exit 1
fi
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
if [ -z "${SAFEGUARD_APP_TOKEN:-}" ]; then
  echo "Refusing to expose the backend without SAFEGUARD_APP_TOKEN: the tunnel is public." >&2
  echo "Set it in the environment or .env, and put the same value in the app (Settings -> Developer)." >&2
  exit 1
fi

LOG="$(mktemp)"
cloudflared tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG" 2>&1 &
TUNNEL_PID=$!
trap 'kill "$TUNNEL_PID" 2>/dev/null || true; rm -f "$LOG"' EXIT

URL=""
for _ in $(seq 1 60); do
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 0.5
done
if [ -z "$URL" ]; then
  echo "The tunnel did not come up. cloudflared said:" >&2
  tail -5 "$LOG" >&2
  exit 1
fi

export PUBLIC_BASE_URL="$URL"
echo "Live links will open at: $URL"
echo "Starting the backend (Ctrl+C stops it and the tunnel)."
cd backend
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000

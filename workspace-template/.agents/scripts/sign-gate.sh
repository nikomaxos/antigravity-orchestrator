#!/usr/bin/env bash
# =============================================================================
# Root Gatekeeper Signing Client (`sign-gate.sh`)
# =============================================================================
# Delegates HMAC-SHA256 signing and objective HEAD/worktree_hash/caller
# verification to the root-owned `agy-gatekeeper.service` daemon on 127.0.0.1:18099.
# Unprivileged users / AI agents cannot read `/etc/agy-gatekeeper/gate.key`
# or `.git/hooks/.gate-secret` (`0600 root:root`).
#
# Usage: ./scripts/sign-gate.sh <gate-file-path> '<json-content>'
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

GATE_FILE="$1"
CONTENT="$2"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GATE_NAME=$(basename "$GATE_FILE" .json)

REQ_BODY=$(jq -n -c \
  --arg ws "$REPO_ROOT" \
  --arg g "$GATE_NAME" \
  --argjson p "$CONTENT" \
  '{workspace: $ws, gate: $g, payload: $p}')

RAW_RESP=$(curl -sS -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d "$REQ_BODY" \
  "http://127.0.0.1:18099/api/gatekeeper/sign" 2>&1 || printf '\n000')

HTTP_CODE=$(printf '%s\n' "$RAW_RESP" | tail -n 1)
RESP_BODY=$(printf '%s\n' "$RAW_RESP" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ ERROR: agy-gatekeeper rejected signing ${GATE_FILE} (HTTP ${HTTP_CODE}): ${RESP_BODY:-service unreachable on 127.0.0.1:18099}" >&2
  exit 1
fi

HMAC=$(printf '%s' "$RESP_BODY" | jq -r '.hmac // ""')
echo "✅ Signed ${GATE_FILE} via agy-gatekeeper.service (HMAC: ${HMAC:0:16}...)"

#!/usr/bin/env bash
# =============================================================================
# Gate Verification Script — Validates all signed gates via agy-gatekeeper
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"

FAILED_CHECKS=""

for gate_file in qa.json regression.json security.json vault.json docs.json skills.json codex-review.json; do
  FULL_PATH="$STATE_DIR/$gate_file"
  if [ -f "$FULL_PATH" ]; then
    GATE_NAME="${gate_file%.json}"
    if ! curl -sf "http://127.0.0.1:18099/api/gatekeeper/verify-file?gate=${GATE_NAME}&workspace=${REPO_ROOT}" >/dev/null 2>&1; then
      FAILED_CHECKS="${FAILED_CHECKS}${gate_file} HMAC INVALID or UNSIGNED; "
    fi
  fi
done

if [ -n "$FAILED_CHECKS" ]; then
  echo "❌ Verification Failed: $FAILED_CHECKS"
  exit 1
else
  echo "✅ All gates verified successfully via agy-gatekeeper.service."
  exit 0
fi

#!/usr/bin/env bash
# =============================================================================
# Regression Gate Runner — Marks regression status and signs regression.json
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

cd "$REPO_ROOT"

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
WORKTREE=$(codex_code_worktree_hash)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

STATUS="${1:-NOT_APPLICABLE}"

echo "🔍 Regression Gate: status=$STATUS"

if [ "$STATUS" != "PASS" ] && [ "$STATUS" != "NOT_APPLICABLE" ]; then
  echo "❌ Invalid status: $STATUS (must be PASS or NOT_APPLICABLE)"
  exit 1
fi

CONTENT=$(printf '{"status":"%s","tested_head":"%s","worktree_hash":"%s","timestamp":"%s"}' "$STATUS" "$HEAD" "$WORKTREE" "$TS")
bash "$SIGN_SCRIPT" ".agent-state/regression.json" "$CONTENT"

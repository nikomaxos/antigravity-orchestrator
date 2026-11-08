#!/usr/bin/env bash
# =============================================================================
# Security Gate Runner — Validates security review before signing
# =============================================================================
# Checks:
# 1. security.json exists with a valid reviewer_agent_id
# 2. OWASP checklist has >= 3 entries
# 3. findings is an array
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

cd "$REPO_ROOT"

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
WORKTREE=$(codex_code_worktree_hash)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "🔍 Validating Security Review..."

SECURITY_FILE="${STATE_DIR}/security.json"

if [ ! -f "$SECURITY_FILE" ]; then
  echo "❌ No security.json found. A reviewer must perform the review first."
  exit 1
fi

STATUS=$(jq -r '.status // "PENDING"' "$SECURITY_FILE")
REVIEWER=$(jq -r '.reviewer_agent_id // ""' "$SECURITY_FILE")
OWASP_COUNT=$(jq '.owasp_checklist | length' "$SECURITY_FILE" 2>/dev/null || echo 0)
FINDINGS_TYPE=$(jq '.findings | type' "$SECURITY_FILE" 2>/dev/null || echo '"null"')

ERRORS=""

if [ "$STATUS" != "PASS" ]; then
  ERRORS="${ERRORS}Security status is $STATUS (not PASS); "
fi

if [ -z "$REVIEWER" ]; then
  ERRORS="${ERRORS}Missing reviewer_agent_id; "
fi

if [ "$OWASP_COUNT" -lt 3 ] 2>/dev/null; then
  ERRORS="${ERRORS}OWASP checklist has $OWASP_COUNT entries (need >= 3); "
fi

if [ "$FINDINGS_TYPE" != '"array"' ]; then
  ERRORS="${ERRORS}findings is not an array; "
fi

if [ -n "$ERRORS" ]; then
  echo "❌ Security validation FAILED: $ERRORS"
  exit 1
fi

echo "✅ Security review valid (reviewer: ${REVIEWER:0:12}...)"
echo "   OWASP checks: $OWASP_COUNT"
echo "   Findings: $(jq '.findings | length' "$SECURITY_FILE")"

CONTENT=$(jq --arg h "$HEAD" --arg w "$WORKTREE" --arg t "$TS" \
  'del(.hmac) | .reviewed_head=$h | .worktree_hash=$w | .tested_head=$h | .timestamp=$t' \
  "$SECURITY_FILE" | tr -d '\n')

bash "$SIGN_SCRIPT" ".agent-state/security.json" "$CONTENT"

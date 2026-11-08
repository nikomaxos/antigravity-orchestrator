#!/usr/bin/env bash
# =============================================================================
# SECURITY REVIEW WRITER — Writes verified security review results
# =============================================================================
# Usage: ./scripts/write-security-review.sh <reviewer_agent_id> <status> <findings_json> <owasp_json>
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"
mkdir -p "$STATE_DIR"

REVIEWER_ID="${1:?'reviewer_agent_id is required'}"
STATUS="${2:?'status (PASS/FAIL) is required'}"
FINDINGS_JSON="${3:?'findings JSON array is required'}"
OWASP_JSON="${4:?'owasp_checklist JSON array is required'}"

if [ "$STATUS" != "PASS" ] && [ "$STATUS" != "FAIL" ]; then
  echo "⛔ Invalid status: $STATUS. Must be PASS or FAIL."
  exit 1
fi

echo "$FINDINGS_JSON" | jq empty 2>/dev/null || { echo "⛔ Invalid findings JSON"; exit 1; }
echo "$OWASP_JSON" | jq empty 2>/dev/null || { echo "⛔ Invalid OWASP JSON"; exit 1; }

OWASP_COUNT=$(echo "$OWASP_JSON" | jq 'length')
if [ "$OWASP_COUNT" -lt 3 ]; then
  echo "⛔ OWASP checklist must have at least 3 entries (got $OWASP_COUNT)"
  exit 1
fi

HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "${STATE_DIR}/security.json" << EOF
{
  "status": "$STATUS",
  "reviewed": true,
  "reviewed_head": "$HEAD",
  "reviewer_agent_id": "$REVIEWER_ID",
  "timestamp": "$TIMESTAMP",
  "findings": $FINDINGS_JSON,
  "owasp_checklist": $OWASP_JSON
}
EOF

echo "✅ Security review written by reviewer $REVIEWER_ID — status: $STATUS"
echo "   reviewed_head: $HEAD"
echo "   findings: $(echo "$FINDINGS_JSON" | jq length) items"
echo "   owasp: $OWASP_COUNT checks"

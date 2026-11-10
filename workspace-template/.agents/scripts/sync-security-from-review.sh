#!/usr/bin/env bash
# =============================================================================
# Post-Commit OWASP & GitHub Security Sync (`sync-security-from-review.sh`)
# =============================================================================
# Cryptographically verifies the pre-commit Cross-Model OWASP review
# (`.hmac` + `head == HEAD~1` + `staged_fingerprint == git diff HEAD~1 HEAD`) +
# deterministic GitHub Dependabot alert checks (`0` extra LLM tokens!).
#
# If `HEAD` is a merge commit, lacks a bound/HMAC-valid `codex-review.json`, or
# touched security-critical paths (Auth, JWT, Crypto, Secrets, or enforcement
# scripts/hooks), exits `2` to require a dedicated Security Reviewer subagent!
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT="$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"
cd "$REPO_ROOT"

if git rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then
  echo "🛡️  HEAD is a merge commit — dedicated Security Reviewer REQUIRED."
  exit 2
fi

COMMITTED_FILES=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)
CODE_COMMITTED=$(printf '%s\n' "$COMMITTED_FILES" | grep -vE '(\.md$|\.txt$|^\.agent-state/|^\.agent-reports/|^\.last-staging-deploy$|^docs/|^platform-docs/)' || true)

# Docs/Vault-only commit: deterministic sign-off
if [ -z "$CODE_COMMITTED" ]; then
  OWASP_DEFAULT='[{"check":"XSS","status":"NOT_APPLICABLE","notes":"Docs/config metadata only"},{"check":"SQLInjection","status":"NOT_APPLICABLE","notes":"Docs/config metadata only"},{"check":"CommandInjection","status":"NOT_APPLICABLE","notes":"Docs/config metadata only"},{"check":"AccessControl","status":"NOT_APPLICABLE","notes":"Docs/config metadata only"},{"check":"SecurityMisconfiguration","status":"PASS","notes":"No secrets committed"}]'
  bash "${SCRIPT_DIR}/write-security-review.sh" "deterministic-docs-gate" "PASS" "[]" "$OWASP_DEFAULT"
  bash "${SCRIPT_DIR}/run-security-gate.sh"
  exit 0
fi

# Security-sensitive R3 paths ALWAYS require a dedicated deep Security Reviewer!
if codex_is_security_sensitive_files "$CODE_COMMITTED"; then
  echo "🛡️  HEAD modified security-sensitive infrastructure/auth/enforcement files:"
  printf '%s\n' "$CODE_COMMITTED" | sed 's/^/   - /'
  echo "➡️  Dedicated Security Reviewer REQUIRED (spawn Claude Opus/Sonnet High or Gemini 4 Carbon High subagent, then run write-security-review.sh + run-security-gate.sh)."
  exit 2
fi

if [ ! -f "$CODEX_REVIEW_STATE" ]; then
  echo "❌ Missing ${CODEX_REVIEW_STATE_REL}; run a dedicated Security Reviewer subagent."
  exit 2
fi

# Cryptographic HMAC verification of codex-review.json via root-owned agy-gatekeeper.service
if ! curl -sf "http://127.0.0.1:18099/api/gatekeeper/verify-file?gate=codex-review&workspace=${REPO_ROOT}" >/dev/null 2>&1; then
  echo "❌ ${CODEX_REVIEW_STATE_REL} HMAC verification FAILED via agy-gatekeeper.service! Dedicated Security Reviewer REQUIRED."
  exit 2
fi

PARENT_HEAD=$(git rev-parse HEAD~1 2>/dev/null || echo "")
COMMITTED_FP=$(git diff HEAD~1 HEAD --no-color --no-ext-diff -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null | sha256sum | awk '{print $1}')
CR_HEAD=$(jq -r '.head // ""' "$CODEX_REVIEW_STATE")
CR_FP=$(jq -r '.staged_fingerprint // ""' "$CODEX_REVIEW_STATE")

if [ -z "$PARENT_HEAD" ] || [ "$CR_HEAD" != "$PARENT_HEAD" ] || [ "$CR_FP" != "$COMMITTED_FP" ]; then
  echo "⚠️  ${CODEX_REVIEW_STATE_REL} is NOT bound to current HEAD (expected parent=${PARENT_HEAD:0:12} fp=${COMMITTED_FP:0:16}, got head=${CR_HEAD:0:12} fp=${CR_FP:0:16})."
  echo "➡️  Spawn dedicated Security Reviewer subagent."
  exit 2
fi

CR_STATUS=$(jq -r '.status // ""' "$CODEX_REVIEW_STATE")
CR_REVIEWER=$(jq -r '.reviewer // "cross-model"' "$CODEX_REVIEW_STATE")
CR_MODEL=$(jq -r '.model // "unknown"' "$CODEX_REVIEW_STATE")
OWASP_LEN=$(jq '(.owasp_checklist // []) | length' "$CODEX_REVIEW_STATE" 2>/dev/null || echo 0)

if { [ "$CR_STATUS" != "PASS" ] && [ "$CR_STATUS" != "PASS_FALLBACK" ]; } || [ "$OWASP_LEN" -lt 3 ]; then
  echo "⚠️  codex-review.json lacks a valid PASS + >=3 OWASP checks (status=${CR_STATUS}, owasp=${OWASP_LEN})."
  echo "➡️  Spawn dedicated Security Reviewer subagent."
  exit 2
fi

# Deterministic GitHub Dependabot check (0 LLM tokens, non-blocking if offline)
GH_ALERTS=0
if command -v gh >/dev/null 2>&1; then
  REMOTE_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#' || true)
  if [[ "$REMOTE_REPO" =~ ^[^/]+/[^/]+$ ]]; then
    GH_ALERTS=$(gh api "repos/${REMOTE_REPO}/dependabot/alerts?state=open&severity=critical,high" --jq 'length' 2>/dev/null || echo 0)
  fi
fi

if [ "${GH_ALERTS:-0}" -gt 0 ]; then
  echo "⚠️  GitHub Dependabot reports ${GH_ALERTS} open CRITICAL/HIGH alert(s)! Review manually before push."
  exit 2
fi

OWASP_JSON=$(jq -c '.owasp_checklist' "$CODEX_REVIEW_STATE")
FINDINGS_JSON="[]"
if [ -f "${CODEX_REPORT_DIR}/review-latest.json" ]; then
  FINDINGS_JSON=$(jq -c '[.findings[]? | select(.category=="security")]' "${CODEX_REPORT_DIR}/review-latest.json" 2>/dev/null || echo "[]")
fi

REVIEWER_TAG="cross-model:${CR_REVIEWER}(${CR_MODEL})"
bash "${SCRIPT_DIR}/write-security-review.sh" "$REVIEWER_TAG" "PASS" "$FINDINGS_JSON" "$OWASP_JSON"
bash "${SCRIPT_DIR}/run-security-gate.sh"
echo "✅ Post-commit security.json synchronized from verified Cross-Model OWASP review (${REVIEWER_TAG}) + Dependabot check!"

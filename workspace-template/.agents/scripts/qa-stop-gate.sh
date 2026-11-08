#!/usr/bin/env bash
# =============================================================================
# QA Stop Gate (`qa-stop-gate.sh`)
# =============================================================================
# Enforces that the agent CANNOT stop while uncommitted/unverified code changes
# exist:
#   - Inspects ALL THREE (unstaged `git diff`, staged `git diff --cached`,
#     and untracked `git ls-files --others --exclude-standard`).
#   - Enforces `tested_head` + `worktree_hash` freshness on all gates.
#   - Root Gatekeeper Verification: Queries `http://127.0.0.1:18099/api/gatekeeper/verify-status?mode=stop`.
# =============================================================================
set -euo pipefail

INPUT=$(cat || true)
TERM_REASON=$(echo "$INPUT" | jq -r '.terminationReason // ""' 2>/dev/null || echo "")

if [ "$TERM_REASON" != "model_stop" ]; then
  echo '{"decision": "stop"}'
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"

cd "$REPO_ROOT" || exit 0

CODE_CHANGED=$(
  {
    git diff --name-only 2>/dev/null || true
    git diff --cached --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sort -u | grep -vE '(\.md$|\.json$|\.txt$|^\.agent-state/|^\.agent-reports/|^\.last-staging-deploy$|^docs/|^platform-docs/)' || true
)

if [ -z "$CODE_CHANGED" ]; then
  echo '{"decision": "stop"}'
  exit 0
fi

CURRENT_HEAD_NOW=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
if [ -f "${REPO_ROOT}/.agents/scripts/codex-lib.sh" ]; then
  # shellcheck source=codex-lib.sh
  source "${REPO_ROOT}/.agents/scripts/codex-lib.sh"
  CURRENT_WORKTREE=$(codex_code_worktree_hash)
else
  CURRENT_WORKTREE=$(git diff HEAD -- . ":(exclude).agent-state" ":(exclude)*.md" ":(exclude).agents/skills" 2>/dev/null | md5sum | awk '{print $1}')
fi

MISSING_GATES=""

# 1. QA gate + freshness
QA_FILE="$STATE_DIR/qa.json"
if [ ! -f "$QA_FILE" ] || [ "$(jq -r '.status // "PENDING"' "$QA_FILE")" != "PASS" ]; then
  MISSING_GATES="${MISSING_GATES}QA verification pending (run: bash .agents/scripts/run-qa-gate.sh); "
else
  QA_HEAD=$(jq -r '.tested_head // ""' "$QA_FILE")
  QA_WT=$(jq -r '.worktree_hash // ""' "$QA_FILE")
  if [ "$QA_HEAD" != "$CURRENT_HEAD_NOW" ] || [ "$QA_WT" != "$CURRENT_WORKTREE" ]; then
    MISSING_GATES="${MISSING_GATES}QA gate is stale for current worktree (re-run: bash .agents/scripts/run-qa-gate.sh); "
  fi
fi

# 2. Regression gate + freshness
REG_FILE="$STATE_DIR/regression.json"
if [ ! -f "$REG_FILE" ]; then
  MISSING_GATES="${MISSING_GATES}Regression analysis not performed (run: bash .agents/scripts/run-regression-gate.sh); "
else
  REG_STATUS=$(jq -r '.status // "PENDING"' "$REG_FILE")
  REG_HEAD=$(jq -r '.tested_head // ""' "$REG_FILE")
  REG_WT=$(jq -r '.worktree_hash // ""' "$REG_FILE")
  if [ "$REG_STATUS" != "PASS" ] && [ "$REG_STATUS" != "NOT_APPLICABLE" ]; then
    MISSING_GATES="${MISSING_GATES}Regression: $REG_STATUS; "
  elif [ "$REG_HEAD" != "$CURRENT_HEAD_NOW" ] || [ "$REG_WT" != "$CURRENT_WORKTREE" ]; then
    MISSING_GATES="${MISSING_GATES}Regression gate is stale for current worktree (re-run: bash .agents/scripts/run-regression-gate.sh); "
  fi
fi

# 3. Vault gate + freshness
VAULT_FILE="$STATE_DIR/vault.json"
if [ ! -f "$VAULT_FILE" ] || [ "$(jq -r '.updated // false' "$VAULT_FILE")" != "true" ]; then
  MISSING_GATES="${MISSING_GATES}Vault gate pending (run: bash .agents/scripts/run-vault-gate.sh); "
else
  VAULT_HEAD=$(jq -r '.tested_head // ""' "$VAULT_FILE")
  VAULT_WT=$(jq -r '.worktree_hash // ""' "$VAULT_FILE")
  if [ "$VAULT_HEAD" != "$CURRENT_HEAD_NOW" ] || [ "$VAULT_WT" != "$CURRENT_WORKTREE" ]; then
    MISSING_GATES="${MISSING_GATES}Vault gate is stale for current worktree (re-run: bash .agents/scripts/run-vault-gate.sh); "
  fi
fi

# 4. Docs gate + freshness
DOCS_FILE="$STATE_DIR/docs.json"
if [ ! -f "$DOCS_FILE" ] || [ "$(jq -r '.evaluated // false' "$DOCS_FILE")" != "true" ]; then
  MISSING_GATES="${MISSING_GATES}Docs gate pending (run: bash .agents/scripts/run-docs-gate.sh); "
else
  DOCS_HEAD=$(jq -r '.tested_head // ""' "$DOCS_FILE")
  DOCS_WT=$(jq -r '.worktree_hash // ""' "$DOCS_FILE")
  if [ "$DOCS_HEAD" != "$CURRENT_HEAD_NOW" ] || [ "$DOCS_WT" != "$CURRENT_WORKTREE" ]; then
    MISSING_GATES="${MISSING_GATES}Docs gate is stale for current worktree (re-run: bash .agents/scripts/run-docs-gate.sh); "
  fi
fi

# 5. Skills evaluation gate + freshness
SKILLS_FILE="$STATE_DIR/skills.json"
if [ ! -f "$SKILLS_FILE" ]; then
  MISSING_GATES="${MISSING_GATES}Skills evaluation not performed (run: bash .agents/scripts/run-skills-gate.sh); "
else
  SKILLS_EVAL=$(jq -r '.evaluated // false' "$SKILLS_FILE")
  SKILLS_STATUS=$(jq -r '.status // "PENDING"' "$SKILLS_FILE")
  SKILLS_HEAD=$(jq -r '.tested_head // ""' "$SKILLS_FILE")
  SKILLS_CODE_HASH=$(jq -r '.worktree_hash // .code_hash // ""' "$SKILLS_FILE")
  if [ "$SKILLS_EVAL" != "true" ] || { [ "$SKILLS_STATUS" != "UPDATED" ] && [ "$SKILLS_STATUS" != "NO_UPDATE_NEEDED" ]; }; then
    MISSING_GATES="${MISSING_GATES}Skills evaluation pending (run: bash .agents/scripts/run-skills-gate.sh); "
  elif [ "$SKILLS_HEAD" != "$CURRENT_HEAD_NOW" ] || [ "$SKILLS_CODE_HASH" != "$CURRENT_WORKTREE" ]; then
    MISSING_GATES="${MISSING_GATES}Skills evaluation is stale for current code (re-run: bash .agents/scripts/run-skills-gate.sh); "
  fi
fi

# 6. Optional Staging Deploy gate (if staging.json is present)
if [ -f "$STATE_DIR/staging.json" ]; then
  STAGING_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/staging.json")
  if [ "$STAGING_STATUS" != "PASS" ]; then
    MISSING_GATES="${MISSING_GATES}Staging deployment status is $STAGING_STATUS; "
  fi
fi

# 7. Root Gatekeeper Service verification (mode=stop)
GK_HTTP=$(curl -s -o /tmp/gk-stop-check.$$.json -w "%{http_code}" "http://127.0.0.1:18099/api/gatekeeper/verify-status?mode=stop&workspace=${REPO_ROOT}" 2>/dev/null || echo "000")
if [ "$GK_HTTP" = "000" ]; then
  rm -f "/tmp/gk-stop-check.$$.json"
  MISSING_GATES="${MISSING_GATES}Root Gatekeeper (stop): agy-gatekeeper.service unreachable on 127.0.0.1:18099; "
elif [ "$GK_HTTP" != "200" ]; then
  GK_ERRS=$(jq -r '(.errors // ["gatekeeper stop check failed"]) | join("; ")' "/tmp/gk-stop-check.$$.json" 2>/dev/null || echo "gatekeeper stop check failed")
  rm -f "/tmp/gk-stop-check.$$.json"
  MISSING_GATES="${MISSING_GATES}Root Gatekeeper (stop): ${GK_ERRS}; "
else
  rm -f "/tmp/gk-stop-check.$$.json"
fi

if [ -n "$MISSING_GATES" ]; then
  MISSING_GATES=$(echo "$MISSING_GATES" | sed 's/; $//')
  jq -n -c --arg r "⚠️ Cannot stop: ${MISSING_GATES}. Complete these gates before stopping." '{decision: "continue", reason: $r}'
  exit 0
fi

echo '{"decision": "stop"}'

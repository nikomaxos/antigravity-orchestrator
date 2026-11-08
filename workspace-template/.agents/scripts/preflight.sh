#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

INPUT=$(cat)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"

if [ ! -d "$STATE_DIR" ] || [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
  echo '{"injectSteps": []}'
  exit 0
fi

QA_STATUS="N/A"
[ -f "$STATE_DIR/qa.json" ] && QA_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/qa.json")

VAULT_STATUS="N/A"
[ -f "$STATE_DIR/vault.json" ] && VAULT_STATUS=$(jq -r 'if .updated then "UPDATED" else "PENDING" end' "$STATE_DIR/vault.json")

DOCS_STATUS="N/A"
[ -f "$STATE_DIR/docs.json" ] && DOCS_STATUS=$(jq -r 'if .evaluated then "EVALUATED" else "PENDING" end' "$STATE_DIR/docs.json")

SKILLS_STATUS="PENDING"
if [ -f "$STATE_DIR/skills.json" ]; then
  SKILLS_STATUS=$(jq -r 'if .evaluated then (.status // "EVALUATED") else "PENDING" end' "$STATE_DIR/skills.json")
fi

SECURITY_STATUS="N/A"
[ -f "$STATE_DIR/security.json" ] && SECURITY_STATUS=$(jq -r 'if .status == "PASS" then "REVIEWED" else "PENDING" end' "$STATE_DIR/security.json")

REG_STATUS="N/A"
[ -f "$STATE_DIR/regression.json" ] && REG_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/regression.json")

CODEX_MSG=""
CODEX_LIB="${REPO_ROOT}/.agents/scripts/codex-lib.sh"
if [ -f "$CODEX_LIB" ]; then
  CODEX_MSG=$(
    set +e +u
    # shellcheck source=codex-lib.sh
    source "$CODEX_LIB" 2>/dev/null
    CR="N/A"
    if [ -n "$(codex_staged_files)" ]; then
      TIER=$(codex_classify_diff_tier)
      CR="REQUIRED(${TIER})"
      if [ -f "$STATE_DIR/codex-review.json" ]; then
        S=$(jq -r '.status // "PENDING"' "$STATE_DIR/codex-review.json")
        if [ "$(jq -r '.staged_fingerprint // ""' "$STATE_DIR/codex-review.json")" = "$(codex_staged_fingerprint)" ]; then
          CR="${S}(${TIER})"
        else
          CR="STALE(was ${S},${TIER})"
        fi
      fi
    fi

    B_OK="✗"; codex_resolve_bin >/dev/null 2>&1 && B_OK="✓"
    C_OK="✗"; claude_resolve_bin >/dev/null 2>&1 && C_OK="✓"
    D_OK="free"; llm_has_deepseek_key && D_OK="✓"

    RCA=""
    if [ -L "${CODEX_REPORT_DIR}/rca-latest.md" ] || [ -f "${CODEX_REPORT_DIR}/rca-latest.md" ]; then
      AGE_H=$(( ( $(date +%s) - $(stat -L -c %Y "${CODEX_REPORT_DIR}/rca-latest.md" 2>/dev/null || date +%s) ) / 3600 ))
      [ "$AGE_H" -lt 48 ] && RCA=", RCA:${AGE_H}h"
    fi

    CTX_WARN=""
    CONV_ID=$(printf '%s' "$INPUT" | jq -r '.conversationId // .trajectoryId // ""' 2>/dev/null)
    HOME_DIR="${HOME:-/home/nick}"
    TR_FILE=""
    if [ -n "$CONV_ID" ] && [ -f "${HOME_DIR}/.gemini/antigravity/brain/${CONV_ID}/.system_generated/logs/transcript.jsonl" ]; then
      TR_FILE="${HOME_DIR}/.gemini/antigravity/brain/${CONV_ID}/.system_generated/logs/transcript.jsonl"
    else
      # shellcheck disable=SC2012
      TR_FILE=$(ls -1t "${HOME_DIR}"/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -1)
    fi
    if [ -n "$TR_FILE" ] && [ -f "$TR_FILE" ]; then
      LAST_IN=$(tail -n 25 "$TR_FILE" 2>/dev/null | jq -r -R 'fromjson? | select(.type=="PLANNER_RESPONSE" and .input_tokens != null) | .input_tokens' 2>/dev/null | tail -1)
      if [ -n "$LAST_IN" ] && [ "$LAST_IN" -gt 160000 ] 2>/dev/null; then
        CTX_WARN=" | 🛑 CTX=$((LAST_IN / 1000))K (>160K: suggest /compact or rotate chat!)"
      elif [ -n "$LAST_IN" ] && [ "$LAST_IN" -gt 120000 ] 2>/dev/null; then
        CTX_WARN=" | ⚠️ CTX=$((LAST_IN / 1000))K (>120K: delegate heavy reads to Flash subagent; suggest /compact soon)"
      fi
    fi

    echo " | 🤖 Review=${CR} Pools[B:${B_OK} C:${C_OK} D:${D_OK}]${RCA}${CTX_WARN}"
  ) || CODEX_MSG=""
fi

MSG="🔒 Active Gates: QA=${QA_STATUS}, Regression=${REG_STATUS}, Vault=${VAULT_STATUS}, Docs=${DOCS_STATUS}, Skills=${SKILLS_STATUS}, Security=${SECURITY_STATUS}${CODEX_MSG}"
jq -n -c --arg m "$MSG" '{injectSteps: [{ephemeralMessage: $m}]}'

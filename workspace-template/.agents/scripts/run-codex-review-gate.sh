#!/usr/bin/env bash
# =============================================================================
# Cross-Model Council Review Gate (`run-codex-review-gate.sh`)
# =============================================================================
# Independent pre-commit code + OWASP review of the STAGED diff across 4 Pools:
#   1. Pool B (Primary):  OpenAI Codex CLI (`R1`: terra med, `R2`: astra med, `R3`: astra high)
#                         + Stateful Round-2+ Delta Review (`codex exec resume`)!
#   2. Pool C (Failover): Anthropic Claude Code CLI (`R1`: sonnet low, `R2`: sonnet high, `R3`: opus/sonnet high)
#   3. Pool D (Failover): OpenCode CLI + DeepSeek API (`deepseek/deepseek-v4-pro`)
#   4. Pool A (Last Resort `--fallback`): Internal Antigravity `Gemini 4 Carbon High` subagent
#      (ONLY allowed if Pools B + C + D were all RATE_LIMITED or UNAVAILABLE!)
#
# Writes (HMAC-signed): .agent-state/codex-review.json
# Reports:              .agent-reports/codex/review-latest.{json,md}
# =============================================================================
set -euo pipefail

# Canonical environment
unset CODEX_BIN CODEX_HOME CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT CODEX_TIMEOUT_SECS CODEX_MAX_DIFF_BYTES DEEPSEEK_API_KEY ANTHROPIC_API_KEY
export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"
SIGN_SCRIPT="${CODEX_SCRIPTS_DIR}/sign-gate.sh"

cd "$CODEX_REPO_ROOT"
mkdir -p "$CODEX_REPORT_DIR" "$(dirname "$CODEX_REVIEW_STATE")"

MODE="review"
FALLBACK_FILE=""
case "${1:-}" in
  --fallback) MODE="fallback"; FALLBACK_FILE="${2:-}" ;;
  --status)   MODE="status" ;;
  ""|--review) ;;
  -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 3 ;;
esac

HEAD_SHA=$(git rev-parse HEAD)
FP=$(codex_staged_fingerprint)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAGED_FILES_JSON=$(codex_staged_files | jq -R -s -c 'split("\n") | map(select(length>0))')

prev_field() { jq -r "$1 // \"\"" "$CODEX_REVIEW_STATE" 2>/dev/null || echo ""; }

sign_state() {
  bash "$SIGN_SCRIPT" "$CODEX_REVIEW_STATE_REL" "$1" >/dev/null
  echo "🔏 Signed ${CODEX_REVIEW_STATE_REL}"
}

render_markdown() {
  {
    echo "# $2"
    echo
    echo "- Status: **$(jq -r '.status' "$1")** | Tier: **$(jq -r '.tier // "R3"' "$1")**"
    echo "- Reviewer: \`$(jq -r '.reviewer' "$1")\` (\`$(jq -r '.model // "-"' "$1")\`, effort \`$(jq -r '.effort // "-"' "$1")\`)"
    echo "- Staged fingerprint: \`$(jq -r '.staged_fingerprint' "$1" | cut -c1-16)\`  HEAD: \`$(jq -r '.head' "$1" | cut -c1-12)\`"
    echo "- Files: $(jq -r '.staged_files | join(", ")' "$1")"
    echo
    echo "## Summary"
    jq -r '.summary' "$1"
    echo
    echo "## OWASP Security Checklist"
    jq -r '(.owasp_checklist // []) | if length==0 then "_None._" else (.[] | "- **[\(.status)] \(.check)**: \(.notes)") end' "$1"
    echo
    echo "## Findings"
    jq -r '.findings | if length==0 then "_None._" else (sort_by({"CRITICAL":0,"HIGH":1,"MEDIUM":2,"LOW":3,"INFO":4}[.severity]) | .[] |
      "### [\(.severity)] \(.title)\n- Category: \(.category)\n- Location: `\(.file)\(if .line then ":\(.line)" else "" end)`\n\n\(.description)\n\n**Recommendation:** \(.recommendation)\n") end' "$1"
  } > "${1%.json}.md"
}

validate_review_shape() {
  jq -e '
    (.verdict|IN("PASS","FAIL")) and (.summary|type=="string") and (.findings|type=="array") and
    all(.findings[]; (.severity|IN("CRITICAL","HIGH","MEDIUM","LOW","INFO"))
                     and (.title|type=="string") and (.file|type=="string")
                     and (.description|type=="string") and (.recommendation|type=="string")) and
    ((.owasp_checklist // []) | type=="array" and length >= 3 and
     all(.[]; (.check|type=="string") and (.status|IN("PASS","FAIL","NOT_APPLICABLE")) and (.notes|type=="string")))
  ' "$1" >/dev/null 2>&1
}

# --- MODE: STATUS ------------------------------------------------------------
if [ "$MODE" = "status" ]; then
  echo "=== Cross-Model Council Review Gate Status ==="
  echo "Current HEAD:       ${HEAD_SHA}"
  echo "Staged files:       $(codex_staged_files | tr '\n' ' ' | sed 's/ $//')"
  echo "Staged fingerprint: ${FP}"
  echo
  if [ ! -f "$CODEX_REVIEW_STATE" ]; then
    echo "State file: (none) — review required before git commit"
    exit 1
  fi
  echo "Last review:"
  jq -r '
    "  Status:       " + .status +
    "\n  Verdict:      " + (.verdict // "-") +
    "\n  Tier:         " + (.tier // "R3") +
    "\n  Reviewer:     " + .reviewer + " (" + (.model // "-") + ", effort " + (.effort // "-") + ")" +
    "\n  Timestamp:    " + .timestamp +
    "\n  Reviewed FP:  " + .staged_fingerprint +
    "\n  Reviewed HEAD:" + .head +
    "\n  Round:        " + ((.review_round // 1)|tostring)
  ' "$CODEX_REVIEW_STATE"
  if [ "$(prev_field '.staged_fingerprint')" = "$FP" ]; then
    echo "  >> Review matches currently staged diff (FRESH)."
    exit 0
  else
    echo "  >> Review is STALE (staged diff changed since last review)."
    exit 1
  fi
fi

# --- Check for Staged Code ---------------------------------------------------
STAGED_DIFF=$(codex_staged_diff)
if [ -z "$STAGED_DIFF" ]; then
  echo "ℹ️  No code changes staged (prose/state/reports only). Review gate NOT required."
  exit 0
fi

DIFF_BYTES=$(printf '%s' "$STAGED_DIFF" | wc -c)
if [ "$DIFF_BYTES" -gt "$CODEX_MAX_DIFF_BYTES" ]; then
  echo "❌ Staged diff too large (${DIFF_BYTES} bytes > max ${CODEX_MAX_DIFF_BYTES}). Split into smaller commits." >&2
  exit 3
fi

# --- MODE: FALLBACK (Pool A: Gemini 4 Carbon subagent review) -------------------
if [ "$MODE" = "fallback" ]; then
  [ -z "$FALLBACK_FILE" ] && { echo "❌ Usage: run-codex-review-gate.sh --fallback <path-to-json>" >&2; exit 3; }
  [ ! -f "$FALLBACK_FILE" ] && { echo "❌ Fallback file not found: $FALLBACK_FILE" >&2; exit 3; }

  # Unlock condition: previous attempt MUST have recorded SKIPPED_RATE_LIMIT
  PREV_STATUS=$(prev_field '.status')
  if [ "$PREV_STATUS" != "SKIPPED_RATE_LIMIT" ]; then
    echo "❌ Internal fallback (--fallback) is ONLY allowed after external pools were exhausted (status=SKIPPED_RATE_LIMIT, got '${PREV_STATUS}')." >&2
    exit 3
  fi

  if ! validate_review_shape "$FALLBACK_FILE"; then
    echo "❌ Fallback JSON fails schema validation (.agents/scripts/codex-review-schema.json)." >&2
    exit 3
  fi

  REV_AGENT=$(jq -r '.reviewer_agent_id // ""' "$FALLBACK_FILE")
  [ -z "$REV_AGENT" ] && { echo "❌ Fallback JSON must include reviewer_agent_id (proves subagent execution)." >&2; exit 3; }

  VERDICT=$(jq -r '.verdict' "$FALLBACK_FILE")
  GATE_STATUS=$([ "$VERDICT" = "PASS" ] && echo "PASS_FALLBACK" || echo "FAIL")
  REPORT_FILE="${CODEX_REPORT_DIR}/review-fallback-$(date -u +%Y%m%dT%H%M%SZ).json"

  jq \
    --arg status "$GATE_STATUS" \
    --arg head "$HEAD_SHA" \
    --arg fp "$FP" \
    --arg ts "$TS" \
    --argjson files "$STAGED_FILES_JSON" \
    --arg model "$(jq -r '.model // "Gemini 4 Carbon High"' "$FALLBACK_FILE")" \
    '
      .status = $status |
      .reviewer = "antigravity:fallback" |
      .model = $model |
      .effort = "high" |
      .head = $head |
      .staged_fingerprint = $fp |
      .timestamp = $ts |
      .staged_files = $files |
      .review_round = 1
    ' "$FALLBACK_FILE" > "$REPORT_FILE"

  ln -sf "$(basename "$REPORT_FILE")" "${CODEX_REPORT_DIR}/review-latest.json"
  render_markdown "$REPORT_FILE" "Antigravity Fallback Review (Pool A)"
  ln -sf "$(basename "${REPORT_FILE%.json}.md")" "${CODEX_REPORT_DIR}/review-latest.md"

  STATE_PAYLOAD=$(jq -c '{
    status: .status,
    verdict: .verdict,
    tier: (.tier // "R3"),
    reviewer: .reviewer,
    model: .model,
    effort: .effort,
    head: .head,
    staged_fingerprint: .staged_fingerprint,
    timestamp: .timestamp,
    staged_files: .staged_files,
    review_round: .review_round,
    findings_count: (.findings | length),
    critical_count: ([.findings[] | select(.severity=="CRITICAL")] | length),
    high_count: ([.findings[] | select(.severity=="HIGH")] | length),
    owasp_checklist: .owasp_checklist
  }' "$REPORT_FILE")

  sign_state "$STATE_PAYLOAD"
  cat "${REPORT_FILE%.json}.md"

  [ "$GATE_STATUS" = "PASS_FALLBACK" ] && { echo "✅ Pre-commit review PASSED via internal fallback."; exit 0; }
  echo "❌ Pre-commit review FAILED via fallback findings. Fix issues and re-review." >&2
  exit 1
fi

# --- MODE: REVIEW (Cascading Pools B -> C -> D) ------------------------------
TIER=$(codex_classify_diff_tier)

PREV_FP=$(prev_field '.staged_fingerprint')
PREV_THREAD=$(prev_field '.thread_id')
PREV_STATUS=$(prev_field '.status')
PREV_ROUND=$(prev_field '.review_round')
PREV_REVIEWER=$(prev_field '.reviewer')

IS_RESUME=0
if [ -n "$PREV_THREAD" ] && [ "$PREV_FP" != "$FP" ] && [ "$PREV_STATUS" = "FAIL" ] && [[ "$PREV_REVIEWER" =~ ^codex: ]]; then
  IS_RESUME=1
fi

ROUND=$(( ${PREV_ROUND:-0} + 1 ))
[ "$IS_RESUME" -eq 0 ] && ROUND=1

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
PROMPT_FILE="${CODEX_REPORT_DIR}/review-${STAMP}.prompt.md"
RAW_OUT="${CODEX_REPORT_DIR}/review-${STAMP}.raw.json"
REPORT_FILE="${CODEX_REPORT_DIR}/review-${STAMP}.json"

echo "🔍 Staged Diff Risk Tier: ${TIER} (files=$(codex_staged_files | wc -l), diff_lines=$(printf '%s' "$STAGED_DIFF" | grep -cE '^[+-][^+-]' || true))"

case "$TIER" in
  R1)
    C_MODEL="$CODEX_R1_MODEL"; C_EFFORT="$CODEX_R1_EFFORT"
    CL_MODEL="$CLAUDE_R1_MODEL"; CL_EFFORT="$CLAUDE_R1_EFFORT"
    ;;
  R2)
    C_MODEL="$CODEX_R2_MODEL"; C_EFFORT="$CODEX_R2_EFFORT"
    CL_MODEL="$CLAUDE_R2_MODEL"; CL_EFFORT="$CLAUDE_R2_EFFORT"
    ;;
  R3)
    C_MODEL="$CODEX_R3_MODEL"; C_EFFORT="$CODEX_R3_EFFORT"
    CL_MODEL="$CLAUDE_R3_MODEL"; CL_EFFORT="$CLAUDE_R3_EFFORT"
    ;;
esac

# Build Prompt
{
  cat <<'EOF'
# ROLE & TASK
You are an expert principal engineer and security architect conducting an independent,
adversarial pre-commit code and OWASP review of the STAGED git diff.
You run in a strict READ-ONLY sandbox.
Output ONLY a JSON object strictly conforming to the provided schema.
Write the summary, finding titles, descriptions, and recommendations in Greek.
EOF
  echo
  if [ "$TIER" = "R1" ]; then
    codex_build_compact_ui_context
  else
    codex_build_context
  fi
  echo
  echo "# REPOSITORY STATE"
  codex_repo_state
  echo
  if [ "$IS_RESUME" -eq 1 ]; then
    echo "# DELTA REVIEW INSTRUCTIONS (Round ${ROUND})"
    echo "You reviewed a previous version of this diff and found defects."
    echo "Review ONLY the interdiff changes and verify whether previous findings were resolved without introducing new ones."
    echo
    echo "## Interdiff Since Previous Review"
    echo '```diff'
    git -C "$CODEX_REPO_ROOT" diff "${PREV_FP:0:12}" -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null | head -c 200000 || echo "(diff too large or ref unavailable)"
    echo '```'
    echo
  fi
  echo "# CURRENT STAGED DIFF TO REVIEW"
  echo '```diff'
  printf '%s\n' "$STAGED_DIFF"
  echo '```'
} > "$PROMPT_FILE"

REVIEWER_USED=""
MODEL_USED=""
EFFORT_USED=""

# Attempt 1: Pool B (Codex CLI)
if ! codex_pool_in_cooldown "codex:${C_MODEL}" 900; then
  if [ "$IS_RESUME" -eq 1 ]; then
    echo "🤖 [Pool B] Running Round-${ROUND} Delta Review via Codex CLI (resume thread ${PREV_THREAD:0:8})..."
    codex_run_resume "review" "$PREV_THREAD" "$C_MODEL" "$C_EFFORT" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$PROMPT_FILE"
  else
    echo "🤖 [Pool B] Running Pre-Commit Review via Codex CLI (${C_MODEL}, effort ${C_EFFORT})..."
    codex_run "review" "$C_MODEL" "$C_EFFORT" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$PROMPT_FILE"
  fi

  if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$RAW_OUT" ] && validate_review_shape "$RAW_OUT"; then
    REVIEWER_USED="codex:cli"
    MODEL_USED="$C_MODEL"
    EFFORT_USED="$C_EFFORT"
  else
    echo "⚠️  [Pool B] Codex review failed (${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-invalid output})."
  fi
else
  echo "⏭️  [Pool B] Codex in cooldown."
fi

# Attempt 2: Pool C (Claude Code CLI)
if [ -z "$REVIEWER_USED" ]; then
  if ! codex_pool_in_cooldown "claude:${CL_MODEL}" 900; then
    echo "🤖 [Pool C] Failing over to Anthropic Claude Code CLI (${CL_MODEL}, effort ${CL_EFFORT})..."
    claude_run "review" "$CL_MODEL" "$CL_EFFORT" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$PROMPT_FILE"
    if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$RAW_OUT" ] && validate_review_shape "$RAW_OUT"; then
      REVIEWER_USED="claude:cli"
      MODEL_USED="$CL_MODEL"
      EFFORT_USED="$CL_EFFORT"
    else
      echo "⚠️  [Pool C] Claude review failed (${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-invalid output})."
    fi
  else
    echo "⏭️  [Pool C] Claude in cooldown."
  fi
fi

# Attempt 3: Pool D (OpenCode CLI + DeepSeek API)
if [ -z "$REVIEWER_USED" ]; then
  echo "🤖 [Pool D] Failing over to OpenCode CLI (${OPENCODE_PRO_MODEL})..."
  opencode_run "review" "$OPENCODE_PRO_MODEL" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$PROMPT_FILE" 0
  if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$RAW_OUT" ] && validate_review_shape "$RAW_OUT"; then
    REVIEWER_USED="opencode:deepseek"
    MODEL_USED="$OPENCODE_PRO_MODEL"
    EFFORT_USED="default"
  else
    echo "⚠️  [Pool D] OpenCode review failed (${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-invalid output})."
  fi
fi

rm -f "$PROMPT_FILE"

# All External Pools Exhausted -> SKIPPED_RATE_LIMIT
if [ -z "$REVIEWER_USED" ]; then
  echo "⛔ All external review pools (Codex, Claude, DeepSeek) are unavailable or rate-limited."
  echo "➡️  Unlocking last-resort internal fallback (Pool A: Gemini 4 Carbon High subagent)."

  STATE_PAYLOAD=$(jq -n -c \
    --arg status "SKIPPED_RATE_LIMIT" \
    --arg tier "$TIER" \
    --arg head "$HEAD_SHA" \
    --arg fp "$FP" \
    --arg ts "$TS" \
    --argjson files "$STAGED_FILES_JSON" \
    '{
      status: $status,
      verdict: "NONE",
      tier: $tier,
      reviewer: "none:rate_limited",
      model: "none",
      effort: "none",
      head: $head,
      staged_fingerprint: $fp,
      timestamp: $ts,
      staged_files: $files,
      findings_count: 0,
      critical_count: 0,
      high_count: 0,
      owasp_checklist: []
    }')

  sign_state "$STATE_PAYLOAD"
  exit 2
fi

# Process Successful Review
VERDICT=$(jq -r '.verdict' "$RAW_OUT")
CRIT_COUNT=$(jq '[.findings[] | select(.severity=="CRITICAL")] | length' "$RAW_OUT")
HIGH_COUNT=$(jq '[.findings[] | select(.severity=="HIGH")] | length' "$RAW_OUT")
OWASP_FAILS=$(jq '[(.owasp_checklist // [])[] | select(.status=="FAIL")] | length' "$RAW_OUT")

if [ "$CRIT_COUNT" -gt 0 ] || [ "$HIGH_COUNT" -gt 0 ] || [ "$OWASP_FAILS" -gt 0 ]; then
  GATE_STATUS="FAIL"
else
  GATE_STATUS="PASS"
fi

jq \
  --arg status "$GATE_STATUS" \
  --arg verdict "$VERDICT" \
  --arg tier "$TIER" \
  --arg rev "$REVIEWER_USED" \
  --arg mod "$MODEL_USED" \
  --arg eff "$EFFORT_USED" \
  --arg head "$HEAD_SHA" \
  --arg fp "$FP" \
  --arg ts "$TS" \
  --arg th "${CODEX_LAST_THREAD_ID:-}" \
  --argjson files "$STAGED_FILES_JSON" \
  --argjson round "$ROUND" \
  '
    .status = $status |
    .verdict = $verdict |
    .tier = $tier |
    .reviewer = $rev |
    .model = $mod |
    .effort = $eff |
    .head = $head |
    .staged_fingerprint = $fp |
    .timestamp = $ts |
    .thread_id = $th |
    .staged_files = $files |
    .review_round = $round
  ' "$RAW_OUT" > "$REPORT_FILE"

rm -f "$RAW_OUT"
ln -sf "$(basename "$REPORT_FILE")" "${CODEX_REPORT_DIR}/review-latest.json"
render_markdown "$REPORT_FILE" "Pre-Commit Code Review (${REVIEWER_USED})"
ln -sf "$(basename "${REPORT_FILE%.json}.md")" "${CODEX_REPORT_DIR}/review-latest.md"

STATE_PAYLOAD=$(jq -c '{
  status: .status,
  verdict: .verdict,
  tier: .tier,
  reviewer: .reviewer,
  model: .model,
  effort: .effort,
  head: .head,
  staged_fingerprint: .staged_fingerprint,
  timestamp: .timestamp,
  thread_id: .thread_id,
  staged_files: .staged_files,
  review_round: .review_round,
  findings_count: (.findings | length),
  critical_count: ([.findings[] | select(.severity=="CRITICAL")] | length),
  high_count: ([.findings[] | select(.severity=="HIGH")] | length),
  owasp_checklist: .owasp_checklist
}' "$REPORT_FILE")

sign_state "$STATE_PAYLOAD"
cat "${REPORT_FILE%.json}.md"

if [ "$GATE_STATUS" = "PASS" ]; then
  echo "✅ Pre-commit review PASSED (Tier: ${TIER}, Reviewer: ${REVIEWER_USED}). Stage .agent-state/codex-review.json and commit."
  exit 0
fi

echo "❌ Pre-commit review FAILED (${CRIT_COUNT} critical, ${HIGH_COUNT} high, ${OWASP_FAILS} OWASP fails). Fix issues and re-run." >&2
exit 1

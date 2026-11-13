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

# Canonical environment: caller overrides must not influence gate outcome
unset CODEX_BIN CODEX_HOME CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT CODEX_TIMEOUT_SECS CODEX_MAX_DIFF_BYTES DEEPSEEK_API_KEY ANTHROPIC_API_KEY
export HOME="/home/nick"
export PATH="/home/nick/.local/bin:/home/nick/.opencode/bin:/home/nick/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# shellcheck source=codex-lib.sh
source "/home/nick/Development/messaging-agent/.agents/scripts/codex-lib.sh"
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

if [ "$MODE" = "status" ]; then
  if [ ! -f "$CODEX_REVIEW_STATE" ]; then echo "No codex-review.json yet."; exit 0; fi
  S=$(prev_field '.status'); SFP=$(prev_field '.staged_fingerprint'); T=$(prev_field '.tier')
  FRESH="STALE (staged diff changed since review)"; [ "$SFP" = "$FP" ] && FRESH="FRESH"
  echo "Cross-Model review: status=${S} tier=${T:-?} reviewer=$(prev_field '.reviewer') model=$(prev_field '.model') blocking=$(prev_field '.blocking_count') -> ${FRESH}"
  echo "Report: $(prev_field '.report')"
  exit 0
fi

if [ -z "$(codex_staged_files)" ]; then
  echo "ℹ️  No staged code changes (after excluding *.md, .last-staging-deploy, .agent-state, .agent-reports)."
  echo "   Docs-only commits do not require a Cross-Model review."
  exit 0
fi

TIER=$(codex_classify_diff_tier)
case "$TIER" in
  R1)
    C_MOD="$CODEX_R1_MODEL"; C_EFF="$CODEX_R1_EFFORT"
    CL_MOD="$CLAUDE_R1_MODEL"; CL_EFF="$CLAUDE_R1_EFFORT"
    ;;
  R2)
    C_MOD="$CODEX_R2_MODEL"; C_EFF="$CODEX_R2_EFFORT"
    CL_MOD="$CLAUDE_R2_MODEL"; CL_EFF="$CLAUDE_R2_EFFORT"
    ;;
  *)
    C_MOD="$CODEX_R3_MODEL"; C_EFF="$CODEX_R3_EFFORT"
    CL_MOD="$CLAUDE_R3_MODEL"; CL_EFF="$CLAUDE_R3_EFFORT"
    ;;
esac

# -----------------------------------------------------------------------------
# FALLBACK MODE — Pool A internal Antigravity subagent (ONLY if B+C+D all failed)
# -----------------------------------------------------------------------------
if [ "$MODE" = "fallback" ]; then
  PREV_STATUS=$(prev_field '.status'); PREV_FP=$(prev_field '.staged_fingerprint')
  if [ "$PREV_STATUS" != "SKIPPED_RATE_LIMIT" ] && [ "$PREV_STATUS" != "UNAVAILABLE" ]; then
    echo "❌ Fallback refused: last external CLI cascade status is '${PREV_STATUS:-none}'."
    echo "   Internal fallback is ONLY allowed after Codex + Claude + DeepSeek CLIs were all RATE_LIMITED/UNAVAILABLE."
    exit 3
  fi
  if [ "$PREV_FP" != "$FP" ]; then
    echo "❌ Fallback refused: staged diff changed since the failed CLI attempt. Re-run the review gate first."
    exit 3
  fi
  if [ -z "$FALLBACK_FILE" ] || [ ! -f "$FALLBACK_FILE" ]; then
    echo "❌ Fallback review file not found: '${FALLBACK_FILE}'"; exit 3
  fi
  if ! validate_review_shape "$FALLBACK_FILE"; then
    echo "❌ Fallback review does not match .agents/scripts/codex-review-schema.json (including >=3 owasp_checklist items)"; exit 3
  fi
  AGENT_ID=$(jq -r '.reviewer_agent_id // ""' "$FALLBACK_FILE")
  FB_FP=$(jq -r '.staged_fingerprint // ""' "$FALLBACK_FILE")
  if [ -z "$AGENT_ID" ]; then echo "❌ Fallback review missing reviewer_agent_id"; exit 3; fi
  if [ "$FB_FP" != "$FP" ]; then echo "❌ Fallback review staged_fingerprint mismatch (expected ${FP})"; exit 3; fi
  REVIEW_SRC="$FALLBACK_FILE"; REVIEWER="antigravity-fallback"
  MODEL_USED="$(jq -r '.model // "Gemini 4 Carbon High"' "$FALLBACK_FILE")"
  EFFORT_USED="high"; PASS_STATUS="PASS_FALLBACK"; THREAD_USED=""
else
# -----------------------------------------------------------------------------
# REVIEW MODE — Multi-CLI Cascade (Pool B Codex -> Pool C Claude -> Pool D DeepSeek)
# -----------------------------------------------------------------------------
  STAMP_PROMPT=$(date -u +%Y%m%dT%H%M%SZ)
  PROMPT_FILE="${CODEX_REPORT_DIR}/review-${STAMP_PROMPT}.prompt.md"
  CUR_PATCH_TMP="${CODEX_REPORT_DIR}/current-staged-${STAMP_PROMPT}.patch"
  codex_staged_diff > "$CUR_PATCH_TMP"
  DIFF_BYTES=$(wc -c < "$CUR_PATCH_TMP")

  # Build canonical full or R1-compact prompt
  {
    cat <<'EOF'
# ROLE
You are an independent senior code & security reviewer for the `messaging-agent` platform.
Another AI agent (Antigravity) wrote the STAGED change below. Find real defects BEFORE commit.
CRITICAL: You run in a strictly READ-ONLY sandbox. Do NOT write, modify, create, or touch any files!
Any file mutation causes an automatic INTEGRITY_VIOLATION. Only run minimal targeted read-only
inspections (`git diff --cached`, `git show`, `rg`, `cat`) on directly affected callers — do NOT
scan unrelated microservices!

# WHAT TO CHECK
1. Correctness, logic bugs, edge cases, null handling, race conditions, error handling.
2. Security (OWASP Top 10): XSS, SQL Injection, Command Injection, Broken Access Control,
   Security Misconfiguration, secret exposure, SSRF, missing validation on public vs internal routes.
   Populate `owasp_checklist` with at least 5 concrete checks (`XSS`, `SQLInjection`,
   `CommandInjection`, `AccessControl`, `SecurityMisconfiguration`).
3. Regressions: callers/consumers, DTO/API contracts, Flyway immutability & zero data loss,
   Redis key/TTL/Lua atomicity, SMPP session lifecycle, K8s `@PreDestroy` cleanup.
4. Workspace invariants: No-Hardcoded-Routing, `String.format(Locale.US, ...)`, no `java.sql.Timestamp`
   in native queries, and UI Design System preservation on `admin-panel/src/**`.

# SEVERITY (binding)
- CRITICAL: security hole, data loss/corruption, outage, or build break.
- HIGH: a real bug that will misbehave in normal use, or a hard workspace rule violation.
- MEDIUM: likely bug in edge cases, missing validation, risky pattern.
- LOW / INFO: style, maintainability, minor suggestions.
Only report issues you can prove from the code. Do NOT invent speculative issues to fill the list.
`verdict` MUST be "FAIL" if and only if at least one finding is CRITICAL or HIGH (or an OWASP check is FAIL).

# OUTPUT
Return ONLY JSON matching the schema. Write `summary`, `description`, `recommendation`, and OWASP `notes`
in Greek (keep identifiers, paths, and technical terms in English).

# WORKSPACE RULES & CONTEXT
EOF
    if [ "$TIER" = "R1" ]; then
      codex_build_compact_ui_context
    else
      codex_build_context
    fi
    echo
    echo "# REPOSITORY STATE (Review Tier: ${TIER})"
    codex_repo_state
    echo
    echo "# STAGED FILES UNDER REVIEW"
    codex_staged_files
    echo
    echo "# STAGED DIFF"
    if [ "$DIFF_BYTES" -gt "$CODEX_MAX_DIFF_BYTES" ]; then
      echo "(Diff is ${DIFF_BYTES} bytes; first ${CODEX_MAX_DIFF_BYTES} bytes shown. Inspect remainder via git diff --cached -- <file>.)"
      echo '```diff'; head -c "$CODEX_MAX_DIFF_BYTES" "$CUR_PATCH_TMP"; echo; echo '```'
    else
      echo '```diff'; cat "$CUR_PATCH_TMP"; echo '```'
    fi
  } > "$PROMPT_FILE"

  RAW_OUT="${CODEX_REPORT_DIR}/review-raw-${STAMP_PROMPT}.json"
  REVIEW_SUCCEEDED=0
  REVIEWER=""
  MODEL_USED=""
  EFFORT_USED=""
  THREAD_USED=""
  CASCADE_ERRORS=""

  # --- Check if Stateful Round-2+ Delta Review is eligible ---
  PREV_STATUS=$(prev_field '.status')
  PREV_HEAD=$(prev_field '.head')
  PREV_REVIEWER=$(prev_field '.reviewer')
  PREV_THREAD=$(prev_field '.review_thread_id')
  LAST_PATCH_FILE="${CODEX_REPORT_DIR}/last-reviewed.patch"
  LAST_REPORT_JSON="${CODEX_REPORT_DIR}/review-latest.json"
  EFFECTIVE_PROMPT_FILE="$PROMPT_FILE"

  if [ "$PREV_STATUS" = "FAIL" ] && [ "$PREV_HEAD" = "$HEAD_SHA" ] && \
     [ -f "$LAST_PATCH_FILE" ] && [ -f "$LAST_REPORT_JSON" ]; then
    DELTA_PROMPT="${CODEX_REPORT_DIR}/review-delta-${STAMP_PROMPT}.prompt.md"
    {
      cat <<'DELTA_EOF'
# STATEFUL DELTA RE-REVIEW (ROUND 2+)
The developer updated the staged diff to fix the previous CRITICAL/HIGH findings on the same HEAD.
STRICT CONVERGENCE RULES (read-only sandbox):
1. Verify whether each previous CRITICAL/HIGH finding listed below is now properly resolved.
2. Review ONLY the newly modified hunks in the interdiff below (and their immediate callers) for regressions.
3. Do NOT invent new stylistic or unrelated findings in unchanged parts of the codebase unless you spot a genuine CRITICAL outage/security defect.
4. Return ONLY valid JSON matching the review schema (including `owasp_checklist` >= 5 items).

## Previous Blocking Findings
DELTA_EOF
      jq '[.findings[] | select(.severity=="CRITICAL" or .severity=="HIGH")]' "$LAST_REPORT_JSON" 2>/dev/null || echo "[]"
      echo
      echo "## Interdiff Since Previous Staged Review"
      echo '```diff'
      diff -u "$LAST_PATCH_FILE" "$CUR_PATCH_TMP" | head -c 150000 || true
      echo '```'
      echo
      echo "## Full Current Staged Diff (for context)"
      echo '```diff'
      head -c "$CODEX_MAX_DIFF_BYTES" "$CUR_PATCH_TMP"
      echo '```'
    } > "$DELTA_PROMPT"
    EFFECTIVE_PROMPT_FILE="$DELTA_PROMPT"

    if [ "$PREV_REVIEWER" = "codex" ] && [ -n "$PREV_THREAD" ] && ! codex_pool_in_cooldown "codex:${C_MOD}"; then
      echo "🔄 Cross-Model Gate [Tier=${TIER}]: Stateful Delta Resume on Codex thread ${PREV_THREAD:0:12} (${C_MOD}, effort=${C_EFF})..."
      codex_run_resume "review" "$PREV_THREAD" "$C_MOD" "$C_EFF" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$DELTA_PROMPT"
      if [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ]; then
        rm -f "$CUR_PATCH_TMP"
        echo "❌ Codex resume ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
        exit 3
      elif [ "$CODEX_RUN_STATUS" = "OK" ] && validate_review_shape "$RAW_OUT"; then
        REVIEW_SUCCEEDED=1; REVIEWER="codex"; MODEL_USED="$C_MOD"; EFFORT_USED="$C_EFF"; THREAD_USED="$PREV_THREAD"
      else
        [ "$CODEX_RUN_STATUS" = "OK" ] && { CODEX_RUN_STATUS="SCHEMA_ERROR"; CODEX_RUN_ERROR="Invalid review JSON shape"; }
        echo "ℹ️  Delta resume returned ${CODEX_RUN_STATUS} (${CODEX_RUN_ERROR}) — falling back to review cascade."
        CASCADE_ERRORS="codex-resume:${CODEX_RUN_STATUS}; "
      fi
    fi
  fi

  # --- Pool B: Fresh OpenAI Codex CLI ---
  if [ "$REVIEW_SUCCEEDED" -eq 0 ]; then
    if codex_pool_in_cooldown "codex:${C_MOD}"; then
      echo "⏭️  [Pool B] Skipping Codex (${C_MOD}) — in cooldown from recent RATE_LIMITED/UNAVAILABLE."
      CASCADE_ERRORS="${CASCADE_ERRORS}codex:RATE_LIMITED(cooldown); "
    else
      echo "🤖 [Pool B] Codex Review [Tier=${TIER}]: model=${C_MOD} effort=${C_EFF} files=$(codex_staged_files | wc -l) diff=${DIFF_BYTES}B"
      codex_run "review" "$C_MOD" "$C_EFF" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$EFFECTIVE_PROMPT_FILE"
      if [ "$CODEX_RUN_STATUS" = "OK" ] && ! validate_review_shape "$RAW_OUT"; then
        CODEX_RUN_STATUS="SCHEMA_ERROR"
        CODEX_RUN_ERROR="Codex output failed JSON schema validation"
      fi
      if [ "$CODEX_RUN_STATUS" = "OK" ]; then
        REVIEW_SUCCEEDED=1; REVIEWER="codex"; MODEL_USED="$C_MOD"; EFFORT_USED="$C_EFF"; THREAD_USED="$CODEX_LAST_THREAD_ID"
      elif [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] || [ "$CODEX_RUN_STATUS" = "TIMEOUT" ] || [ "$CODEX_RUN_STATUS" = "SCHEMA_ERROR" ]; then
        rm -f "$CUR_PATCH_TMP"
        echo "❌ Codex ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
        exit 3
      else
        echo "⚠️  [Pool B] Codex ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
        CASCADE_ERRORS="${CASCADE_ERRORS}codex:${CODEX_RUN_STATUS}(${CODEX_RUN_ERROR}); "
      fi
    fi
  fi

  # --- Pool C: Anthropic Claude Code CLI Failover ---
  if [ "$REVIEW_SUCCEEDED" -eq 0 ]; then
    if codex_pool_in_cooldown "claude:${CL_MOD}" && codex_pool_in_cooldown "claude:${CLAUDE_R2_MODEL:-claude-sonnet-5-5}"; then
      echo "⏭️  [Pool C] Skipping Claude CLI (${CL_MOD}/${CLAUDE_R2_MODEL:-claude-sonnet-5-5}) — in cooldown from recent RATE_LIMITED/UNAVAILABLE."
      CASCADE_ERRORS="${CASCADE_ERRORS}claude:RATE_LIMITED(cooldown); "
    else
      echo "🤖 [Pool C] Failing over to Claude Code CLI [Tier=${TIER}]: model=${CL_MOD} effort=${CL_EFF}..."
      claude_run "review" "$CL_MOD" "$CL_EFF" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$EFFECTIVE_PROMPT_FILE"
      # If R3 opus hit Claude Pro 5h cap, try sonnet high before moving to Pool D!
      if [ "$CODEX_RUN_STATUS" = "RATE_LIMITED" ]; then
        case "$CL_MOD" in
          *opus*)
            retry_sonnet="${CLAUDE_R2_MODEL:-claude-sonnet-5-5}"
            echo "ℹ️  Claude ${CL_MOD} rate-limited; retrying Pool C with model=${retry_sonnet} effort=high..."
            claude_run "review" "$retry_sonnet" "high" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$EFFECTIVE_PROMPT_FILE"
            CL_MOD="$retry_sonnet"; CL_EFF="high"
            ;;
        esac
      fi
      if [ "$CODEX_RUN_STATUS" = "OK" ] && ! validate_review_shape "$RAW_OUT"; then
        CODEX_RUN_STATUS="SCHEMA_ERROR"
        CODEX_RUN_ERROR="Claude CLI output failed JSON schema validation"
      fi
      if [ "$CODEX_RUN_STATUS" = "OK" ]; then
        REVIEW_SUCCEEDED=1; REVIEWER="claude-cli"; MODEL_USED="claude-${CL_MOD}"; EFFORT_USED="$CL_EFF"; THREAD_USED=""
      elif [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] || [ "$CODEX_RUN_STATUS" = "TIMEOUT" ] || [ "$CODEX_RUN_STATUS" = "SCHEMA_ERROR" ]; then
        rm -f "$CUR_PATCH_TMP"
        echo "❌ Claude CLI ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
        exit 3
      else
        echo "⚠️  [Pool C] Claude CLI ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
        CASCADE_ERRORS="${CASCADE_ERRORS}claude:${CODEX_RUN_STATUS}(${CODEX_RUN_ERROR}); "
      fi
    fi
  fi

  # --- Pool D: OpenCode + DeepSeek Paid API Failover ---
  if [ "$REVIEW_SUCCEEDED" -eq 0 ]; then
    opencode_rev_model="${OPENCODE_REVIEW_MODEL:-deepseek/deepseek-v4-pro}"
    echo "🤖 [Pool D] Failing over to OpenCode DeepSeek API [Tier=${TIER}]: model=${opencode_rev_model}..."
    opencode_run "review" "$opencode_rev_model" "$CODEX_REVIEW_SCHEMA" "$RAW_OUT" "$EFFECTIVE_PROMPT_FILE" 1
    if [ "$CODEX_RUN_STATUS" = "OK" ] && ! validate_review_shape "$RAW_OUT"; then
      CODEX_RUN_STATUS="SCHEMA_ERROR"
      CODEX_RUN_ERROR="OpenCode output failed JSON schema validation"
    fi
    if [ "$CODEX_RUN_STATUS" = "OK" ]; then
      REVIEW_SUCCEEDED=1; REVIEWER="opencode-deepseek"; MODEL_USED="$OPENCODE_PRO_MODEL"; EFFORT_USED="high"; THREAD_USED=""
    elif [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] || [ "$CODEX_RUN_STATUS" = "TIMEOUT" ] || [ "$CODEX_RUN_STATUS" = "SCHEMA_ERROR" ]; then
      rm -f "$CUR_PATCH_TMP"
      echo "❌ OpenCode ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
      exit 3
    else
      echo "⚠️  [Pool D] OpenCode ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}"
      CASCADE_ERRORS="${CASCADE_ERRORS}opencode:${CODEX_RUN_STATUS}(${CODEX_RUN_ERROR}); "
    fi
  fi

  # Verify staged diff did not change mid-run
  if [ "$REVIEW_SUCCEEDED" -eq 1 ] && [ "$(codex_staged_fingerprint)" != "$FP" ]; then
    rm -f "$CUR_PATCH_TMP"
    echo "❌ INTEGRITY_VIOLATION: Staged diff changed while review was running. Re-run gate."
    exit 3
  fi

  if [ "$REVIEW_SUCCEEDED" -eq 0 ]; then
    rm -f "$CUR_PATCH_TMP"
    # Unlock Pool A fallback ONLY if every attempted external CLI was RATE_LIMITED or UNAVAILABLE
    if echo "$CASCADE_ERRORS" | grep -qE '(codex|claude|opencode):(ERROR|TIMEOUT|SCHEMA_ERROR|INTEGRITY_VIOLATION)'; then
      echo "❌ External CLI review failed with hard fault (${CASCADE_ERRORS}). Fix the error and re-run."
      exit 3
    fi
    NEW_STATUS="SKIPPED_RATE_LIMIT"
    sign_state "$(jq -n -c --arg s "$NEW_STATUS" --arg tier "$TIER" --arg fp "$FP" --arg h "$HEAD_SHA" --arg t "$TS" \
      --arg e "$CASCADE_ERRORS" --argjson files "$STAGED_FILES_JSON" \
      '{status:$s, tier:$tier, reviewer:"external-cascade", staged_fingerprint:$fp, staged_files:$files, head:$h, blocking_count:null, error:$e, timestamp:$t}')"
    echo "⚠️  All 3 External CLI Pools (Codex, Claude, DeepSeek) unavailable/rate-limited: ${CASCADE_ERRORS}"
    echo "➡️  LAST-RESORT FALLBACK (Pool A):"
    echo "   1. Spawn an internal subagent (Gemini 4 Carbon High) to review the staged diff using codex-review-schema.json"
    echo "      (including owasp_checklist >= 5 items + reviewer_agent_id + staged_fingerprint=\"${FP}\")."
    echo "   2. Save to .agent-reports/codex/fallback-review.json and run:"
    echo "      bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json"
    exit 2
  fi

  mv -f "$CUR_PATCH_TMP" "${CODEX_REPORT_DIR}/last-reviewed.patch"
  REVIEW_SRC="$RAW_OUT"
  PASS_STATUS="PASS"
fi

# -----------------------------------------------------------------------------
# Evaluate Findings + OWASP Checklist
# -----------------------------------------------------------------------------
COUNTS=$(jq -c '[.findings[].severity] as $s | {CRITICAL:($s|map(select(.=="CRITICAL"))|length),
  HIGH:($s|map(select(.=="HIGH"))|length), MEDIUM:($s|map(select(.=="MEDIUM"))|length),
  LOW:($s|map(select(.=="LOW"))|length), INFO:($s|map(select(.=="INFO"))|length)}' "$REVIEW_SRC")
OWASP_FAILS=$(jq '[(.owasp_checklist // [])[] | select(.status=="FAIL")] | length' "$REVIEW_SRC")
BLOCKING=$(( $(echo "$COUNTS" | jq '.CRITICAL + .HIGH') + OWASP_FAILS ))
STATUS="$PASS_STATUS"; [ "$BLOCKING" -gt 0 ] && STATUS="FAIL"

STAMP=$(date -u +%Y%m%dT%H:%M%SZ)
REPORT="${CODEX_REPORT_DIR}/review-${STAMP}.json"
jq --arg s "$STATUS" --arg tier "$TIER" --arg r "$REVIEWER" --arg m "$MODEL_USED" --arg e "$EFFORT_USED" \
   --arg fp "$FP" --arg h "$HEAD_SHA" --arg t "$TS" --arg tid "$THREAD_USED" \
   --argjson files "$STAGED_FILES_JSON" --argjson c "$COUNTS" \
   '{status:$s, tier:$tier, reviewer:$r, model:$m, effort:$e, review_thread_id:(if $tid=="" then null else $tid end),
     staged_fingerprint:$fp, head:$h, timestamp:$t, staged_files:$files, counts:$c,
     model_verdict:.verdict, summary:.summary, owasp_checklist:(.owasp_checklist // []), findings:.findings,
     reviewer_agent_id:(.reviewer_agent_id // null)}' "$REVIEW_SRC" > "$REPORT"
render_markdown "$REPORT" "Cross-Model Review (${REVIEWER} / ${TIER}) — ${STATUS}"
ln -sfn "$(basename "$REPORT")" "${CODEX_REPORT_DIR}/review-latest.json"
ln -sfn "$(basename "${REPORT%.json}.md")" "${CODEX_REPORT_DIR}/review-latest.md"
[ "$MODE" = "review" ] && rm -f "$RAW_OUT"

REPORT_REL="${REPORT#"$CODEX_REPO_ROOT"/}"
OWASP_COMPACT=$(jq -c '.owasp_checklist // []' "$REPORT")
sign_state "$(jq -n -c --arg s "$STATUS" --arg tier "$TIER" --arg r "$REVIEWER" --arg m "$MODEL_USED" --arg e "$EFFORT_USED" \
  --arg fp "$FP" --arg h "$HEAD_SHA" --arg t "$TS" --arg rep "$REPORT_REL" --arg tid "$THREAD_USED" \
  --argjson files "$STAGED_FILES_JSON" --argjson c "$COUNTS" --argjson b "$BLOCKING" --argjson owasp "$OWASP_COMPACT" \
  --arg aid "$(jq -r '.reviewer_agent_id // ""' "$REPORT")" \
  '{status:$s, tier:$tier, reviewer:$r, model:$m, effort:$e, review_thread_id:(if $tid=="" then null else $tid end),
    staged_fingerprint:$fp, staged_files:$files, head:$h, counts:$c, blocking_count:$b,
    owasp_checklist:$owasp, report:$rep,
    reviewer_agent_id:(if $aid=="" then null else $aid end), timestamp:$t}')"

echo ""
echo "📊 Tier=${TIER} | Reviewer=${REVIEWER} (${MODEL_USED}, ${EFFORT_USED}) | Findings: $(echo "$COUNTS" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(" ")') | OWASP_FAIL=${OWASP_FAILS}"
echo "📄 Report: ${REPORT_REL%.json}.md"
if [ "$STATUS" = "FAIL" ]; then
  echo "❌ Cross-Model review FAIL — ${BLOCKING} blocking finding(s). Fix them, re-stage, re-run (Round 2 will auto-resume delta!)."
  exit 1
fi
echo "✅ Cross-Model review ${STATUS} (bound to staged fingerprint ${FP:0:16})"
exit 0

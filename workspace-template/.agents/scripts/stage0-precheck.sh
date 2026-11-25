#!/usr/bin/env bash
# =============================================================================
# Stage-0 Optional Manual DeepSeek Pre-Check (`stage0-precheck.sh`)
# =============================================================================
# MANUAL-ONLY TOOL: Pool D (OpenCode + DeepSeek) is disabled from all automated
# workflows and cascades. Agents MUST NEVER run this script automatically.
# Pass `--manual` (or `AGY_ALLOW_MANUAL_DEEPSEEK=1`) when explicitly triggered
# by the operator on demand.
# =============================================================================
set -euo pipefail

MANUAL_TRIGGER="${AGY_ALLOW_MANUAL_DEEPSEEK:-0}"
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--manual" ]; then
    MANUAL_TRIGGER=1
  else
    ARGS+=("$arg")
  fi
done

if [ "$MANUAL_TRIGGER" != "1" ]; then
  echo "ℹ️  stage0-precheck.sh uses Pool D (DeepSeek / OpenCode), which is configured as MANUAL-ONLY."
  echo "   Pass --manual to run it explicitly on demand (agents must NEVER invoke this automatically)."
  exit 0
fi

set -- "${ARGS[@]+"${ARGS[@]}"}"

export PATH="/home/nick/.opencode/bin:/home/nick/.local/bin:${PATH}"
# shellcheck source=codex-lib.sh
source "/home/nick/Development/messaging-agent/.agents/scripts/codex-lib.sh"
cd "$CODEX_REPO_ROOT"

DIFF=""
CHANGED_LIST=""
if [ "${1:-}" = "--staged" ]; then
  DIFF=$(codex_staged_diff)
  CHANGED_LIST=$(codex_staged_files)
elif [ $# -gt 0 ]; then
  DIFF=$(git diff HEAD --no-color --no-ext-diff -- "$@" 2>/dev/null || true)
  CHANGED_LIST=$(git diff HEAD --name-only -- "$@" 2>/dev/null || true)
elif [ -n "$(codex_staged_files)" ]; then
  DIFF=$(codex_staged_diff)
  CHANGED_LIST=$(codex_staged_files)
else
  DIFF=$(git diff HEAD --no-color --no-ext-diff -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null || true)
  CHANGED_LIST=$(git diff HEAD --name-only -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null || true)
fi

if [ -z "$DIFF" ]; then
  echo "ℹ️  Stage-0 Pre-Check: No code changes in target scope."
  exit 0
fi

STAMP=$(date -u +%Y%m%dT%H:%M%SZ)
PROMPT_FILE="${CODEX_REPORT_DIR}/stage0-${STAMP}.prompt.md"
OUT_JSON="${CODEX_REPORT_DIR}/stage0-latest.json"

{
  cat <<'EOF'
# STAGE-0 PRE-GATE DEFECT CHECK (STRICT READ-ONLY)
Inspect the working-tree diff below BEFORE staging/commit. Identify ONLY genuine bugs,
null/concurrency/SQL/Flyway hazards, OWASP security flaws, or violations of workspace
invariants (`Locale.US` in `String.format`, no `java.sql.Timestamp` in native queries,
No-Hardcoded-Routing, UI design system preservation).
Do NOT modify any files. Write findings in Greek.
EOF
  echo ""
  echo "# CHANGED FILES"
  printf '%s\n' "$CHANGED_LIST"
  echo ""
  echo "# WORKING TREE DIFF"
  echo '```diff'
  printf '%s\n' "$DIFF" | head -c 250000 || true
  echo '```'
} > "$PROMPT_FILE"

echo "⚡ Running Stage-0 Pre-Check via OpenCode (DeepSeek)..."
opencode_run "stage0" "$OPENCODE_PRO_MODEL" "$CODEX_REVIEW_SCHEMA" "$OUT_JSON" "$PROMPT_FILE" 0

if [ "$CODEX_RUN_STATUS" != "OK" ] || [ ! -s "$OUT_JSON" ]; then
  echo "⚠️  Stage-0 Pre-Check skipped (${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR})"
  exit 0
fi

COUNTS=$(jq -c '[.findings[].severity] as $s | {CRITICAL:($s|map(select(.=="CRITICAL"))|length), HIGH:($s|map(select(.=="HIGH"))|length), MEDIUM:($s|map(select(.=="MEDIUM"))|length)}' "$OUT_JSON" 2>/dev/null || echo '{"CRITICAL":0,"HIGH":0,"MEDIUM":0}')
BLOCKING=$(echo "$COUNTS" | jq '(.CRITICAL // 0) + (.HIGH // 0)')

echo "📊 Stage-0 Pre-Check Findings: ${COUNTS}"
jq -r '.findings[]? | "  - [\(.severity)] \(.file):\(.line // "-") — \(.title): \(.recommendation)"' "$OUT_JSON" 2>/dev/null || true

if [ "$BLOCKING" -gt 0 ]; then
  echo "⚠️  Stage-0 caught ${BLOCKING} CRITICAL/HIGH issue(s) early! Fix them now before running Staging/Codex Gate."
  exit 1
fi
echo "✅ Stage-0 Pre-Check clean (0 CRITICAL/HIGH)."
exit 0

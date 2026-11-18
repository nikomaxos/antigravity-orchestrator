#!/usr/bin/env bash
# Manage Gemini Quota Reserve Mode (<10% Weekly/Monthly Limit -> 100% Non-Gemini Pass-Through)
# Usage:
#   bash .agents/scripts/gemini-quota-mode.sh --set-reserve [pct]   (0..9, default 8 -> activates <10% Reserve Mode)
#   bash .agents/scripts/gemini-quota-mode.sh --set-normal [pct]    (10..100, default 100 -> restores normal mode)
#   bash .agents/scripts/gemini-quota-mode.sh --is-reserve          (exits 0 if in <10% Reserve Mode, 1 otherwise)
#   bash .agents/scripts/gemini-quota-mode.sh --status              (read-only: prints JSON status without mutating disk)
#   bash .agents/scripts/gemini-quota-mode.sh --auto-status         (read-only: AUTOMATIC discrete 5h/weekly meter report via gemini-budget.js)
#   bash .agents/scripts/gemini-quota-mode.sh --auto-apply          (evaluate meter now and auto-switch reserve/normal; preflight does this every turn)
#   bash .agents/scripts/gemini-quota-mode.sh --sync-pct <0..100>   (anchor current 5h epoch remaining % to Antigravity UI)
#   bash .agents/scripts/gemini-quota-mode.sh --clear-sync          (clear any active UI sync anchor)
# NOTE: The trigger is AUTOMATIC (preflight -> gemini-budget.js, source="auto-meter"). Manual --set-reserve writes
#       source="manual" and is NEVER auto-restored; --set-normal (source="manual") lets the auto meter take over again.
set -euo pipefail

GLOBAL_STATE_FILE="${AGY_GEMINI_QUOTA_FILE:-$HOME/.gemini/config/gemini-quota.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUDGET_JS="${SCRIPT_DIR}/gemini-budget.js"
[ -f "$BUDGET_JS" ] || BUDGET_JS="${SCRIPT_DIR}/../workspace-template/.agents/scripts/gemini-budget.js"
[ -f "$BUDGET_JS" ] || BUDGET_JS="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.agents/scripts/gemini-budget.js"
THRESHOLD_PCT=10
MODE="${1:---status}"

usage() {
  cat >&2 <<'EOF'
Usage: gemini-quota-mode.sh <--set-reserve [0..9] | --set-normal [10..100] | --is-reserve | --status | --auto-status | --auto-apply | --sync-pct <0..100> | --clear-sync>
EOF
}

validate_pct() {
  local val="$1"
  if ! [[ "$val" =~ ^[0-9]{1,3}$ ]] || [ "$val" -gt 100 ]; then
    echo "ERROR: Percentage must be an integer between 0 and 100 (got: '$val')." >&2
    exit 1
  fi
}

build_json() {
  local reserve="$1"
  local pct="$2"
  local ts="$3"
  local allow_sub="true"
  if [ "$reserve" = "true" ]; then
    allow_sub="false"
  fi
  jq -n     --argjson pct "$pct"     --argjson threshold "$THRESHOLD_PCT"     --argjson reserve "$reserve"     --argjson allow_sub "$allow_sub"     --arg ts "$ts"     --arg src "${QUOTA_SOURCE:-manual}"     '{
      gemini_remaining_pct: $pct,
      threshold_pct: $threshold,
      reserve_passthrough_mode: $reserve,
      allow_gemini_subagents: $allow_sub,
      allow_gemini_flash_t1: $allow_sub,
      source: $src,
      t1_replacement: "Pool D (deepseek/deepseek-flash | deepseek-v4-pro) -> Pool C (claude-sonnet-5-5 low) -> Pool B (codex gpt-6-luna low)",
      t2_replacement: "Pool C (claude-sonnet-5-5 med) -> Pool B (codex gpt-6.1-terra med) -> Pool D (deepseek-v4-pro)",
      t3_replacement: "Pool B (codex gpt-6.1-sol high) -> Pool C (claude-sonnet-5-5 high) -> Pool D (deepseek-v4-pro)",
      t4_replacement: "Pool B (codex gpt-6-astra xhigh) -> Pool C (claude-opus-5-5 high) -> Pool D (deepseek-v4-pro)",
      updated_at: $ts
    }'
}

write_state_atomic() {
  local reserve="$1"
  local pct="$2"
  local dir tmp ts
  dir="$(dirname "$GLOBAL_STATE_FILE")"
  mkdir -p "$dir"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="$(mktemp "${dir}/.gemini-quota.XXXXXX.tmp")"
  build_json "$reserve" "$pct" "$ts" > "$tmp"
  mv -f "$tmp" "$GLOBAL_STATE_FILE"
}

case "$MODE" in
  --set-reserve)
    PCT="${2:-8}"
    validate_pct "$PCT"
    if [ "$PCT" -ge "$THRESHOLD_PCT" ]; then
      echo "ERROR: --set-reserve requires percentage < ${THRESHOLD_PCT}% (got ${PCT}%). Use --set-normal for >= ${THRESHOLD_PCT}%." >&2
      exit 1
    fi
    write_state_atomic "true" "$PCT"
    echo "🚨 GEMINI RESERVE PASS-THROUGH MODE ACTIVATED (Remaining=${PCT}% < ${THRESHOLD_PCT}%). ALL Gemini models (including Carbon, Neon, Hydrogen, Argon & 3.8 Flash) are replaced by Pools B/C/D."
    ;;
  --set-normal)
    PCT="${2:-100}"
    validate_pct "$PCT"
    if [ "$PCT" -lt "$THRESHOLD_PCT" ]; then
      echo "ERROR: --set-normal requires percentage >= ${THRESHOLD_PCT}% (got ${PCT}%). Use --set-reserve for < ${THRESHOLD_PCT}%." >&2
      exit 1
    fi
    write_state_atomic "false" "$PCT"
    echo "✅ GEMINI NORMAL ORCHESTRATOR MODE RESTORED (Remaining=${PCT}% >= ${THRESHOLD_PCT}%)."
    ;;
  --is-reserve)
    if [ -f "$GLOBAL_STATE_FILE" ] && jq -e '.reserve_passthrough_mode == true' "$GLOBAL_STATE_FILE" >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
    ;;
  --status)
    if [ -f "$GLOBAL_STATE_FILE" ] && jq -e . "$GLOBAL_STATE_FILE" >/dev/null 2>&1; then
      cat "$GLOBAL_STATE_FILE"
    else
      QUOTA_SOURCE=default build_json "false" 100 "default"
    fi
    ;;
  --auto-status|--auto-apply)
    if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUDGET_JS" ]; then
      echo "ERROR: node and gemini-budget.js are required for the automatic meter (looked at: $BUDGET_JS)." >&2
      exit 1
    fi
    if [ "$MODE" = "--auto-apply" ]; then
      node "$BUDGET_JS" --apply
    else
      node "$BUDGET_JS" --status
    fi
    ;;
  --sync-pct)
    PCT="${2:-}"
    if [ -z "$PCT" ]; then
      echo "ERROR: --sync-pct requires a percentage between 0 and 100." >&2
      exit 1
    fi
    validate_pct "$PCT"
    if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUDGET_JS" ]; then
      echo "ERROR: node and gemini-budget.js are required for --sync-pct (looked at: $BUDGET_JS)." >&2
      exit 1
    fi
    node "$BUDGET_JS" --sync-pct "$PCT"
    ;;
  --clear-sync)
    if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUDGET_JS" ]; then
      echo "ERROR: node and gemini-budget.js are required for --clear-sync (looked at: $BUDGET_JS)." >&2
      exit 1
    fi
    node "$BUDGET_JS" --clear-sync
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: Unknown argument '$MODE'." >&2
    usage
    exit 1
    ;;
esac

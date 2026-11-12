#!/usr/bin/env bash
# Manage Gemini Quota Reserve Mode (<10% Weekly/Monthly Limit -> 100% Non-Gemini Pass-Through)
# Usage:
#   bash .agents/scripts/gemini-quota-mode.sh --set-reserve [pct]   (0..9, default 8 -> activates <10% Reserve Mode)
#   bash .agents/scripts/gemini-quota-mode.sh --set-normal [pct]    (10..100, default 100 -> restores normal mode)
#   bash .agents/scripts/gemini-quota-mode.sh --is-reserve          (exits 0 if in <10% Reserve Mode, 1 otherwise)
#   bash .agents/scripts/gemini-quota-mode.sh --status              (read-only: prints JSON status without mutating disk)
set -euo pipefail

GLOBAL_STATE_FILE="$HOME/.gemini/config/gemini-quota.json"
THRESHOLD_PCT=10
MODE="${1:---status}"

usage() {
  cat >&2 <<'EOF'
Usage: gemini-quota-mode.sh <--set-reserve [0..9] | --set-normal [10..100] | --is-reserve | --status>
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
  jq -n     --argjson pct "$pct"     --argjson threshold "$THRESHOLD_PCT"     --argjson reserve "$reserve"     --argjson allow_sub "$allow_sub"     --arg ts "$ts"     '{
      gemini_remaining_pct: $pct,
      threshold_pct: $threshold,
      reserve_passthrough_mode: $reserve,
      allow_gemini_subagents: $allow_sub,
      allow_gemini_flash_t1: $allow_sub,
      t1_replacement: "Pool D (deepseek/deepseek-v4-pro | deepseek-flash) -> Pool C (claude sonnet low) -> Pool B (codex gpt-5.6-terra low)",
      t2_replacement: "Pool C (claude sonnet 4.6) -> Pool B (codex gpt-5.6-terra medium) -> Pool D (deepseek-v4-pro)",
      t3_replacement: "Pool B (codex gpt-6-astra high) -> Pool C (claude sonnet 4.6) -> Pool D (deepseek-v4-pro)",
      t4_replacement: "Pool B (codex gpt-6-astra xhigh) -> Pool C (claude opus 4.6 high) -> Pool D (deepseek-v4-pro)",
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
    echo "🚨 GEMINI RESERVE PASS-THROUGH MODE ACTIVATED (Remaining=${PCT}% < ${THRESHOLD_PCT}%). ALL Gemini models (including 3.8 Flash) are replaced by Pools B/C/D."
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
      build_json "false" 100 "default"
    fi
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

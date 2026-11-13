#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.opencode/bin:${HOME}/.local/bin:${PATH}"
SECRETS_ENV="${HOME}/.config/llm-council/secrets.env"
if [ -f "$SECRETS_ENV" ]; then
  # Only load if valid DEEPSEEK_API_KEY="sk-..." line is present
  if grep -qE '^DEEPSEEK_API_KEY="?sk-[A-Za-z0-9_-]+' "$SECRETS_ENV" 2>/dev/null; then
    # shellcheck disable=SC1090
    source "$SECRETS_ENV"
    export DEEPSEEK_API_KEY
  fi
fi

TIER="pro"
MODEL=""
WORKDIR="${PWD}"

if [[ "${1:-}" == "run" ]]; then
  shift
fi

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    -m|--model) MODEL="$2"; shift 2 ;;
    -C|--cd|--workdir) WORKDIR="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

CFG_FILE="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
[ ! -f "$CFG_FILE" ] && [ -f "${WORKDIR}/.agents/config/model-routing.json" ] && CFG_FILE="${WORKDIR}/.agents/config/model-routing.json"
if [ -f "$CFG_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_FLASH_MODEL=$(jq -r '.pools.pool_d.models.t1_flash.primary // "deepseek/deepseek-flash"' "$CFG_FILE" 2>/dev/null || echo "deepseek/deepseek-flash")
  DEFAULT_PRO_MODEL=$(jq -r '.pools.pool_d.models.pro_fallback.primary // "deepseek/deepseek-v4-pro"' "$CFG_FILE" 2>/dev/null || echo "deepseek/deepseek-v4-pro")
  DEFAULT_FREE_MODEL=$(jq -r '.pools.pool_d.models.t1_flash.free_fallback // "opencode/deepseek-v4.1-flash-free"' "$CFG_FILE" 2>/dev/null || echo "opencode/deepseek-v4.1-flash-free")
else
  DEFAULT_FLASH_MODEL="deepseek/deepseek-flash"
  DEFAULT_PRO_MODEL="deepseek/deepseek-v4-pro"
  DEFAULT_FREE_MODEL="opencode/deepseek-v4.1-flash-free"
fi

if [ -z "$MODEL" ]; then
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    case "$TIER" in
      flash|fast|t1) MODEL="$DEFAULT_FLASH_MODEL" ;;
      *)             MODEL="$DEFAULT_PRO_MODEL" ;;
    esac
  else
    MODEL="$DEFAULT_FREE_MODEL"
  fi
fi

PROMPT=""
if [ ${#POSITIONAL[@]} -gt 0 ]; then
  PROMPT="${POSITIONAL[*]}"
elif [ ! -t 0 ]; then
  PROMPT=$(cat)
fi
[ -z "$PROMPT" ] && { echo "ERROR: Empty prompt" >&2; exit 1; }

BIN=$(command -v opencode || true)
[ -z "$BIN" ] && { echo "ERROR: opencode binary not found" >&2; exit 2; }

echo ">>> [OpenCode Dispatcher] Tier=${TIER} | Model=${MODEL} | Agent=readonly-auditor"
"$BIN" run --dir "$WORKDIR" --agent readonly-auditor -m "$MODEL" -- "$PROMPT" < /dev/null

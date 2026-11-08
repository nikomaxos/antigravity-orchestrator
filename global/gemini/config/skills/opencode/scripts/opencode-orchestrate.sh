#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.opencode/bin:${HOME}/.local/bin:${PATH}"
SECRETS_ENV="${HOME}/.config/llm-council/secrets.env"
if [ -f "$SECRETS_ENV" ]; then
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

if [ -z "$MODEL" ]; then
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    case "$TIER" in
      flash|fast|t1) MODEL="deepseek/deepseek-flash" ;;
      *)             MODEL="deepseek/deepseek-v4-pro" ;;
    esac
  else
    MODEL="opencode/deepseek-v4.1-flash-free"
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

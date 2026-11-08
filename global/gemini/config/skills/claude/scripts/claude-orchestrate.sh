#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${PATH}"
TIER="backend"
MODEL=""
EFFORT=""
WORKDIR="${PWD}"
MAX_TURNS=25

if [[ "${1:-}" == "run" ]]; then
  shift
fi

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    -m|--model) MODEL="$2"; shift 2 ;;
    -e|--effort) EFFORT="$2"; shift 2 ;;
    -C|--cd|--workdir) WORKDIR="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

case "$TIER" in
  fast|t1)    : "${MODEL:=haiku}";  : "${EFFORT:=low}" ;;
  ui|t2)      : "${MODEL:=sonnet}"; : "${EFFORT:=medium}" ;;
  backend|t3) : "${MODEL:=sonnet}"; : "${EFFORT:=high}" ;;
  deep|t4)    : "${MODEL:=opus}";   : "${EFFORT:=high}" ;;
  *) echo "Invalid --tier: $TIER" >&2; exit 1 ;;
esac

PROMPT=""
if [ ${#POSITIONAL[@]} -gt 0 ]; then
  PROMPT="${POSITIONAL[*]}"
elif [ ! -t 0 ]; then
  PROMPT=$(cat)
fi
[ -z "$PROMPT" ] && { echo "ERROR: Empty prompt" >&2; exit 1; }

BIN=$(command -v claude || true)
[ -z "$BIN" ] && { echo "ERROR: claude binary not found (expected ~/.local/bin/claude)" >&2; exit 2; }

PROTECTED_RO=0
[ -f "${WORKDIR}/.agents/hooks.json" ] && PROTECTED_RO=1

echo ">>> [Claude Dispatcher] Tier=${TIER} | Model=${MODEL} | Effort=${EFFORT} | ProtectedRO=${PROTECTED_RO}"

cd "$WORKDIR"
if [ "$PROTECTED_RO" -eq 1 ]; then
  "$BIN" -p \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --permission-mode plan \
    --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
    --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" \
    --max-turns "$MAX_TURNS" \
    -- "$PROMPT"
else
  "$BIN" -p \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --permission-mode acceptEdits \
    --max-turns "$MAX_TURNS" \
    -- "$PROMPT"
fi

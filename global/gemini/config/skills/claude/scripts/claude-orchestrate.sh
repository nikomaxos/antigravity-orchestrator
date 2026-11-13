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

CFG_FILE="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
[ ! -f "$CFG_FILE" ] && [ -f "${WORKDIR}/.agents/config/model-routing.json" ] && CFG_FILE="${WORKDIR}/.agents/config/model-routing.json"
if [ -f "$CFG_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_T1_MODEL=$(jq -r '.pools.pool_c.models.t1_reserve.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "claude-sonnet-5-5")
  DEFAULT_T1_EFFORT=$(jq -r '.pools.pool_c.models.t1_reserve.primary_effort // "low"' "$CFG_FILE" 2>/dev/null || echo "low")
  DEFAULT_UI_MODEL=$(jq -r '.pools.pool_c.models.t2_ui.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "claude-sonnet-5-5")
  DEFAULT_UI_EFFORT=$(jq -r '.pools.pool_c.models.t2_ui.primary_effort // "medium"' "$CFG_FILE" 2>/dev/null || echo "medium")
  DEFAULT_BACKEND_MODEL=$(jq -r '.pools.pool_c.models.t3_backend.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "claude-sonnet-5-5")
  DEFAULT_BACKEND_EFFORT=$(jq -r '.pools.pool_c.models.t3_backend.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "high")
  DEFAULT_DEEP_MODEL=$(jq -r '.pools.pool_c.models.t4_deep.primary // "claude-opus-5-5"' "$CFG_FILE" 2>/dev/null || echo "claude-opus-5-5")
  DEFAULT_DEEP_EFFORT=$(jq -r '.pools.pool_c.models.t4_deep.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "high")
else
  DEFAULT_T1_MODEL="claude-sonnet-5-5"; DEFAULT_T1_EFFORT="low"
  DEFAULT_UI_MODEL="claude-sonnet-5-5"; DEFAULT_UI_EFFORT="medium"
  DEFAULT_BACKEND_MODEL="claude-sonnet-5-5"; DEFAULT_BACKEND_EFFORT="high"
  DEFAULT_DEEP_MODEL="claude-opus-5-5"; DEFAULT_DEEP_EFFORT="high"
fi

case "$TIER" in
  fast|t1)    : "${MODEL:=$DEFAULT_T1_MODEL}";  : "${EFFORT:=$DEFAULT_T1_EFFORT}" ;;
  ui|t2)      : "${MODEL:=$DEFAULT_UI_MODEL}"; : "${EFFORT:=$DEFAULT_UI_EFFORT}" ;;
  backend|t3) : "${MODEL:=$DEFAULT_BACKEND_MODEL}"; : "${EFFORT:=$DEFAULT_BACKEND_EFFORT}" ;;
  deep|t4)    : "${MODEL:=$DEFAULT_DEEP_MODEL}";   : "${EFFORT:=$DEFAULT_DEEP_EFFORT}" ;;
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

run_claude() {
  local target_model="$1"
  if [ "$PROTECTED_RO" -eq 1 ]; then
    "$BIN" -p \
      --model "$target_model" \
      --effort "$EFFORT" \
      --permission-mode plan \
      --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
      --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" \
      --max-turns "$MAX_TURNS" \
      -- "$PROMPT"
  else
    "$BIN" -p \
      --model "$target_model" \
      --effort "$EFFORT" \
      --permission-mode acceptEdits \
      --max-turns "$MAX_TURNS" \
      -- "$PROMPT"
  fi
}

cd "$WORKDIR"
if ! run_claude "$MODEL"; then
  FALLBACK_MODEL=""
  case "$MODEL" in
    *sonnet*) FALLBACK_MODEL="sonnet" ;;
    *opus*)   FALLBACK_MODEL="opus" ;;
    *haiku*)  FALLBACK_MODEL="haiku" ;;
  esac
  if [ -n "$FALLBACK_MODEL" ] && [ "$FALLBACK_MODEL" != "$MODEL" ]; then
    echo "⚠️  Model '${MODEL}' failed; retrying with fallback model '${FALLBACK_MODEL}'..." >&2
    run_claude "$FALLBACK_MODEL"
  fi
fi

#!/usr/bin/env bash
# =============================================================================
# Codex CLI Tier-Aware Dispatcher (`codex-orchestrate.sh`)
# =============================================================================
# Improvements over v1 (2026-11-05):
#   1. Tier routing (`--tier ui|backend|deep`):
#      - ui      -> gpt-5.6-terra (effort=medium, multi_agent=false)
#      - backend -> gpt-6-astra   (effort=high,   multi_agent=false) [DEFAULT]
#      - deep    -> gpt-6-astra   (effort=xhigh,  bounded max 2 subagents)
#   2. Single-Writer Workspace Safety: if `<workdir>/.agents/hooks.json` exists,
#      unconditionally runs in `-s read-only` Patch/Plan Producer mode.
# =============================================================================
set -euo pipefail

CODEX_TIER="${CODEX_TIER:-backend}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_EFFORT="${CODEX_EFFORT:-}"
CODEX_MULTI_AGENT="false"
CODEX_TIMEOUT_SECS="${CODEX_TIMEOUT_SECS:-3600}"
CODEX_WORKDIR="${PWD}"
RAW_PROMPT=0

STATE_ROOT="${CODEX_ORCHESTRATOR_STATE_DIR:-/tmp/codex-orchestrator-$(id -u)}"
mkdir -p "$STATE_ROOT"
chmod 700 "$STATE_ROOT"

codex_resolve_bin() {
  if [ -n "${CODEX_BIN:-}" ] && [ -x "${CODEX_BIN}" ]; then
    echo "${CODEX_BIN}"; return 0
  fi
  if [ -x "/home/nick/.npm-global/bin/codex" ]; then
    echo "/home/nick/.npm-global/bin/codex"; return 0
  fi
  if command -v codex >/dev/null 2>&1; then
    command -v codex; return 0
  fi
  local candidate=""
  candidate=$(ls -d "${HOME}/.antigravity/extensions/openai.chatgpt-"*/bin/linux-*/codex 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    echo "$candidate"; return 0
  fi
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  codex-orchestrate.sh run [OPTIONS] [PROMPT]
  codex-orchestrate.sh resume [OPTIONS] [SESSION_ID|--last] [PROMPT]
  codex-orchestrate.sh auto [OPTIONS] [PROMPT]
  codex-orchestrate.sh status [-C <dir>]
  codex-orchestrate.sh reset [-C <dir>]

Options:
  --tier <ui|backend|deep>  Task tier (default: backend)
  -C, --cd <dir>            Working directory for Codex (default: current directory)
  -m, --model <model>       Override Codex model
  -e, --effort <level>      Override reasoning effort: low|medium|high|xhigh
  -f, --file <path>         Read prompt instructions from file
  --raw                     Send prompt as-is without autonomous wrapper
  -h, --help                Show this help message
EOF
}

workspace_key() {
  realpath "$1" 2>/dev/null | sha256sum | awk '{print substr($1,1,16)}'
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  status)
    while [ $# -gt 0 ]; do
      case "$1" in -C|--cd) CODEX_WORKDIR="$2"; shift 2 ;; *) shift ;; esac
    done
    wkey=$(workspace_key "$CODEX_WORKDIR")
    echo "=== Codex Orchestrator Status ==="
    echo "Workspace: $(realpath "$CODEX_WORKDIR" 2>/dev/null || echo "$CODEX_WORKDIR")"
    echo "Codex Bin: $(codex_resolve_bin || echo 'NOT FOUND')"
    [ -f "${STATE_ROOT}/${wkey}.session_id" ] && echo "Last Session ID: $(cat "${STATE_ROOT}/${wkey}.session_id")" || echo "Last Session ID: (none)"
    [ -f "${STATE_ROOT}/${wkey}.last_meta" ] && cat "${STATE_ROOT}/${wkey}.last_meta"
    exit 0 ;;
  reset)
    while [ $# -gt 0 ]; do
      case "$1" in -C|--cd) CODEX_WORKDIR="$2"; shift 2 ;; *) shift ;; esac
    done
    wkey=$(workspace_key "$CODEX_WORKDIR")
    rm -f "${STATE_ROOT}/${wkey}.session_id" "${STATE_ROOT}/${wkey}.last_meta"
    echo "Cleared saved Codex session for workspace: $CODEX_WORKDIR"
    exit 0 ;;
  run|resume|auto) ;;
  *) echo "Unknown subcommand: $cmd" >&2; usage >&2; exit 1 ;;
esac

PROMPT_FILE=""
SESSION_TARGET=""
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) CODEX_TIER="$2"; shift 2 ;;
    -C|--cd|--workdir) CODEX_WORKDIR="$2"; shift 2 ;;
    -m|--model) CODEX_MODEL="$2"; shift 2 ;;
    -e|--effort) CODEX_EFFORT="$2"; shift 2 ;;
    -f|--file) PROMPT_FILE="$2"; shift 2 ;;
    --raw) RAW_PROMPT=1; shift ;;
    --last) SESSION_TARGET="--last"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

CFG_FILE="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
[ ! -f "$CFG_FILE" ] && [ -f "${CODEX_WORKDIR}/.agents/config/model-routing.json" ] && CFG_FILE="${CODEX_WORKDIR}/.agents/config/model-routing.json"
if [ -f "$CFG_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_UI_MODEL=$(jq -r '.pools.pool_b.models.t2_ui.primary // "gpt-6.1-terra"' "$CFG_FILE" 2>/dev/null || echo "gpt-6.1-terra")
  DEFAULT_UI_EFFORT=$(jq -r '.pools.pool_b.models.t2_ui.primary_effort // "medium"' "$CFG_FILE" 2>/dev/null || echo "medium")
  DEFAULT_BACKEND_MODEL=$(jq -r '.pools.pool_b.models.t3_backend.primary // "gpt-6.1-sol"' "$CFG_FILE" 2>/dev/null || echo "gpt-6.1-sol")
  DEFAULT_BACKEND_EFFORT=$(jq -r '.pools.pool_b.models.t3_backend.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "high")
  DEFAULT_DEEP_MODEL=$(jq -r '.pools.pool_b.models.t4_deep.primary // "gpt-6-astra"' "$CFG_FILE" 2>/dev/null || echo "gpt-6-astra")
  DEFAULT_DEEP_EFFORT=$(jq -r '.pools.pool_b.models.t4_deep.primary_effort // "xhigh"' "$CFG_FILE" 2>/dev/null || echo "xhigh")
  DEFAULT_FLASH_MODEL=$(jq -r '.pools.pool_b.models.t1_reserve.primary // "gpt-6-luna"' "$CFG_FILE" 2>/dev/null || echo "gpt-6-luna")
  DEFAULT_FLASH_EFFORT=$(jq -r '.pools.pool_b.models.t1_reserve.primary_effort // "low"' "$CFG_FILE" 2>/dev/null || echo "low")
else
  DEFAULT_UI_MODEL="gpt-6.1-terra"; DEFAULT_UI_EFFORT="medium"
  DEFAULT_BACKEND_MODEL="gpt-6.1-sol"; DEFAULT_BACKEND_EFFORT="high"
  DEFAULT_DEEP_MODEL="gpt-6-astra"; DEFAULT_DEEP_EFFORT="xhigh"
  DEFAULT_FLASH_MODEL="gpt-6-luna"; DEFAULT_FLASH_EFFORT="low"
fi

case "$CODEX_TIER" in
  flash|fast|t1)
    : "${CODEX_MODEL:=$DEFAULT_FLASH_MODEL}"
    : "${CODEX_EFFORT:=$DEFAULT_FLASH_EFFORT}"
    CODEX_MULTI_AGENT="false"
    ;;
  ui|t2)
    : "${CODEX_MODEL:=$DEFAULT_UI_MODEL}"
    : "${CODEX_EFFORT:=$DEFAULT_UI_EFFORT}"
    CODEX_MULTI_AGENT="false"
    ;;
  backend|t3)
    : "${CODEX_MODEL:=$DEFAULT_BACKEND_MODEL}"
    : "${CODEX_EFFORT:=$DEFAULT_BACKEND_EFFORT}"
    CODEX_MULTI_AGENT="false"
    ;;
  deep|t4)
    : "${CODEX_MODEL:=$DEFAULT_DEEP_MODEL}"
    : "${CODEX_EFFORT:=$DEFAULT_DEEP_EFFORT}"
    CODEX_MULTI_AGENT="true"
    ;;
  *)
    echo "ERROR: Invalid --tier '$CODEX_TIER' (must be flash, ui, backend, or deep)" >&2
    exit 1
    ;;
esac

SINGLE_WRITER_PROTECTED=0
if [ -f "${CODEX_WORKDIR}/.agents/hooks.json" ]; then
  SINGLE_WRITER_PROTECTED=1
fi

wkey=$(workspace_key "$CODEX_WORKDIR")
ts=$(date -u +%Y%m%dT%H%M%SZ)
EVENTS_FILE="${STATE_ROOT}/${wkey}-${ts}.events.jsonl"
STDERR_FILE="${STATE_ROOT}/${wkey}-${ts}.stderr.log"
OUT_FILE="${STATE_ROOT}/${wkey}-${ts}.last-message.md"
USER_PROMPT_FILE="${STATE_ROOT}/${wkey}-${ts}.user-prompt.md"
TMP_PROMPT="${STATE_ROOT}/${wkey}-${ts}.prompt.md"

if [ "$cmd" = "auto" ]; then
  if [ -f "${STATE_ROOT}/${wkey}.session_id" ] && [ -s "${STATE_ROOT}/${wkey}.session_id" ]; then
    cmd="resume"; SESSION_TARGET=$(cat "${STATE_ROOT}/${wkey}.session_id")
  else
    cmd="run"
  fi
elif [ "$cmd" = "resume" ]; then
  if [ -z "$SESSION_TARGET" ]; then
    if [ ${#POSITIONAL[@]} -gt 0 ] && [[ "${POSITIONAL[0]}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      SESSION_TARGET="${POSITIONAL[0]}"; POSITIONAL=("${POSITIONAL[@]:1}")
    elif [ -f "${STATE_ROOT}/${wkey}.session_id" ]; then
      SESSION_TARGET=$(cat "${STATE_ROOT}/${wkey}.session_id")
    else
      SESSION_TARGET="--last"
    fi
  fi
fi

if [ -n "$PROMPT_FILE" ]; then
  cat "$PROMPT_FILE" > "$USER_PROMPT_FILE"
elif [ ${#POSITIONAL[@]} -gt 0 ] && [ "${POSITIONAL[0]}" != "-" ]; then
  printf '%s\n' "${POSITIONAL[*]}" > "$USER_PROMPT_FILE"
elif [ ! -t 0 ]; then
  cat > "$USER_PROMPT_FILE"
else
  echo "ERROR: No prompt provided via argument, -f <file>, or stdin." >&2; exit 1
fi

if [ ! -s "$USER_PROMPT_FILE" ]; then
  echo "ERROR: Prompt is empty." >&2; exit 1
fi

if [ "$RAW_PROMPT" -eq 1 ]; then
  cat "$USER_PROMPT_FILE" > "$TMP_PROMPT"
elif [ "$SINGLE_WRITER_PROTECTED" -eq 1 ]; then
  cat > "$TMP_PROMPT" <<'MANDATE_RO_EOF'
<single_writer_readonly_mandate>
You are running in a kernel-enforced READ-ONLY sandbox inside a Single-Writer Gated Workspace.
Do NOT attempt to write, edit, or delete any files (Antigravity is the single writer and will apply your patch).
1. Inspect ONLY the directly relevant files (keep reads focused — do not scan the entire repo unnecessarily).
2. Design the exact solution and verify all edge cases, callers, and workspace rules (`AGENTS.md`).
3. Output your response in Greek (Ελληνικά) containing:
   - Root cause / architectural summary
   - Exact unified diff (`git diff` patch blocks) for every file Antigravity must apply
   - Exact test & verification commands Antigravity must execute
</single_writer_readonly_mandate>

## User Request
MANDATE_RO_EOF
  cat "$USER_PROMPT_FILE" >> "$TMP_PROMPT"
else
  cat > "$TMP_PROMPT" <<MANDATE_RW_EOF
<autonomous_execution_mandate>
You are executing a Tier='${CODEX_TIER}' task (Model=${CODEX_MODEL}, Effort=${CODEX_EFFORT}).
1. Inspect relevant files efficiently without redundant whole-repo scans.
2. Design and implement clean, surgical changes.
3. Sub-agents: $( [ "$CODEX_MULTI_AGENT" = "true" ] && echo "Allowed ONLY if strictly helpful (MAX 2 sub-agents)." || echo "DISABLED — execute directly in this single thread to conserve quota." )
4. Run targeted builds/tests and inspect \`git diff\` before concluding.
5. Write your final summary in Greek (Ελληνικά).
</autonomous_execution_mandate>

## User Request
MANDATE_RW_EOF
  cat "$USER_PROMPT_FILE" >> "$TMP_PROMPT"
fi

BIN=$(codex_resolve_bin) || { echo "ERROR: codex binary not found" >&2; exit 2; }
: > "$EVENTS_FILE"; : > "$STDERR_FILE"; rm -f "$OUT_FILE"

SANDBOX_ARGS=()
if [ "$SINGLE_WRITER_PROTECTED" -eq 1 ]; then
  SANDBOX_ARGS=(-s read-only)
else
  SANDBOX_ARGS=(-c 'sandbox_mode="workspace-write"')
fi

echo ">>> [Codex Dispatcher] Mode=${cmd} | Tier=${CODEX_TIER} | Model=${CODEX_MODEL} | Effort=${CODEX_EFFORT} | MultiAgent=${CODEX_MULTI_AGENT} | ProtectedRO=${SINGLE_WRITER_PROTECTED}"

rc=0
if [ "$cmd" = "run" ]; then
  timeout "$CODEX_TIMEOUT_SECS" "$BIN" exec \
    -C "$CODEX_WORKDIR" \
    "${SANDBOX_ARGS[@]}" \
    -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"${CODEX_EFFORT}\"" \
    -c "features.multi_agent=${CODEX_MULTI_AGENT}" \
    -c 'approval_policy="never"' \
    --skip-git-repo-check \
    --json \
    -o "$OUT_FILE" \
    - < "$TMP_PROMPT" > "$EVENTS_FILE" 2> "$STDERR_FILE" || rc=$?
else
  (
    cd "$CODEX_WORKDIR"
    timeout "$CODEX_TIMEOUT_SECS" "$BIN" exec resume "$SESSION_TARGET" \
      "${SANDBOX_ARGS[@]}" \
      -m "$CODEX_MODEL" \
      -c "model_reasoning_effort=\"${CODEX_EFFORT}\"" \
      -c "features.multi_agent=${CODEX_MULTI_AGENT}" \
      -c 'approval_policy="never"' \
      --skip-git-repo-check \
      --json \
      -o "$OUT_FILE" \
      - < "$TMP_PROMPT" > "$EVENTS_FILE" 2> "$STDERR_FILE"
  ) || rc=$?
fi

SESSION_ID=$(jq -r -R 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$EVENTS_FILE" 2>/dev/null | head -1 || true)
if [ -n "$SESSION_ID" ]; then
  echo "$SESSION_ID" > "${STATE_ROOT}/${wkey}.session_id"
elif [ -f "${STATE_ROOT}/${wkey}.session_id" ]; then
  SESSION_ID=$(cat "${STATE_ROOT}/${wkey}.session_id")
fi

USAGE=$(jq -c -R 'fromjson? | select(.usage) | .usage' "$EVENTS_FILE" 2>/dev/null | tail -1 || true)
[ -z "$USAGE" ] && USAGE="{}"

cat > "${STATE_ROOT}/${wkey}.last_meta" <<EOF
Last Run Timestamp: ${ts}
Last Mode: ${cmd} (tier=${CODEX_TIER}, protected_ro=${SINGLE_WRITER_PROTECTED})
Last Model: ${CODEX_MODEL} (effort=${CODEX_EFFORT}, multi_agent=${CODEX_MULTI_AGENT})
Last Exit Code: ${rc}
Last Usage: ${USAGE}
Last Output File: ${OUT_FILE}
EOF

echo ">>> [Codex Dispatcher] Session=${SESSION_ID:-unknown} | Exit=${rc} | Usage=${USAGE}"
if [ -s "$OUT_FILE" ]; then
  echo "==================== CODEX FINAL REPORT ===================="
  cat "$OUT_FILE"
  echo ""
  echo "============================================================"
else
  echo ">>> [Codex Dispatcher] WARNING: No final message output file produced." >&2
  jq -r -R 'fromjson? | select(.type=="error" or .type=="turn.failed") | . | tostring' "$EVENTS_FILE" 2>/dev/null | tail -10 >&2 || true
  cat "$STDERR_FILE" >&2 || true
fi
exit "$rc"

#!/usr/bin/env bash
# =============================================================================
# Codex CLI Tier-Aware Dispatcher (`codex-orchestrate.sh`)
# =============================================================================
# Tier routing (`--tier ui|backend|deep`):
#   - ui      -> gpt-5.6-terra (effort=medium, multi_agent=false)
#   - backend -> gpt-6-astra   (effort=high,   multi_agent=false) [DEFAULT]
#   - deep    -> gpt-6-astra   (effort=xhigh,  bounded max 2 subagents)
# Single-Writer Workspace Safety: if `<workdir>/.agents/hooks.json` exists,
# unconditionally runs in `-s read-only` Patch/Plan Producer mode.
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

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
  if [ -x "${HOME}/.local/share/mise/shims/codex" ]; then
    echo "${HOME}/.local/share/mise/shims/codex"; return 0
  fi
  if [ -x "${HOME}/.npm-global/bin/codex" ]; then
    echo "${HOME}/.npm-global/bin/codex"; return 0
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

case "$CODEX_TIER" in
  ui|t1|t2)
    : "${CODEX_MODEL:=gpt-5.6-terra}"
    : "${CODEX_EFFORT:=medium}"
    CODEX_MULTI_AGENT="false"
    ;;
  backend|t3)
    : "${CODEX_MODEL:=gpt-6-astra}"
    : "${CODEX_EFFORT:=high}"
    CODEX_MULTI_AGENT="false"
    ;;
  deep|t4)
    : "${CODEX_MODEL:=gpt-6-astra}"
    : "${CODEX_EFFORT:=xhigh}"
    CODEX_MULTI_AGENT="true"
    ;;
  *)
    echo "ERROR: Invalid --tier '$CODEX_TIER' (must be ui, backend, or deep)" >&2
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
  cat "$USER_PROMPT_FILE" > "$TMP_PROMPT"
fi

BIN=$(codex_resolve_bin) || {
  echo "ERROR: Codex CLI not found. Install Codex CLI or check ~/.npm-global/bin/codex" >&2
  exit 2
}

SANDBOX_MODE="read-only"
[ "$SINGLE_WRITER_PROTECTED" -eq 0 ] && SANDBOX_MODE="workspace-write"

echo ">>> [Codex Dispatcher] Mode=${cmd} | Tier=${CODEX_TIER} | Model=${CODEX_MODEL} | Effort=${CODEX_EFFORT} | MultiAgent=${CODEX_MULTI_AGENT} | Sandbox=${SANDBOX_MODE}"

RUN_ARGS=(
  -C "$CODEX_WORKDIR"
  -s "$SANDBOX_MODE"
  -m "$CODEX_MODEL"
  -c "model_reasoning_effort=\"${CODEX_EFFORT}\""
  -c "features.multi_agent=${CODEX_MULTI_AGENT}"
  --json
)

[ "$cmd" = "run" ] && RUN_ARGS+=(-o "$OUT_FILE")

CMD_EXEC=("$BIN" exec "${RUN_ARGS[@]}")
if [ "$cmd" = "resume" ]; then
  CMD_EXEC=("$BIN" exec resume "${RUN_ARGS[@]}" "$SESSION_TARGET" -)
else
  CMD_EXEC+=(-)
fi

set +e
timeout "$CODEX_TIMEOUT_SECS" "${CMD_EXEC[@]}" < "$TMP_PROMPT" > "$EVENTS_FILE" 2> "$STDERR_FILE"
EXIT_CODE=$?
set -e

rm -f "$TMP_PROMPT"

SESSION_ID=""
if [ -s "$EVENTS_FILE" ]; then
  SESSION_ID=$(jq -r -R 'fromjson? | select(.type=="session_started") | .session_id' "$EVENTS_FILE" 2>/dev/null | tail -1 || true)
  if [ -n "$SESSION_ID" ]; then
    echo "$SESSION_ID" > "${STATE_ROOT}/${wkey}.session_id"
    {
      echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "Tier: ${CODEX_TIER}"
      echo "Model: ${CODEX_MODEL}"
      echo "Effort: ${CODEX_EFFORT}"
      echo "Last Events: ${EVENTS_FILE}"
    } > "${STATE_ROOT}/${wkey}.last_meta"
  fi
fi

if [ -s "$OUT_FILE" ]; then
  cat "$OUT_FILE"
elif [ -s "$EVENTS_FILE" ]; then
  python3 - "$EVENTS_FILE" <<'PY' || true
import sys, json
path = sys.argv[1]
last_text = None
with open(path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "message" and item.get("role") == "assistant":
                parts = item.get("content") or []
                for p in parts:
                    if p.get("type") == "text" and p.get("text"):
                        last_text = p["text"]
if last_text:
    print(last_text)
PY
fi

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "" >&2
  echo "⚠️ Codex exited with code ${EXIT_CODE}" >&2
  [ -s "$STDERR_FILE" ] && tail -n 20 "$STDERR_FILE" >&2
  exit "$EXIT_CODE"
fi

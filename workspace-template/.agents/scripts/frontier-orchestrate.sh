#!/usr/bin/env bash
# =============================================================================
# External-First Frontier Orchestrator (`frontier-orchestrate.sh`)
# =============================================================================
# Unified CLI dispatcher that routes heavy reasoning, architecture, RCA, and
# surgical read-only patch design to External Frontier Pools (B/C/D) FIRST,
# preserving Pool A (`Gemini 4 Argon`) quota for orchestration & final fallback.
#
# Tier Cascades:
#   --tier ui      (T2 Frontend/UI/Tests):
#       Pool C (Claude Sonnet 4.6 med) -> Pool B (Codex gpt-5.6-terra med) -> Pool D (DeepSeek-V4-Pro)
#   --tier backend (T3 Multi-Service/Backend/CRUD/Migrations):
#       Pool B (Codex gpt-6-astra high) -> Pool C (Claude Sonnet 4.6 high) -> Pool D (DeepSeek-V4-Pro)
#   --tier deep    (T4 Critical Architecture/Concurrency/Protocols/Security):
#       Pool B (Codex gpt-6-astra xhigh) -> Pool C (Claude Opus 4.6 high) -> Pool D (DeepSeek-V4-Pro)
#   --tier flash   (T1 Log/Repo Scan):
#       Pool D (DeepSeek-Flash -> DeepSeek-V4-Pro -> Free Flash fallback)
#
# Exit Codes:
#   0 — External frontier pool succeeded (response printed to stdout & saved to .agent-reports/codex/frontier-latest.md)
#   2 — All external frontier pools (B/C/D) are exhausted/unavailable; caller MUST fall back to Pool A (Gemini 4 Argon Medium/High)
#   1 — Invalid arguments or usage error
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

TIER="backend"
PROMPT_TEXT=""
ATTACH_FILES=()
COOLDOWN_SECS="${FRONTIER_COOLDOWN_SECS:-900}"

usage() {
  cat <<'EOF'
Usage:
  bash .agents/scripts/frontier-orchestrate.sh --tier <ui|backend|deep|flash> [--prompt "<task>"] [--file <path>]...

Options:
  --tier <ui|backend|deep|flash>  Task tier routing cascade (default: backend):
                                    - ui      (T2): Pool C (Claude Sonnet 4.6) -> Pool B (Codex gpt-5.6-terra medium) -> Pool D (DeepSeek-V4-Pro)
                                    - backend (T3): Pool B (Codex gpt-6-astra high) -> Pool C (Claude Sonnet 4.6) -> Pool D (DeepSeek-V4-Pro)
                                    - deep    (T4): Pool B (Codex gpt-6-astra xhigh) -> Pool C (Claude Opus 4.6 high) -> Pool D (DeepSeek-V4-Pro)
                                    - flash   (T1): Pool D (DeepSeek-Flash / DeepSeek-V4-Pro)
  -p, --prompt "<text>"           Task prompt (can also be passed as positional args or via stdin)
  -f, -a, --file <path>           Attach repo-local file content into the prompt context (repeatable)
  -h, --help                      Show this help message and exit 0

Exit Codes:
  0  Success (frontier output written to stdout and .agent-reports/codex/frontier-latest.md)
  2  All external pools (B/C/D) exhausted/rate-limited -> Fall back to Pool A (Gemini 4 Argon Medium/High)
  1  Usage / argument error
EOF
}

validate_attach_file() {
  local raw_path="$1" resolved=""
  [ -f "$raw_path" ] || { echo "ERROR: Attached file not found: '${raw_path}'" >&2; exit 1; }
  resolved=$(realpath "$raw_path" 2>/dev/null || echo "")
  if command -v cygpath >/dev/null 2>&1; then
    resolved="$(cygpath -m "$resolved" 2>/dev/null || echo "$resolved")"
  fi
  local root_check="$CODEX_REPO_ROOT"
  if command -v cygpath >/dev/null 2>&1; then
    root_check="$(cygpath -m "$root_check" 2>/dev/null || echo "$root_check")"
  fi
  if [[ "$resolved" != "${root_check}/"* ]] && [[ "$resolved" != "$root_check" ]]; then
    echo "ERROR: Attached file must reside inside ${root_check} (got '${resolved}')" >&2
    exit 1
  fi
  if echo "$resolved" | grep -qiE '(/\.git/|/\.env|secret|\.key$|\.pem$|id_rsa)'; then
    echo "ERROR: Refusing to attach sensitive/secret path: '${resolved}'" >&2
    exit 1
  fi
  ATTACH_FILES+=("$resolved")
}

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "ERROR: --tier requires a non-empty value" >&2; exit 1; }
      TIER="$2"
      shift 2
      ;;
    -p|--prompt)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "ERROR: $1 requires a non-empty value" >&2; exit 1; }
      PROMPT_TEXT="$2"
      shift 2
      ;;
    -f|-a|--file|--attach)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "ERROR: $1 requires a file path" >&2; exit 1; }
      validate_attach_file "$2"
      shift 2
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done
      ;;
    -*)
      echo "ERROR: Unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

case "$TIER" in
  ui|t2|T2)          TIER="ui" ;;
  backend|t3|T3)     TIER="backend" ;;
  deep|t4|T4)        TIER="deep" ;;
  flash|fast|t1|T1)  TIER="flash" ;;
  *)
    echo "ERROR: Invalid --tier '$TIER' (expected: ui, backend, deep, or flash)" >&2
    usage >&2
    exit 1
    ;;
esac

if [ -z "$PROMPT_TEXT" ]; then
  if [ ${#POSITIONAL[@]} -gt 0 ]; then
    PROMPT_TEXT="${POSITIONAL[*]}"
  elif [ ! -t 0 ]; then
    PROMPT_TEXT="$(timeout 5 cat || true)"
  fi
fi

if [ -z "$PROMPT_TEXT" ]; then
  echo "ERROR: No prompt provided via --prompt, positional arguments, or stdin." >&2
  usage >&2
  exit 1
fi

mkdir -p "$CODEX_REPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
PROMPT_FILE="${CODEX_REPORT_DIR}/frontier-${TIER}-${STAMP}.prompt.md"
OUT_FILE="${CODEX_REPORT_DIR}/frontier-${TIER}-${STAMP}.md"
LATEST_LINK="${CODEX_REPORT_DIR}/frontier-latest.md"
trap 'rm -f "${PROMPT_FILE:-}"' EXIT

# Build read-only single-writer prompt with optional file attachments
{
  cat <<'EOF'
# SINGLE-WRITER READ-ONLY FRONTIER MANDATE
You are running as an external Frontier Architect & Patch Designer inside a kernel-enforced READ-ONLY sandbox.
Antigravity (Pool A) is the single writer and will apply your changes and execute tests.
1. Inspect ONLY the directly relevant files.
2. Respect all workspace invariants in `AGENTS.md`.
3. Produce a concise, actionable response in Greek (Ελληνικά) containing:
   - Root cause or architectural design summary
   - Exact unified diff (`git diff` / replacement blocks) with file paths and line numbers
   - Exact verification / test commands to run

## Task Request
EOF
  printf '%s\n' "$PROMPT_TEXT"

  if [ ${#ATTACH_FILES[@]} -gt 0 ]; then
    echo ""
    echo "## Attached Context Files"
    for af in "${ATTACH_FILES[@]}"; do
      echo ""
      echo "### File: \`${af#"$CODEX_REPO_ROOT"/}\`"
      echo '```'
      head -c "$CODEX_MAX_ATTACH_BYTES" "$af"
      echo ""
      echo '```'
    done
  fi
} > "$PROMPT_FILE"

pool_in_cooldown() {
  codex_pool_in_cooldown "$1" "${COOLDOWN_SECS:-900}"
}

try_pool_b_codex() {
  local model="$1" effort="$2" label="$3"
  if pool_in_cooldown "codex:${model}"; then
    echo "⏭️  [Frontier Orchestrator] Skipping Pool B (${label}) — in cooldown from recent RATE_LIMITED/UNAVAILABLE." >&2
    CODEX_RUN_STATUS="COOLDOWN"
    return 1
  fi
  echo ">>> [Frontier Orchestrator] Tier=${TIER} | Trying Pool B: OpenAI Codex (${label}, model=${model}, effort=${effort}, sandbox=read-only)..." >&2
  codex_run "frontier-${TIER}" "$model" "$effort" "" "$OUT_FILE" "$PROMPT_FILE"
  if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$OUT_FILE" ]; then
    echo "✅ [Frontier Orchestrator] Pool B (${label}) succeeded." >&2
    return 0
  fi
  echo "⚠️  [Frontier Orchestrator] Pool B (${label}) status=${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-none}" >&2
  return 1
}

try_pool_c_claude() {
  local model="$1" effort="$2" label="$3"
  if pool_in_cooldown "claude:${model}"; then
    echo "⏭️  [Frontier Orchestrator] Skipping Pool C (${label}) — in cooldown from recent RATE_LIMITED/UNAVAILABLE." >&2
    CODEX_RUN_STATUS="COOLDOWN"
    return 1
  fi
  echo ">>> [Frontier Orchestrator] Tier=${TIER} | Trying Pool C: Anthropic Claude Code (${label}, model=${model}, effort=${effort}, mode=plan)..." >&2
  claude_run "frontier-${TIER}" "$model" "$effort" "" "$OUT_FILE" "$PROMPT_FILE"
  if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$OUT_FILE" ]; then
    echo "✅ [Frontier Orchestrator] Pool C (${label}) succeeded." >&2
    return 0
  fi
  echo "⚠️  [Frontier Orchestrator] Pool C (${label}) status=${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-none}" >&2
  return 1
}

try_pool_d_deepseek() {
  local model="$1" req_paid="$2" label="$3"
  echo ">>> [Frontier Orchestrator] Tier=${TIER} | Trying Pool D: OpenCode DeepSeek (${label}, model=${model}, agent=readonly-auditor)..." >&2
  opencode_run "frontier-${TIER}" "$model" "" "$OUT_FILE" "$PROMPT_FILE" "$req_paid"
  if [ "$CODEX_RUN_STATUS" = "OK" ] && [ -s "$OUT_FILE" ]; then
    echo "✅ [Frontier Orchestrator] Pool D (${label}) succeeded." >&2
    return 0
  fi
  echo "⚠️  [Frontier Orchestrator] Pool D (${label}) status=${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR:-none}" >&2
  return 1
}

SUCCEEDED=0

case "$TIER" in
  ui)
    if try_pool_c_claude "sonnet" "medium" "Claude Sonnet 4.6 (Medium)"; then
      SUCCEEDED=1
    elif try_pool_b_codex "gpt-5.6-terra" "medium" "Codex gpt-5.6-terra (Medium)"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  backend)
    if try_pool_b_codex "gpt-6-astra" "high" "Codex gpt-6-astra (High)"; then
      SUCCEEDED=1
    elif try_pool_c_claude "sonnet" "high" "Claude Sonnet 4.6 (High)"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  deep)
    if try_pool_b_codex "gpt-6-astra" "xhigh" "Codex gpt-6-astra (xhigh)"; then
      SUCCEEDED=1
    elif try_pool_c_claude "opus" "high" "Claude Opus 4.6 (High)"; then
      SUCCEEDED=1
    elif try_pool_c_claude "sonnet" "high" "Claude Sonnet 4.6 (High)"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  flash)
    if try_pool_d_deepseek "$OPENCODE_FLASH_MODEL" 0 "DeepSeek-Flash"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
esac

rm -f "$PROMPT_FILE"

if [ "$SUCCEEDED" -eq 1 ] && [ -s "$OUT_FILE" ]; then
  ln -sf "$(basename "$OUT_FILE")" "$LATEST_LINK"
  cat "$OUT_FILE"
  exit 0
fi

echo "⛔ [Frontier Orchestrator] All external frontier pools (B/C/D) for --tier ${TIER} are exhausted or unavailable." >&2
echo "➡️  Caller MUST fall back to Pool A (Antigravity Gemini 4 Argon Medium/High)." >&2
exit 2

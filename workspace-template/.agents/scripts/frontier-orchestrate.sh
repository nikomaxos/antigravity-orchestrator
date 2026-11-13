#!/usr/bin/env bash
# =============================================================================
# External-First Frontier Orchestrator (`frontier-orchestrate.sh`)
# =============================================================================
# Unified CLI dispatcher that routes heavy reasoning, architecture, RCA, and
# surgical read-only patch design to External Frontier Pools (B/C/D) FIRST,
# preserving Pool A (`Gemini 4 Carbon`) quota for orchestration & final fallback.
#
# Tier Cascades:
#   --tier ui      (T2 React/TS/UI/Tests):
#       Pool C (Claude Sonnet 5.5 med) -> Pool B (Codex gpt-6.1-terra med) -> Pool D (DeepSeek-V4-Pro)
#   --tier backend (T3 Multi-Service/CRUD/Flyway):
#       Pool B (Codex gpt-6.1-sol high) -> Pool C (Claude Sonnet 5.5 high) -> Pool D (DeepSeek-V4-Pro)
#   --tier deep    (T4 Concurrency/SMPP/Hardware/Security/Architecture):
#       Pool B (Codex gpt-6-astra xhigh) -> Pool C (Claude Opus 5.5 high) -> Pool D (DeepSeek-V4-Pro)
#   --tier flash   (T1 Log/Repo Scan):
#       Pool D (DeepSeek-Flash -> DeepSeek-V4-Pro) -> Pool C (Claude Sonnet 5.5 low) -> Pool B (Codex gpt-6-luna low)
#
# Exit Codes:
#   0 — External frontier pool succeeded (response printed to stdout & saved to .agent-reports/codex/frontier-latest.md)
#   2 — All external frontier pools (B/C/D) are exhausted/unavailable; caller MUST fall back to Pool A (Gemini 4 Carbon Medium/High)
#   1 — Invalid arguments or usage error
# =============================================================================
set -euo pipefail

export HOME="${HOME:-/home/nick}"
export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
                                    - ui      (T2): Pool C (Claude Sonnet 5.5) -> Pool B (Codex gpt-6.1-terra medium) -> Pool D (DeepSeek-V4-Pro)
                                    - backend (T3): Pool B (Codex gpt-6.1-sol high) -> Pool C (Claude Sonnet 5.5) -> Pool D (DeepSeek-V4-Pro)
                                    - deep    (T4): Pool B (Codex gpt-6-astra xhigh) -> Pool C (Claude Opus 5.5 high) -> Pool D (DeepSeek-V4-Pro)
                                    - flash   (T1): Pool D (DeepSeek-Flash / DeepSeek-V4-Pro) -> Pool C (Claude Sonnet 5.5 low) -> Pool B (Codex gpt-6-luna low)
  -p, --prompt "<text>"           Task prompt (can also be passed as positional args or via stdin)
  -f, -a, --file <path>           Attach repo-local file content into the prompt context (repeatable)
  -h, --help                      Show this help message and exit 0

Exit Codes:
  0  Success (frontier output written to stdout and .agent-reports/codex/frontier-latest.md)
  2  All external pools (B/C/D) exhausted/rate-limited -> Fall back to Pool A (Gemini 4 Carbon Medium/High)
  1  Usage / argument error
EOF
}

validate_attach_file() {
  local raw_path="$1" resolved=""
  [ -f "$raw_path" ] || { echo "ERROR: Attached file not found: '${raw_path}'" >&2; exit 1; }
  resolved=$(realpath "$raw_path" 2>/dev/null || echo "")
  if [[ "$resolved" != "${CODEX_REPO_ROOT}/"* ]]; then
    echo "ERROR: Attached file must reside inside ${CODEX_REPO_ROOT} (got '${resolved}')" >&2
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
1. Inspect ONLY the directly relevant files (do not scan unrelated microservices).
2. Respect all workspace invariants in `AGENTS.md` (No-Hardcoded-Routing, `String.format(Locale.US, ...)`, no `java.sql.Timestamp` in native queries, and `.agents/knowledge/ui-design-system.md` for Admin Panel UI).
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

# Delegate cooldown check to shared codex_pool_in_cooldown in codex-lib.sh
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

# Load dynamic tier settings from model-routing.json if available
CFG_FILE="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
[ ! -f "$CFG_FILE" ] && [ -f "${CODEX_REPO_ROOT}/.agents/config/model-routing.json" ] && CFG_FILE="${CODEX_REPO_ROOT}/.agents/config/model-routing.json"

TIER_UI_C_MODEL="claude-sonnet-5-5"
TIER_UI_C_EFFORT="medium"
TIER_UI_B_MODEL="gpt-6.1-terra"
TIER_UI_B_FALLBACK="gpt-6.1-sol"
TIER_UI_B_EFFORT="medium"

TIER_BACKEND_B_MODEL="gpt-6.1-sol"
TIER_BACKEND_B_FALLBACK="gpt-6-astra"
TIER_BACKEND_B_EFFORT="high"
TIER_BACKEND_C_MODEL="claude-sonnet-5-5"
TIER_BACKEND_C_EFFORT="high"

TIER_DEEP_B_MODEL="gpt-6-astra"
TIER_DEEP_B_FALLBACK="gpt-6.1-sol"
TIER_DEEP_B_EFFORT="xhigh"
TIER_DEEP_C_MODEL="claude-opus-5-5"
TIER_DEEP_C_FALLBACK="claude-sonnet-5-5"
TIER_DEEP_C_FALLBACK_EFFORT="high"
TIER_DEEP_C_EFFORT="high"

TIER_FLASH_B_MODEL="gpt-6-luna"
TIER_FLASH_B_FALLBACK="gpt-reserve"
TIER_FLASH_B_EFFORT="low"
TIER_FLASH_C_MODEL="claude-sonnet-5-5"
TIER_FLASH_C_EFFORT="low"

if [ -f "$CFG_FILE" ] && command -v jq >/dev/null 2>&1; then
  TIER_UI_C_MODEL=$(jq -r '.pools.pool_c.models.t2_ui.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "$TIER_UI_C_MODEL")
  TIER_UI_C_EFFORT=$(jq -r '.pools.pool_c.models.t2_ui.primary_effort // "medium"' "$CFG_FILE" 2>/dev/null || echo "$TIER_UI_C_EFFORT")
  TIER_UI_B_MODEL=$(jq -r '.pools.pool_b.models.t2_ui.primary // "gpt-6.1-terra"' "$CFG_FILE" 2>/dev/null || echo "$TIER_UI_B_MODEL")
  TIER_UI_B_FALLBACK=$(jq -r '.pools.pool_b.models.t2_ui.fallback // "gpt-6.1-sol"' "$CFG_FILE" 2>/dev/null || echo "$TIER_UI_B_FALLBACK")
  TIER_UI_B_EFFORT=$(jq -r '.pools.pool_b.models.t2_ui.primary_effort // "medium"' "$CFG_FILE" 2>/dev/null || echo "$TIER_UI_B_EFFORT")

  TIER_BACKEND_B_MODEL=$(jq -r '.pools.pool_b.models.t3_backend.primary // "gpt-6.1-sol"' "$CFG_FILE" 2>/dev/null || echo "$TIER_BACKEND_B_MODEL")
  TIER_BACKEND_B_FALLBACK=$(jq -r '.pools.pool_b.models.t3_backend.fallback // "gpt-6-astra"' "$CFG_FILE" 2>/dev/null || echo "$TIER_BACKEND_B_FALLBACK")
  TIER_BACKEND_B_EFFORT=$(jq -r '.pools.pool_b.models.t3_backend.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "$TIER_BACKEND_B_EFFORT")
  TIER_BACKEND_C_MODEL=$(jq -r '.pools.pool_c.models.t3_backend.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "$TIER_BACKEND_C_MODEL")
  TIER_BACKEND_C_EFFORT=$(jq -r '.pools.pool_c.models.t3_backend.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "$TIER_BACKEND_C_EFFORT")

  TIER_DEEP_B_MODEL=$(jq -r '.pools.pool_b.models.t4_deep.primary // "gpt-6-astra"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_B_MODEL")
  TIER_DEEP_B_FALLBACK=$(jq -r '.pools.pool_b.models.t4_deep.fallback // "gpt-6.1-sol"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_B_FALLBACK")
  TIER_DEEP_B_EFFORT=$(jq -r '.pools.pool_b.models.t4_deep.primary_effort // "xhigh"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_B_EFFORT")
  TIER_DEEP_C_MODEL=$(jq -r '.pools.pool_c.models.t4_deep.primary // "claude-opus-5-5"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_C_MODEL")
  TIER_DEEP_C_FALLBACK=$(jq -r '.pools.pool_c.models.t4_deep.secondary_fallback // .pools.pool_c.models.t4_deep.fallback // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_C_FALLBACK")
  TIER_DEEP_C_FALLBACK_EFFORT=$(jq -r '.pools.pool_c.models.t4_deep.secondary_fallback_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "high")
  TIER_DEEP_C_EFFORT=$(jq -r '.pools.pool_c.models.t4_deep.primary_effort // "high"' "$CFG_FILE" 2>/dev/null || echo "$TIER_DEEP_C_EFFORT")

  TIER_FLASH_B_MODEL=$(jq -r '.pools.pool_b.models.t1_reserve.primary // "gpt-6-luna"' "$CFG_FILE" 2>/dev/null || echo "$TIER_FLASH_B_MODEL")
  TIER_FLASH_B_FALLBACK=$(jq -r '.pools.pool_b.models.t1_reserve.fallback // "gpt-reserve"' "$CFG_FILE" 2>/dev/null || echo "$TIER_FLASH_B_FALLBACK")
  TIER_FLASH_B_EFFORT=$(jq -r '.pools.pool_b.models.t1_reserve.primary_effort // "low"' "$CFG_FILE" 2>/dev/null || echo "$TIER_FLASH_B_EFFORT")
  TIER_FLASH_C_MODEL=$(jq -r '.pools.pool_c.models.t1_reserve.primary // "claude-sonnet-5-5"' "$CFG_FILE" 2>/dev/null || echo "$TIER_FLASH_C_MODEL")
  TIER_FLASH_C_EFFORT=$(jq -r '.pools.pool_c.models.t1_reserve.primary_effort // "low"' "$CFG_FILE" 2>/dev/null || echo "$TIER_FLASH_C_EFFORT")
fi

SUCCEEDED=0

case "$TIER" in
  ui)
    # Cascade: Pool C (Claude Sonnet 5.5) -> Pool B (Codex gpt-6.1-terra / sol) -> Pool D (DeepSeek-V4-Pro)
    if try_pool_c_claude "$TIER_UI_C_MODEL" "$TIER_UI_C_EFFORT" "Claude ${TIER_UI_C_MODEL} (${TIER_UI_C_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_b_codex "$TIER_UI_B_MODEL" "$TIER_UI_B_EFFORT" "Codex ${TIER_UI_B_MODEL} (${TIER_UI_B_EFFORT})"; then
      SUCCEEDED=1
    elif [ -n "$TIER_UI_B_FALLBACK" ] && try_pool_b_codex "$TIER_UI_B_FALLBACK" "$TIER_UI_B_EFFORT" "Codex ${TIER_UI_B_FALLBACK} (${TIER_UI_B_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  backend)
    # Cascade: Pool B (Codex gpt-6.1-sol / astra) -> Pool C (Claude Sonnet 5.5) -> Pool D (DeepSeek-V4-Pro)
    if try_pool_b_codex "$TIER_BACKEND_B_MODEL" "$TIER_BACKEND_B_EFFORT" "Codex ${TIER_BACKEND_B_MODEL} (${TIER_BACKEND_B_EFFORT})"; then
      SUCCEEDED=1
    elif [ -n "$TIER_BACKEND_B_FALLBACK" ] && try_pool_b_codex "$TIER_BACKEND_B_FALLBACK" "$TIER_BACKEND_B_EFFORT" "Codex ${TIER_BACKEND_B_FALLBACK} (${TIER_BACKEND_B_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_c_claude "$TIER_BACKEND_C_MODEL" "$TIER_BACKEND_C_EFFORT" "Claude ${TIER_BACKEND_C_MODEL} (${TIER_BACKEND_C_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  deep)
    # Cascade: Pool B (Codex gpt-6-astra / sol) -> Pool C (Claude Opus 5.5 / sonnet) -> Pool D (DeepSeek-V4-Pro)
    if try_pool_b_codex "$TIER_DEEP_B_MODEL" "$TIER_DEEP_B_EFFORT" "Codex ${TIER_DEEP_B_MODEL} (${TIER_DEEP_B_EFFORT})"; then
      SUCCEEDED=1
    elif [ -n "$TIER_DEEP_B_FALLBACK" ] && try_pool_b_codex "$TIER_DEEP_B_FALLBACK" "$TIER_DEEP_B_EFFORT" "Codex ${TIER_DEEP_B_FALLBACK} (${TIER_DEEP_B_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_c_claude "$TIER_DEEP_C_MODEL" "$TIER_DEEP_C_EFFORT" "Claude ${TIER_DEEP_C_MODEL} (${TIER_DEEP_C_EFFORT})"; then
      SUCCEEDED=1
    elif [ -n "$TIER_DEEP_C_FALLBACK" ] && try_pool_c_claude "$TIER_DEEP_C_FALLBACK" "$TIER_DEEP_C_FALLBACK_EFFORT" "Claude ${TIER_DEEP_C_FALLBACK} (${TIER_DEEP_C_FALLBACK_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    fi
    ;;
  flash)
    # Cascade (T1 / Zero-Gemini Flash Replacement): Pool D (DeepSeek-Flash -> DeepSeek-V4-Pro) -> Pool C (Claude Sonnet 5.5 low) -> Pool B (Codex gpt-6-luna / reserve low)
    if try_pool_d_deepseek "$OPENCODE_FLASH_MODEL" 0 "DeepSeek-Flash"; then
      SUCCEEDED=1
    elif try_pool_d_deepseek "$OPENCODE_PRO_MODEL" 0 "DeepSeek-V4-Pro"; then
      SUCCEEDED=1
    elif try_pool_c_claude "$TIER_FLASH_C_MODEL" "$TIER_FLASH_C_EFFORT" "Claude ${TIER_FLASH_C_MODEL} (${TIER_FLASH_C_EFFORT})"; then
      SUCCEEDED=1
    elif try_pool_b_codex "$TIER_FLASH_B_MODEL" "$TIER_FLASH_B_EFFORT" "Codex ${TIER_FLASH_B_MODEL} (${TIER_FLASH_B_EFFORT})"; then
      SUCCEEDED=1
    elif [ -n "$TIER_FLASH_B_FALLBACK" ] && try_pool_b_codex "$TIER_FLASH_B_FALLBACK" "$TIER_FLASH_B_EFFORT" "Codex ${TIER_FLASH_B_FALLBACK} (${TIER_FLASH_B_EFFORT})"; then
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
echo "➡️  Caller MUST fall back to Pool A (Antigravity Gemini 4 Carbon Medium/High)." >&2
exit 2

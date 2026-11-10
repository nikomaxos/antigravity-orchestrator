#!/usr/bin/env bash
# =============================================================================
# Cross-Model Deep RCA (`codex-rca.sh`) — Read-Only Multi-CLI Cascade
# =============================================================================
# Cascade order:
#   1. Pool B: OpenAI Codex CLI (`gpt-6-astra`, effort `xhigh`)
#   2. Pool C: Anthropic Claude Code CLI (`opus` -> `sonnet`, effort `high`)
#   3. Pool D: OpenCode CLI + DeepSeek API (`deepseek/deepseek-v4-pro`)
#   4. Pool A: Exit 2 -> spawn internal `Gemini 4 Carbon High` subagent
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"
cd "$CODEX_REPO_ROOT"

MODEL="$CODEX_RCA_MODEL"; EFFORT="$CODEX_RCA_EFFORT"; ATTACH=(); PROBLEM=""
PREFER_CLI="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--attach) ATTACH+=("${2:?missing file}"); shift 2 ;;
    -e|--effort) EFFORT="${2:?missing level}"; shift 2 ;;
    -m|--model)  MODEL="${2:?missing model}"; shift 2 ;;
    --cli)       PREFER_CLI="${2:?missing cli (auto|codex|claude|opencode)}"; shift 2 ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    --) shift; PROBLEM="$*"; break ;;
    *)  PROBLEM="${PROBLEM:+$PROBLEM }$1"; shift ;;
  esac
done
if [ -z "$PROBLEM" ] && [ ! -t 0 ]; then PROBLEM=$(cat); fi
if [ -z "$PROBLEM" ]; then echo "❌ Provide a problem description (argument or stdin)." >&2; exit 3; fi

mkdir -p "$CODEX_REPORT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${CODEX_REPORT_DIR}/rca-${STAMP}.md"
PROMPT_FILE="${CODEX_REPORT_DIR}/rca-${STAMP}.prompt.md"

{
  cat <<'EOF'
# ROLE
You are a principal engineer performing ROOT-CAUSE ANALYSIS.
You run in a READ-ONLY sandbox. NEVER attempt to modify files. Only run focused read-only
commands (git log/show/diff/blame, cat, grep, rg, find, ls) on directly relevant paths.
If a command is blocked by the sandbox (e.g. docker, network), list it under
"Commands for the implementation agent".

# METHOD
1. Restate the symptom precisely.
2. Trace the real execution path in the code (entry point -> failure point).
3. Form hypotheses, then confirm or eliminate each with evidence (`file:line`, git history, logs).
4. Identify THE root cause (not the symptom). If uncertain, rank candidates with probabilities.
5. Propose the minimal correct fix and its regression surface.

# OUTPUT (Markdown in Greek; keep identifiers/paths/commands in English)
## Σύνοψη
## Σύμπτωμα
## Root Cause (with `path:line` & code excerpts)
## Confidence (High / Medium / Low + why)
## Υποθέσεις που αποκλείστηκαν
## Προτεινόμενη διόρθωση (exact files/functions/diff)
## Regression surface
## Βήματα επαλήθευσης ("Symptom Assertion")
## Commands for the implementation agent

# WORKSPACE RULES & CONTEXT
EOF
  codex_build_context
  echo
  echo "# REPOSITORY STATE"
  codex_repo_state
  echo
  echo "# PROBLEM REPORTED"
  printf '%s\n' "$PROBLEM"
  for f in "${ATTACH[@]+"${ATTACH[@]}"}"; do
    echo
    if [ -f "$f" ]; then
      SIZE=$(wc -c < "$f")
      echo "# ATTACHMENT: $f (${SIZE} bytes$([ "$SIZE" -gt "$CODEX_MAX_ATTACH_BYTES" ] && echo ", last ${CODEX_MAX_ATTACH_BYTES} shown"))"
      echo '```'; tail -c "$CODEX_MAX_ATTACH_BYTES" "$f"; echo; echo '```'
    else
      echo "# ATTACHMENT: $f (NOT FOUND)"
    fi
  done
} > "$PROMPT_FILE"

USED_LABEL=""

if [ "$PREFER_CLI" = "auto" ] || [ "$PREFER_CLI" = "codex" ]; then
  echo "🤖 [Pool B] Codex RCA: model=${MODEL} effort=${EFFORT} (read-only)..."
  codex_run "rca" "$MODEL" "$EFFORT" "" "$OUT" "$PROMPT_FILE"
  [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ Codex ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
  [ "$CODEX_RUN_STATUS" = "OK" ] && USED_LABEL="Codex (${MODEL}, effort ${EFFORT})"
fi

if [ -z "$USED_LABEL" ] && { [ "$PREFER_CLI" = "auto" ] || [ "$PREFER_CLI" = "claude" ]; }; then
  echo "🤖 [Pool C] Failing over RCA to Claude Code CLI (model=opus, effort=high)..."
  claude_run "rca" "opus" "high" "" "$OUT" "$PROMPT_FILE"
  [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ Claude ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
  [ "$CODEX_RUN_STATUS" = "OK" ] && USED_LABEL="Claude Code (opus, effort high)"
fi

if [ -z "$USED_LABEL" ] && { [ "$PREFER_CLI" = "auto" ] || [ "$PREFER_CLI" = "opencode" ]; }; then
  echo "🤖 [Pool D] Failing over RCA to OpenCode CLI (model=${OPENCODE_PRO_MODEL})..."
  opencode_run "rca" "$OPENCODE_PRO_MODEL" "" "$OUT" "$PROMPT_FILE" 0
  [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ OpenCode ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
  [ "$CODEX_RUN_STATUS" = "OK" ] && USED_LABEL="OpenCode (${OPENCODE_PRO_MODEL})"
fi

rm -f "$PROMPT_FILE"

if [ -n "$USED_LABEL" ] && [ -s "$OUT" ]; then
  ln -sf "$(basename "$OUT")" "${CODEX_REPORT_DIR}/rca-latest.md"
  echo "✅ RCA completed by ${USED_LABEL}"
  echo "📄 Report saved to: ${OUT} (symlinked to ${CODEX_REPORT_DIR}/rca-latest.md)"
  cat "$OUT"
  exit 0
fi

echo "⚠️  All external RCA models failed / rate-limited."
echo "➡️  Falling back to Pool A: Spawn internal Gemini 4 Carbon High subagent with problem context."
exit 2

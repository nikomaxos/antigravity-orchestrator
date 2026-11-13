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

export PATH="/home/nick/.local/bin:/home/nick/.opencode/bin:/home/nick/.npm-global/bin:${PATH}"
# shellcheck source=codex-lib.sh
source "/home/nick/Development/messaging-agent/.agents/scripts/codex-lib.sh"
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
You are a principal engineer performing ROOT-CAUSE ANALYSIS for the `messaging-agent`
platform (event-driven Java/Spring microservices, React admin panel, SMPP, Redis, Kafka,
PostgreSQL, Docker Compose staging on DevBox 10.10.10.96, K3s production).
You run in a READ-ONLY sandbox. NEVER attempt to modify files. Only run focused read-only
commands (git log/show/diff/blame, cat, grep, rg, find, ls) on directly relevant paths.
If a command is blocked by the sandbox (e.g. docker, ssh, network), list it under
"Commands for the implementation agent".

# METHOD
1. Restate the symptom precisely.
2. Trace the real execution path in the code (entry point -> failure point).
3. Form hypotheses, then confirm or eliminate each with evidence (`file:line`, git history, logs).
4. Identify THE root cause (not the symptom). If uncertain, rank candidates with probabilities.
5. Propose the minimal correct fix (respecting the No-Hardcoded-Routing UI-first invariant!) and its regression surface.

# OUTPUT (Markdown in Greek; keep identifiers/paths/commands in English)
## Σύνοψη
## Σύμπτωμα
## Root Cause (with `path:line` & code excerpts)
## Confidence (High / Medium / Low + why)
## Υποθέσεις που αποκλείστηκαν
## Προτεινόμενη διόρθωση (UI/DB home if routing-related + exact files/functions)
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
  CL_RCA="${CLAUDE_RCA_MODEL:-claude-opus-5-5}"
  CL_EFF="${CLAUDE_RCA_EFFORT:-high}"
  echo "🤖 [Pool C] Failing over RCA to Claude Code CLI (model=${CL_RCA}, effort=${CL_EFF})..."
  claude_run "rca" "$CL_RCA" "$CL_EFF" "" "$OUT" "$PROMPT_FILE"
  [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ Claude CLI ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
  if [ "$CODEX_RUN_STATUS" = "RATE_LIMITED" ]; then
    CL_FALLBACK="${CLAUDE_R2_MODEL:-claude-sonnet-5-5}"
    echo "ℹ️  Claude ${CL_RCA} rate-limited; retrying RCA with Claude ${CL_FALLBACK} (effort=high)..."
    claude_run "rca" "$CL_FALLBACK" "high" "" "$OUT" "$PROMPT_FILE"
    [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ Claude CLI ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
    [ "$CODEX_RUN_STATUS" = "OK" ] && USED_LABEL="Claude Code CLI (${CL_FALLBACK}, effort high)"
  elif [ "$CODEX_RUN_STATUS" = "OK" ]; then
    USED_LABEL="Claude Code CLI (${CL_RCA}, effort ${CL_EFF})"
  fi
fi

if [ -z "$USED_LABEL" ] && { [ "$PREFER_CLI" = "auto" ] || [ "$PREFER_CLI" = "opencode" ]; }; then
  echo "🤖 [Pool D] Failing over RCA to OpenCode DeepSeek (${OPENCODE_PRO_MODEL})..."
  opencode_run "rca" "$OPENCODE_PRO_MODEL" "" "$OUT" "$PROMPT_FILE" 1
  [ "$CODEX_RUN_STATUS" = "INTEGRITY_VIOLATION" ] && { echo "❌ OpenCode ${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR}" >&2; exit 3; }
  [ "$CODEX_RUN_STATUS" = "OK" ] && USED_LABEL="OpenCode (${OPENCODE_PRO_MODEL})"
fi

if [ -n "$USED_LABEL" ] && [ -s "$OUT" ]; then
  {
    echo
    echo "---"
    echo "_Generated by ${USED_LABEL} at ${STAMP}, HEAD $(git rev-parse --short HEAD). Read-only analysis — verify evidence before acting._"
  } >> "$OUT"
  ln -sfn "$(basename "$OUT")" "${CODEX_REPORT_DIR}/rca-latest.md"
  echo "✅ RCA report (${USED_LABEL}): ${OUT#"$CODEX_REPO_ROOT"/}"
  exit 0
fi

echo "⚠️  External RCA CLIs unavailable/rate-limited (last=${CODEX_RUN_STATUS}: ${CODEX_RUN_ERROR})"
echo "➡️  FALLBACK: spawn an internal subagent (Gemini 4 Carbon High) with the prompt in:"
echo "    ${PROMPT_FILE#"$CODEX_REPO_ROOT"/}"
exit 2

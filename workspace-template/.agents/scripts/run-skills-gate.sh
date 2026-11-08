#!/usr/bin/env bash
# =============================================================================
# Skills Gate Runner — Evaluates & Signs .agent-state/skills.json
# =============================================================================
# Enforces that before every commit/stop, the agent explicitly evaluates
# whether .agents/skills/*/SKILL.md files must be updated.
#
# Usage:
#   bash .agents/scripts/run-skills-gate.sh <UPDATED|NO_UPDATE_NEEDED> '["skill1"]' "<reason>"
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cd "$REPO_ROOT"

# Auto-detect existing skills if available
EXISTING_SKILLS=$(ls -1 .agents/skills 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || echo '["multi-model-delegation","codex-review"]')
[ "$EXISTING_SKILLS" = "[]" ] && EXISTING_SKILLS='["multi-model-delegation","codex-review"]'

STATUS="${1:-}"
SKILLS_CHECKED="${2:-$EXISTING_SKILLS}"
REASON="${3:-Evaluated skills against current code changes}"

if [ -z "$STATUS" ]; then
  if [ -n "$(git status --porcelain .agents/skills/ 2>/dev/null)" ] || \
     [ -n "$(git diff --name-only HEAD~1..HEAD -- .agents/skills/ 2>/dev/null)" ]; then
    STATUS="UPDATED"
  else
    echo "❌ ERROR: You must explicitly specify STATUS as 'UPDATED' or 'NO_UPDATE_NEEDED'." >&2
    echo "Usage: bash .agents/scripts/run-skills-gate.sh <UPDATED|NO_UPDATE_NEEDED> '[\"skill-name\"]' \"<reason>\"" >&2
    exit 1
  fi
fi

if [ "$STATUS" != "UPDATED" ] && [ "$STATUS" != "NO_UPDATE_NEEDED" ]; then
  echo "❌ ERROR: Invalid status '$STATUS'. Must be 'UPDATED' or 'NO_UPDATE_NEEDED'." >&2
  exit 1
fi

ARRAY_LEN=$(echo "$SKILLS_CHECKED" | jq 'if type == "array" then length else -1 end' 2>/dev/null || echo "-1")
if [ "$ARRAY_LEN" -le 0 ]; then
  echo "❌ ERROR: skills_checked must be a non-empty JSON array of evaluated skill names." >&2
  exit 1
fi

if [ "${#REASON}" -lt 10 ]; then
  echo "❌ ERROR: Please provide a meaningful reason (>= 10 chars) explaining the skills evaluation." >&2
  exit 1
fi

SKILL_FILES_MODIFIED=$( (git diff --name-only HEAD -- .agents/skills/ 2>/dev/null; git diff --cached --name-only -- .agents/skills/ 2>/dev/null; git diff --name-only HEAD~1..HEAD -- .agents/skills/ 2>/dev/null) | sort -u | grep '\S' || true )

if [ "$STATUS" = "UPDATED" ] && [ -z "$SKILL_FILES_MODIFIED" ]; then
  echo "❌ ERROR: Status is 'UPDATED', but no files under .agents/skills/ were modified in the working tree or latest commit." >&2
  echo "   Either update the relevant .agents/skills/*/SKILL.md file(s) first, or pass 'NO_UPDATE_NEEDED' with a valid justification." >&2
  exit 1
fi

MODIFIED_JSON="[]"
if [ -n "$SKILL_FILES_MODIFIED" ]; then
  MODIFIED_JSON=$(echo "$SKILL_FILES_MODIFIED" | jq -R . | jq -s -c .)
fi

CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
CODE_HASH=$(codex_code_worktree_hash)

echo "🔍 Skills Gate: status=${STATUS}, evaluated=${ARRAY_LEN} skill(s)"
CONTENT=$(jq -n -c \
  --arg status "$STATUS" \
  --argjson skills_checked "$SKILLS_CHECKED" \
  --argjson skills_modified "$MODIFIED_JSON" \
  --arg reason "$REASON" \
  --arg tested_head "$CURRENT_HEAD" \
  --arg code_hash "$CODE_HASH" \
  --arg timestamp "$TS" \
  '{
    evaluated: true,
    status: $status,
    skills_checked: $skills_checked,
    skills_modified: $skills_modified,
    reason: $reason,
    tested_head: $tested_head,
    code_hash: $code_hash,
    timestamp: $timestamp
  }')

bash "$SIGN_SCRIPT" ".agent-state/skills.json" "$CONTENT"

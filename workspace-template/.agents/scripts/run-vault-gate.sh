#!/usr/bin/env bash
# =============================================================================
# Vault Gate Runner — Verifies Knowledge Vault diff & signs vault.json
# =============================================================================
# Usage:
#   bash .agents/scripts/run-vault-gate.sh [--updated true|false] [--action updated|none_needed] [--reason "..."]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT="$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
fi
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

cd "$REPO_ROOT"

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
WORKTREE=$(codex_code_worktree_hash)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_FLAG="true"
ACTION_TAKEN="updated"
REASON=""
FILES_CHECKED='[".agents/PROJECT_KNOWLEDGE.md"]'

while [ $# -gt 0 ]; do
  case "$1" in
    --updated)
      UPDATED_FLAG="${2:-true}"
      if [ "$UPDATED_FLAG" = "false" ]; then
        ACTION_TAKEN="none_needed"
      else
        ACTION_TAKEN="updated"
      fi
      shift 2
      ;;
    --action)
      ACTION_TAKEN="${2:-updated}"
      shift 2
      ;;
    --reason)
      REASON="${2:-}"
      shift 2
      ;;
    --files)
      FILES_CHECKED="${2:-[]}"
      shift 2
      ;;
    *)
      if [[ "$1" == \[* ]]; then
        FILES_CHECKED="$1"
      else
        REASON="$1"
      fi
      shift
      ;;
  esac
done

VAULT_DIFF=$( { git diff HEAD -- .agents/PROJECT_KNOWLEDGE.md .agents/knowledge/ 2>/dev/null; git diff --cached -- .agents/PROJECT_KNOWLEDGE.md .agents/knowledge/ 2>/dev/null; } | head -c 4096 || true )

if [ "$ACTION_TAKEN" = "none_needed" ]; then
  if [ "${#REASON}" -lt 30 ]; then
    echo "❌ ERROR: Vault Gate with --action none_needed / --updated false requires --reason of at least 30 characters." >&2
    exit 1
  fi
else
  # Verify whether code changed or --updated true was requested
  CODE_CHANGED=$( { git diff HEAD --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; } | grep -vE '(\.md$|\.txt$|^\.agents/|^\.agent-state/|^\.agent-reports/|^docs/|^platform-docs/)' || true )
  if { [ -n "$CODE_CHANGED" ] || [ "$UPDATED_FLAG" = "true" ]; } && [ -z "$VAULT_DIFF" ]; then
    echo "❌ ERROR: Vault Gate failed — --updated true was passed while code changed, but neither .agents/PROJECT_KNOWLEDGE.md nor .agents/knowledge/*.md has any git diff changes!" >&2
    exit 1
  fi
fi

echo "🔍 Vault Gate: action_taken=${ACTION_TAKEN}, head=${HEAD:0:12}, worktree=${WORKTREE:0:12}"
CONTENT=$(jq -n -c \
  --arg action_taken "$ACTION_TAKEN" \
  --arg reason "$REASON" \
  --argjson files_checked "$FILES_CHECKED" \
  --arg tested_head "$HEAD" \
  --arg worktree_hash "$WORKTREE" \
  --arg timestamp "$TS" \
  '{
    updated: true,
    action_taken: $action_taken,
    reason: $reason,
    files_checked: $files_checked,
    tested_head: $tested_head,
    worktree_hash: $worktree_hash,
    timestamp: $timestamp
  }')

bash "$SIGN_SCRIPT" ".agent-state/vault.json" "$CONTENT"

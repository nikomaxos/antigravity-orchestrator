#!/usr/bin/env bash
# =============================================================================
# Docs Gate Runner — Evaluates Markdown / documentation & signs docs.json
# =============================================================================
# Usage:
#   bash .agents/scripts/run-docs-gate.sh [--updated true|false] ["<reason>"]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

cd "$REPO_ROOT"

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
WORKTREE=$(codex_code_worktree_hash)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPDATED_FLAG="false"
REASON="Evaluated by agent"

while [ $# -gt 0 ]; do
  case "$1" in
    --updated)
      UPDATED_FLAG="${2:-false}"
      shift 2
      ;;
    --reason)
      REASON="${2:-Evaluated by agent}"
      shift 2
      ;;
    *)
      REASON="$1"
      shift
      ;;
  esac
done

if [ "$UPDATED_FLAG" = "true" ]; then
  DOCS_DIFF=$( { git diff HEAD -- docs/ platform-docs/ .agents/PROJECT_KNOWLEDGE.md .agents/knowledge/ 2>/dev/null; git diff --cached -- docs/ platform-docs/ .agents/PROJECT_KNOWLEDGE.md .agents/knowledge/ 2>/dev/null; } | head -c 4096 || true )
  if [ -z "$DOCS_DIFF" ]; then
    echo "❌ ERROR: Docs Gate --updated true passed, but no documentation files were modified!" >&2
    exit 1
  fi
fi

echo "🔍 Docs Gate: marking as evaluated (head=${HEAD:0:12}, worktree=${WORKTREE:0:12})"
CONTENT=$(jq -n -c \
  --arg reason "$REASON" \
  --arg tested_head "$HEAD" \
  --arg worktree_hash "$WORKTREE" \
  --arg timestamp "$TS" \
  '{
    evaluated: true,
    reason: $reason,
    tested_head: $tested_head,
    worktree_hash: $worktree_hash,
    timestamp: $timestamp
  }')

bash "$SIGN_SCRIPT" ".agent-state/docs.json" "$CONTENT"

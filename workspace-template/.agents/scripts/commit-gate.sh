#!/usr/bin/env bash
# =============================================================================
# Pre-Commit & Pre-Push Gate (`commit-gate.sh`)
# =============================================================================
# Runs both as an Antigravity PreToolUse hook AND directly via `.git/hooks/pre-commit`.
# Verifies all gates locally AND via root-owned `agy-gatekeeper.service`
# (`http://127.0.0.1:18099/api/gatekeeper/verify-status?mode=commit`).
# =============================================================================
set -euo pipefail

GIT_HOOK_MODE=0
if [ "${1:-}" = "--git-hook" ]; then
  GIT_HOOK_MODE=1
  COMMAND_LINE="git commit"
else
  INPUT=$(cat || true)
  if [ -z "$INPUT" ]; then
    GIT_HOOK_MODE=1
    COMMAND_LINE="git commit"
  else
    if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
      echo '{"decision": "deny", "reason": "⛔ BLOCKED: Malformed PreToolUse hook input JSON"}'
      exit 0
    fi
    COMMAND_LINE=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // ""')
  fi
fi

if [ "$GIT_HOOK_MODE" -eq 0 ] && ! echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+commit|git[[:space:]]+push'; then
  echo '{"decision": "allow"}'
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT="$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
fi
STATE_DIR="${REPO_ROOT}/.agent-state"

cd "$REPO_ROOT" 2>/dev/null || true

FAILED_CHECKS=""

# --- Gate status checks ---
if [ -f "$STATE_DIR/qa.json" ]; then
  QA_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/qa.json")
  if [ "$QA_STATUS" != "PASS" ]; then
    FAILED_CHECKS="${FAILED_CHECKS}QA status is $QA_STATUS; "
  fi
else
  FAILED_CHECKS="${FAILED_CHECKS}qa.json missing; "
fi

if [ -f "$STATE_DIR/vault.json" ]; then
  VAULT_UPDATED=$(jq -r '.updated // false' "$STATE_DIR/vault.json")
  if [ "$VAULT_UPDATED" != "true" ]; then
    FAILED_CHECKS="${FAILED_CHECKS}Vault not updated; "
  fi
else
  FAILED_CHECKS="${FAILED_CHECKS}vault.json missing; "
fi

if [ -f "$STATE_DIR/docs.json" ]; then
  DOCS_EVALUATED=$(jq -r '.evaluated // false' "$STATE_DIR/docs.json")
  if [ "$DOCS_EVALUATED" != "true" ]; then
    FAILED_CHECKS="${FAILED_CHECKS}Docs not evaluated; "
  fi
else
  FAILED_CHECKS="${FAILED_CHECKS}docs.json missing; "
fi

# Skills gate check
if [ -f "$STATE_DIR/skills.json" ]; then
  SKILLS_EVALUATED=$(jq -r '.evaluated // false' "$STATE_DIR/skills.json")
  SKILLS_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/skills.json")
  if [ "$SKILLS_EVALUATED" != "true" ] || { [ "$SKILLS_STATUS" != "UPDATED" ] && [ "$SKILLS_STATUS" != "NO_UPDATE_NEEDED" ]; }; then
    FAILED_CHECKS="${FAILED_CHECKS}Skills not evaluated (run: bash .agents/scripts/run-skills-gate.sh); "
  fi
else
  FAILED_CHECKS="${FAILED_CHECKS}skills.json missing (run: bash .agents/scripts/run-skills-gate.sh); "
fi

# Regression gate check
if [ -f "$STATE_DIR/regression.json" ]; then
  REG_STATUS=$(jq -r '.status // "PENDING"' "$STATE_DIR/regression.json")
  if [ "$REG_STATUS" != "PASS" ] && [ "$REG_STATUS" != "NOT_APPLICABLE" ]; then
    FAILED_CHECKS="${FAILED_CHECKS}Regression: $REG_STATUS; "
  fi
else
  FAILED_CHECKS="${FAILED_CHECKS}regression.json missing; "
fi

# --- Cross-Model Review Gate ---
if echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+commit'; then
  CODEX_LIB="${REPO_ROOT}/.agents/scripts/codex-lib.sh"
  if [ -f "$CODEX_LIB" ]; then
    # shellcheck source=codex-lib.sh
    source "$CODEX_LIB"
    if [ "$GIT_HOOK_MODE" -eq 0 ]; then
      if echo "$COMMAND_LINE" | grep -qE 'git[[:space:]]+commit([[:space:]].*)?[[:space:]](-[[:alnum:]]*[aoi][[:alnum:]]*|--all|--only|--include)([[:space:]]|$)'; then
        FAILED_CHECKS="${FAILED_CHECKS}git commit -a/-o/-i/--all/--only/--include is forbidden (stage explicit paths, then run the Cross-Model review gate); "
      fi
      HAS_PATHSPEC=$(node -e '
        const cmd = process.argv[1];
        const match = cmd.match(/git\s+commit\b(.*)/i);
        if (!match) process.exit(0);
        const rest = match[1].trim();
        const tokens = rest.match(/(?:[^\s"\x27]+|"[^"]*"|\x27[^\x27]*\x27)+/g) || [];
        const optsWithValue = new Set(["-m", "-F", "-c", "-C", "--message", "--file", "--reedit-message", "--reuse-message", "--fixup", "--squash", "--author", "--date", "-u", "--untracked-files"]);
        for (let i = 0; i < tokens.length; i++) {
          let t = tokens[i];
          if (t === "--") {
            if (i + 1 < tokens.length) { console.log("pathspec"); process.exit(0); }
            continue;
          }
          if (t.startsWith("-")) {
            if (optsWithValue.has(t) && i + 1 < tokens.length) {
              i++;
            }
            continue;
          }
          console.log("pathspec");
          process.exit(0);
        }
      ' "$COMMAND_LINE" 2>/dev/null || true)
      if [ "$HAS_PATHSPEC" = "pathspec" ]; then
        FAILED_CHECKS="${FAILED_CHECKS}git commit with positional pathspec is forbidden (stage explicit paths, then run the Cross-Model review gate); "
      fi
    fi
    if [ -n "$(codex_staged_files)" ]; then
      CR_FILE="${STATE_DIR}/codex-review.json"
      if [ ! -f "$CR_FILE" ]; then
        FAILED_CHECKS="${FAILED_CHECKS}Cross-Model review missing (run: bash .agents/scripts/run-codex-review-gate.sh); "
      else
        CR_STATUS=$(jq -r '.status // "PENDING"' "$CR_FILE")
        CR_FP=$(jq -r '.staged_fingerprint // ""' "$CR_FILE")
        if [ "$CR_FP" != "$(codex_staged_fingerprint)" ]; then
          FAILED_CHECKS="${FAILED_CHECKS}Cross-Model review is STALE (staged diff changed after review — re-run run-codex-review-gate.sh); "
        elif [ "$CR_STATUS" = "SKIPPED_RATE_LIMIT" ] || [ "$CR_STATUS" = "UNAVAILABLE" ]; then
          FAILED_CHECKS="${FAILED_CHECKS}External CLI cascade ${CR_STATUS} — complete the internal Carbon High fallback review (run-codex-review-gate.sh --fallback); "
        elif [ "$CR_STATUS" != "PASS" ] && [ "$CR_STATUS" != "PASS_FALLBACK" ]; then
          FAILED_CHECKS="${FAILED_CHECKS}Cross-Model review status is ${CR_STATUS} ($(jq -r '.blocking_count // "?"' "$CR_FILE") CRITICAL/HIGH/OWASP unresolved); "
        fi
      fi
    fi
  else
    FAILED_CHECKS="${FAILED_CHECKS}codex-lib.sh missing; "
  fi
fi

# --- Change Integrity & Freshness Check ---
if [ -f "${REPO_ROOT}/.agents/scripts/codex-lib.sh" ]; then
  # shellcheck source=codex-lib.sh
  source "${REPO_ROOT}/.agents/scripts/codex-lib.sh"
  CURRENT_WORKTREE=$(codex_code_worktree_hash)
else
  CURRENT_WORKTREE=$(git diff HEAD -- . ":(exclude).agent-state" ":(exclude)*.md" ":(exclude).agents/skills" 2>/dev/null | md5sum | awk '{print $1}')
fi
CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

IS_PUSH_ONLY=0
if echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+push' && ! echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+commit'; then
  IS_PUSH_ONLY=1
fi
PARENT_HEAD=$(git rev-parse HEAD~1 2>/dev/null || echo "none")
EMPTY_MD5="d41d8cd98f00b204e9800998ecf8427e"

is_gate_fresh() {
  local g_head="$1" g_wt="$2"
  if [ "$g_head" = "$CURRENT_HEAD" ] && [ "$g_wt" = "$CURRENT_WORKTREE" ]; then
    return 0
  fi
  if [ "$IS_PUSH_ONLY" -eq 1 ] && [ "$CURRENT_WORKTREE" = "$EMPTY_MD5" ] && [ "$g_head" = "$PARENT_HEAD" ]; then
    return 0
  fi
  return 1
}

# Check qa.json tested_head & worktree_hash
if [ -f "$STATE_DIR/qa.json" ] && [ "${QA_STATUS:-PENDING}" = "PASS" ]; then
  QA_HEAD=$(jq -r '.tested_head // ""' "$STATE_DIR/qa.json")
  QA_WORKTREE=$(jq -r '.worktree_hash // ""' "$STATE_DIR/qa.json")
  if ! is_gate_fresh "$QA_HEAD" "$QA_WORKTREE"; then
    FAILED_CHECKS="${FAILED_CHECKS}QA PASS is STALE (code/HEAD changed after verification); "
  fi
fi

# Check regression.json tested_head & worktree_hash
if [ -f "$STATE_DIR/regression.json" ]; then
  REG_HEAD=$(jq -r '.tested_head // ""' "$STATE_DIR/regression.json")
  REG_WORKTREE=$(jq -r '.worktree_hash // ""' "$STATE_DIR/regression.json")
  if ! is_gate_fresh "$REG_HEAD" "$REG_WORKTREE"; then
    FAILED_CHECKS="${FAILED_CHECKS}Regression gate is STALE (code/HEAD changed after verification); "
  fi
fi

# Check vault.json tested_head & worktree_hash
if [ -f "$STATE_DIR/vault.json" ] && [ "${VAULT_UPDATED:-false}" = "true" ]; then
  VAULT_HEAD=$(jq -r '.tested_head // ""' "$STATE_DIR/vault.json")
  VAULT_WORKTREE=$(jq -r '.worktree_hash // ""' "$STATE_DIR/vault.json")
  if ! is_gate_fresh "$VAULT_HEAD" "$VAULT_WORKTREE"; then
    FAILED_CHECKS="${FAILED_CHECKS}Vault gate is STALE (re-run bash .agents/scripts/run-vault-gate.sh for current HEAD/worktree); "
  fi
fi

# Check docs.json tested_head & worktree_hash
if [ -f "$STATE_DIR/docs.json" ] && [ "${DOCS_EVALUATED:-false}" = "true" ]; then
  DOCS_HEAD=$(jq -r '.tested_head // ""' "$STATE_DIR/docs.json")
  DOCS_WORKTREE=$(jq -r '.worktree_hash // ""' "$STATE_DIR/docs.json")
  if ! is_gate_fresh "$DOCS_HEAD" "$DOCS_WORKTREE"; then
    FAILED_CHECKS="${FAILED_CHECKS}Docs gate is STALE (re-run bash .agents/scripts/run-docs-gate.sh for current HEAD/worktree); "
  fi
fi

# Check skills.json tested_head & worktree_hash/code_hash
if [ -f "$STATE_DIR/skills.json" ] && [ "${SKILLS_EVALUATED:-false}" = "true" ]; then
  SKILLS_HEAD=$(jq -r '.tested_head // ""' "$STATE_DIR/skills.json")
  SKILLS_CODE_HASH=$(jq -r '.worktree_hash // .code_hash // ""' "$STATE_DIR/skills.json")
  if ! is_gate_fresh "$SKILLS_HEAD" "$SKILLS_CODE_HASH"; then
    FAILED_CHECKS="${FAILED_CHECKS}Skills evaluation is STALE (code changed after run-skills-gate.sh — re-evaluate skills); "
  fi
fi

# --- Root Gatekeeper Service HMAC & Freshness Verification ---
GK_MODE="commit"
if echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+push'; then
  GK_MODE="deploy"
fi
if ! curl -G -sf "http://127.0.0.1:18099/api/gatekeeper/verify-status" --data-urlencode "mode=${GK_MODE}" --data-urlencode "workspace=${REPO_ROOT}" >/dev/null 2>&1; then
  GK_BODY=$(curl -G -s "http://127.0.0.1:18099/api/gatekeeper/verify-status" --data-urlencode "mode=${GK_MODE}" --data-urlencode "workspace=${REPO_ROOT}" 2>/dev/null || echo '{"errors":["agy-gatekeeper.service unreachable on 127.0.0.1:18099"]}')
  GK_ERRS=$(echo "$GK_BODY" | jq -r '(.errors // ["gatekeeper verification failed"]) | join("; ")' 2>/dev/null || echo "gatekeeper verification failed")
  FAILED_CHECKS="${FAILED_CHECKS}Root Gatekeeper (${GK_MODE}) rejected: ${GK_ERRS}; "
fi

# --- Staged Gate Files Check ---
if echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+commit'; then
  STAGED_CODE=$(git diff --cached --name-only 2>/dev/null | grep -vE '^\.agent-state/' || true)
  STAGED_GATES=$(git diff --cached --name-only 2>/dev/null | grep -E '^\.agent-state/' || true)
  if [ -n "$STAGED_CODE" ] && [ -z "$STAGED_GATES" ]; then
    FAILED_CHECKS="${FAILED_CHECKS}No .agent-state/ gate files staged — commit must include signed gate files; "
  fi
fi

# --- Static Analysis / Anti-Pattern Gate (Scoped to Java if present) ---
if echo "$COMMAND_LINE" | grep -iqE 'git[[:space:]]+commit'; then
  if find . -name "*.java" -not -path "*/target/*" -not -path "*/build/*" 2>/dev/null | head -1 | grep -q .; then
    if git diff --cached 2>/dev/null | grep -E 'String\.format\("[^"]*%[0-9]*\.?[0-9]*[fgeFGE]' | grep -v "Locale" >/dev/null 2>&1; then
      FAILED_CHECKS="${FAILED_CHECKS}ANTI-PATTERN DETECTED: String.format used without explicit Locale. Always use String.format(Locale.US, ...); "
    fi
  fi
fi

# --- Final decision ---
if [ -n "$FAILED_CHECKS" ]; then
  FAILED_CHECKS=$(echo "$FAILED_CHECKS" | sed 's/; $//')
  if [ "$GIT_HOOK_MODE" -eq 1 ]; then
    echo "⛔ BLOCKED BY COMMIT GATE: $FAILED_CHECKS" >&2
    exit 1
  else
    jq -n -c --arg r "⛔ BLOCKED: $FAILED_CHECKS" '{decision: "deny", reason: $r}'
    exit 0
  fi
fi

if [ "$GIT_HOOK_MODE" -eq 1 ]; then
  exit 0
else
  echo '{"decision": "allow"}'
fi

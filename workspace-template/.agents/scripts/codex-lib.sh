#!/usr/bin/env bash
# =============================================================================
# Multi-CLI Cross-Model Council — Shared Library (`codex-lib.sh`)
# =============================================================================
# Sourced by: codex-rca.sh, run-codex-review-gate.sh, stage0-precheck.sh,
#             sync-security-from-review.sh, commit-gate.sh, preflight.sh
# Do NOT execute directly.
#
# 4 Orthogonal Pools (Single-Writer Invariant: ONLY Antigravity writes files):
#   - Pool B: OpenAI Codex CLI (`codex exec` / `codex exec resume`, `-s read-only`)
#   - Pool C: Anthropic Claude Code CLI (`claude -p --permission-mode plan`)
#   - Pool D: OpenCode CLI (`opencode run --agent readonly-auditor` + DeepSeek API)
#   - Pool A: Antigravity Native (`--fallback` subagent ONLY if B+C+D all fail)
#
# Every external CLI invocation verifies `before_fp == after_fp` on the worktree!
# =============================================================================

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
CODEX_REPO_ROOT="${CODEX_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CODEX_REPORT_DIR="${CODEX_REPO_ROOT}/.agent-reports/codex"
CODEX_USAGE_LOG="${CODEX_REPORT_DIR}/usage.log"
CODEX_SCRIPTS_DIR="${CODEX_REPO_ROOT}/.agents/scripts"
CODEX_REVIEW_STATE_REL=".agent-state/codex-review.json"
CODEX_REVIEW_STATE="${CODEX_REPO_ROOT}/${CODEX_REVIEW_STATE_REL}"
CODEX_REVIEW_SCHEMA="${CODEX_SCRIPTS_DIR}/codex-review-schema.json"
LLM_COUNCIL_SECRETS="${HOME}/.config/llm-council/secrets.env"

# --- Default Model Routing (Tier R3 / RCA defaults) --------------------------
CODEX_RCA_MODEL="${CODEX_RCA_MODEL:-gpt-6-astra}"
CODEX_RCA_EFFORT="${CODEX_RCA_EFFORT:-xhigh}"
CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-gpt-6-astra}"
CODEX_REVIEW_EFFORT="${CODEX_REVIEW_EFFORT:-high}"

# Tier-specific Review Routing (R1: light UI/test, R2: standard CRUD, R3: critical)
CODEX_R1_MODEL="gpt-5.6-terra"; CODEX_R1_EFFORT="medium"
CODEX_R2_MODEL="gpt-6-astra";   CODEX_R2_EFFORT="medium"
CODEX_R3_MODEL="gpt-6-astra";   CODEX_R3_EFFORT="high"

CLAUDE_R1_MODEL="sonnet"; CLAUDE_R1_EFFORT="low"
CLAUDE_R2_MODEL="sonnet"; CLAUDE_R2_EFFORT="high"
CLAUDE_R3_MODEL="opus";   CLAUDE_R3_EFFORT="high"

OPENCODE_PRO_MODEL="deepseek/deepseek-v4-pro"
OPENCODE_FLASH_MODEL="deepseek/deepseek-flash"
OPENCODE_FREE_MODEL="opencode/deepseek-v4.1-flash-free"

CODEX_TIMEOUT_SECS="${CODEX_TIMEOUT_SECS:-1800}"
CODEX_MAX_DIFF_BYTES="${CODEX_MAX_DIFF_BYTES:-400000}"
CODEX_MAX_ATTACH_BYTES="${CODEX_MAX_ATTACH_BYTES:-100000}"
CODEX_KEEP_RUN_LOGS="${CODEX_KEEP_RUN_LOGS:-50}"

# Exclusions for staged diff review: state, reports, deploy marker, and prose (*.md)
CODEX_EXCLUDES=(
  ":(exclude).agent-state"
  ":(exclude).agent-reports"
  ":(exclude).last-staging-deploy"
  ":(exclude)*.md"
  ":(exclude)platform-docs"
  ":(exclude)docs"
)

# Shared non-code exclusions for QA/Regression/Skills worktree hashes
NON_CODE_WORKTREE_EXCLUDES=(
  ":(exclude).agent-state"
  ":(exclude).agent-reports"
  ":(exclude).last-staging-deploy"
  ":(exclude)*.md"
  ":(exclude).agents/skills"
  ":(exclude)platform-docs"
  ":(exclude)docs"
)

# Run results (populated by codex_run / codex_run_resume / claude_run / opencode_run)
CODEX_RUN_STATUS=""
CODEX_RUN_ERROR=""
CODEX_RUN_EVENTS=""
CODEX_RUN_STDERR=""
CODEX_LAST_THREAD_ID=""

# -----------------------------------------------------------------------------
# Binary & Secret Resolution
# -----------------------------------------------------------------------------
codex_resolve_bin() {
  if [ -n "${CODEX_BIN:-}" ] && [ -x "${CODEX_BIN}" ]; then echo "${CODEX_BIN}"; return 0; fi
  local home="${HOME}" candidate=""
  if [ -x "${home}/.local/share/mise/shims/codex" ]; then echo "${home}/.local/share/mise/shims/codex"; return 0; fi
  if [ -x "${home}/.npm-global/bin/codex" ]; then echo "${home}/.npm-global/bin/codex"; return 0; fi
  candidate=$(ls -d "${home}"/.antigravity/extensions/openai.chatgpt-*/bin/linux-*/codex 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
  if command -v codex >/dev/null 2>&1; then command -v codex; return 0; fi
  return 1
}

claude_resolve_bin() {
  local home="${HOME}"
  if [ -x "${home}/.local/share/mise/shims/claude" ]; then echo "${home}/.local/share/mise/shims/claude"; return 0; fi
  if [ -x "${home}/.local/bin/claude" ]; then echo "${home}/.local/bin/claude"; return 0; fi
  if [ -x "${home}/.npm-global/bin/claude" ]; then echo "${home}/.npm-global/bin/claude"; return 0; fi
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  return 1
}

opencode_resolve_bin() {
  local home="${HOME}"
  if [ -x "${home}/.local/share/mise/shims/opencode" ]; then echo "${home}/.local/share/mise/shims/opencode"; return 0; fi
  if [ -x "${home}/.opencode/bin/opencode" ]; then echo "${home}/.opencode/bin/opencode"; return 0; fi
  if [ -x "${home}/.local/bin/opencode" ]; then echo "${home}/.local/bin/opencode"; return 0; fi
  if command -v opencode >/dev/null 2>&1; then command -v opencode; return 0; fi
  return 1
}

llm_has_deepseek_key() {
  [ -f "$LLM_COUNCIL_SECRETS" ] && grep -qE '^DEEPSEEK_API_KEY="?sk-[A-Za-z0-9_-]{16,}' "$LLM_COUNCIL_SECRETS" 2>/dev/null
}

llm_load_deepseek_key() {
  if llm_has_deepseek_key; then
    # shellcheck disable=SC1090
    source "$LLM_COUNCIL_SECRETS"
    export DEEPSEEK_API_KEY
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Fingerprints & Automatic Diff Risk Tiering (R1 / R2 / R3)
# -----------------------------------------------------------------------------
codex_staged_diff() {
  git -C "$CODEX_REPO_ROOT" diff --cached --no-color --no-ext-diff -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null || true
}

codex_staged_files() {
  git -C "$CODEX_REPO_ROOT" diff --cached --name-only -- . "${CODEX_EXCLUDES[@]}" 2>/dev/null || true
}

codex_staged_fingerprint() {
  codex_staged_diff | sha256sum | awk '{print $1}'
}

codex_code_worktree_hash() {
  (
    cd "$CODEX_REPO_ROOT" || exit 0
    {
      git diff HEAD -- . "${NON_CODE_WORKTREE_EXCLUDES[@]}" 2>/dev/null || true
      git ls-files --others --exclude-standard -z -- . "${NON_CODE_WORKTREE_EXCLUDES[@]}" 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum 2>/dev/null || true
    } | md5sum | awk '{print $1}'
  )
}

codex_pool_in_cooldown() {
  local pm="$1" cd_secs="${2:-900}"
  [ -f "$CODEX_USAGE_LOG" ] || return 1
  local last_line ts_str status now_ep last_ep
  last_line=$(awk -F'\t' -v p="$pm" '$3 == p' "$CODEX_USAGE_LOG" 2>/dev/null | tail -1 || true)
  [ -n "$last_line" ] || return 1
  ts_str=$(printf '%s' "$last_line" | awk -F'\t' '{print $1}')
  status=$(printf '%s' "$last_line" | awk -F'\t' '{print $5}')
  if [ "$status" = "RATE_LIMITED" ] || [ "$status" = "UNAVAILABLE" ]; then
    now_ep=$(date -u +%s)
    last_ep=$(date -u -d "$ts_str" +%s 2>/dev/null || echo 0)
    if [ $((now_ep - last_ep)) -lt "$cd_secs" ]; then
      return 0
    fi
  fi
  return 1
}

codex_worktree_fingerprint() {
  (
    set +e +o pipefail
    cd "$CODEX_REPO_ROOT" || exit 0
    local ex=(":(exclude).agent-state" ":(exclude).agent-reports")
    {
      git status --porcelain=v1 --untracked-files=all -- . "${ex[@]}" 2>/dev/null
      git diff --cached --no-color --no-ext-diff --binary -- . "${ex[@]}" 2>/dev/null
      git diff --no-color --no-ext-diff --binary -- . "${ex[@]}" 2>/dev/null
      git ls-files --others --exclude-standard -z -- . "${ex[@]}" 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null
    } | sha256sum | awk '{print $1}'
  )
}

# Classify staged diff into R1 (light UI/test), R2 (standard CRUD/backend), or R3 (critical)
codex_classify_diff_tier() {
  local files diff_lines
  files=$(codex_staged_files)
  diff_lines=$(codex_staged_diff | grep -cE '^[+-][^+-]' || true)

  if grep -qE '(\.lua$|/V[0-9]+__.*\.sql$|Security|Jwt|Auth|Crypto|Lock|Concurrency|Mutex|Socket|Protocol|Netty|K8s|Dockerfile|docker-compose|setup-git-hooks\.sh|\.agents/scripts/|\.agents/hooks\.json)' <<< "$files" \
     || [ "${diff_lines:-0}" -ge 350 ]; then
    echo "R3"
    return 0
  fi

  if [ "${diff_lines:-0}" -lt 60 ] && ! grep -qE '(pom\.xml$|build\.gradle$|pyproject\.toml$|go\.mod$|Cargo\.toml$|\.sh$)' <<< "$files"; then
    echo "R1"
    return 0
  fi

  echo "R2"
}

codex_is_security_sensitive_files() {
  grep -qE '(Security|Jwt|Auth|Encryption|Crypto|Secret|Token|Permission|Rbac|Vhost|Firewall|setup-git-hooks\.sh|\.agents/scripts/|\.agents/hooks\.json)' <<< "${1:-}"
}

# -----------------------------------------------------------------------------
# Context Builders (Full Context for R2/R3 & RCA; Compact UI Context for R1)
# -----------------------------------------------------------------------------
codex_build_context() {
  local root="$CODEX_REPO_ROOT"
  echo "NOTE: The rules below describe this workspace. Workflow rules about subagents,"
  echo "gates, deployment, commits and user communication apply to the Antigravity"
  echo "implementation agent, NOT to you. Use them as authoritative context for what is"
  echo "correct, required or forbidden in this codebase and its operations."
  echo
  echo "### .agents/AGENTS.md"
  cat "$root/.agents/AGENTS.md" 2>/dev/null || cat "$root/AGENTS.md" 2>/dev/null || echo "(missing)"
  local f
  for f in "$root"/.agents/rules/*.md; do
    [ -f "$f" ] || continue
    echo
    echo "### ${f#"$root"/}"
    cat "$f"
  done
  echo
  echo "### .agents/PROJECT_KNOWLEDGE.md"
  sed -n '1,/^## 📝 Recent/p' "$root/.agents/PROJECT_KNOWLEDGE.md" 2>/dev/null || cat "$root/.agents/PROJECT_KNOWLEDGE.md" 2>/dev/null || sed -n '1,/^## 📝 Recent/p' "$root/PROJECT_KNOWLEDGE.md" 2>/dev/null || cat "$root/PROJECT_KNOWLEDGE.md" 2>/dev/null || true
}

codex_build_compact_ui_context() {
  local root="$CODEX_REPO_ROOT"
  echo "### UI & Security Rules (Compact R1 Mode)"
  echo "- Maintain UI consistency: preserve fonts, colors, pill badges, and layout hierarchy."
  echo "- Security: verify zero XSS (dangerouslySetInnerHTML / unescaped URLs), zero leaked secrets, and clean types."
}

codex_repo_state() {
  echo "HEAD: $(git -C "$CODEX_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "Branch: $(git -C "$CODEX_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "git status --short:"
  git -C "$CODEX_REPO_ROOT" status --short 2>/dev/null | head -100 || true
}

# -----------------------------------------------------------------------------
# Error Classification & Usage Logging
# -----------------------------------------------------------------------------
codex_error_messages() {
  {
    jq -r -R 'fromjson? | select(.type=="error" or .type=="turn.failed" or .is_error==true) | (.message // .error.message // .result // empty)' "$1" 2>/dev/null || true
    grep -iE 'error|fail|limit|denied|unauthori|not logged|quota|429|401|balance|insufficient' "$2" 2>/dev/null || true
  } | head -25 || true
}

codex_is_rate_limited() {
  grep -qiE 'usage limit|usage_limit|rate[ _-]?limit|too many requests|"status":[[:space:]]*429|[^0-9]429[^0-9]|quota|limit reached|try again (at|in)|5-hour|weekly limit|overloaded|insufficient[ _-]?balance'
}

codex_is_unavailable() {
  grep -qiE '502|503|504|bad gateway|service unavailable|gateway timeout|cloudflare|unreachable|econnrefused|not logged|unauthorized|invalid api key'
}

codex_log_usage() {
  local kind="$1" provider_model="$2" effort="$3" status="$4" events_file="$5"
  local in_tok="0" out_tok="0" cost="0.00"
  if [ -s "$events_file" ]; then
    in_tok=$(jq -r -s 'map(select(.type=="turn.completed" or .type=="session.completed") | .usage.input_tokens // 0) | add // 0' "$events_file" 2>/dev/null || echo 0)
    out_tok=$(jq -r -s 'map(select(.type=="turn.completed" or .type=="session.completed") | .usage.output_tokens // 0) | add // 0' "$events_file" 2>/dev/null || echo 0)
  fi
  mkdir -p "$(dirname "$CODEX_USAGE_LOG")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$provider_model" "$effort" "$status" "$in_tok" "$out_tok" "$cost" \
    >> "$CODEX_USAGE_LOG"
}

# -----------------------------------------------------------------------------
# Pool B Runners: OpenAI Codex CLI (`codex_run` / `codex_run_resume`, strict read-only)
# -----------------------------------------------------------------------------
codex_run() {
  local kind="$1" model="$2" effort="$3" schema="$4" out="$5" prompt_file="$6"
  local ts bin rc=0 before after msgs
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$CODEX_REPORT_DIR"
  CODEX_RUN_EVENTS="${CODEX_REPORT_DIR}/${kind}-codex-${ts}.events.jsonl"
  CODEX_RUN_STDERR="${CODEX_REPORT_DIR}/${kind}-codex-${ts}.stderr.log"
  CODEX_RUN_ERROR=""
  CODEX_LAST_THREAD_ID=""
  : > "$CODEX_RUN_EVENTS"; : > "$CODEX_RUN_STDERR"

  if ! bin=$(codex_resolve_bin); then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR="Codex binary not found"
    codex_log_usage "$kind" "codex:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  local -a args=(
    -C "$CODEX_REPO_ROOT"
    -s "read-only"
    -m "$model"
    -c "model_reasoning_effort=\"${effort}\""
    -c "features.multi_agent=false"
    --json
  )
  [ -n "$schema" ] && [ -f "$schema" ] && args+=(--output-schema "$schema")
  [ -n "$out" ] && args+=(-o "$out")

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  timeout "$CODEX_TIMEOUT_SECS" "$bin" exec "${args[@]}" - < "$prompt_file" > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR" || rc=$?
  after=$(codex_worktree_fingerprint)

  CODEX_LAST_THREAD_ID=$(jq -r -R 'fromjson? | select(.type=="session_started" or .type=="thread.created") | (.thread_id // .session_id // empty)' "$CODEX_RUN_EVENTS" 2>/dev/null | tail -1 || true)
  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during read-only Codex run"
    rm -f "$out"
  elif [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Codex exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  codex_log_usage "$kind" "codex:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

codex_run_resume() {
  local kind="$1" thread_id="$2" model="$3" effort="$4" schema="$5" out="$6" prompt_file="$7"
  local ts bin rc=0 before after msgs
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$CODEX_REPORT_DIR"
  CODEX_RUN_EVENTS="${CODEX_REPORT_DIR}/${kind}-codex-resume-${ts}.events.jsonl"
  CODEX_RUN_STDERR="${CODEX_REPORT_DIR}/${kind}-codex-resume-${ts}.stderr.log"
  CODEX_RUN_ERROR=""
  CODEX_LAST_THREAD_ID="$thread_id"
  : > "$CODEX_RUN_EVENTS"; : > "$CODEX_RUN_STDERR"

  if ! bin=$(codex_resolve_bin); then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR="Codex binary not found"
    codex_log_usage "$kind" "codex:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  local -a args=(
    -C "$CODEX_REPO_ROOT"
    -s "read-only"
    -m "$model"
    -c "model_reasoning_effort=\"${effort}\""
    -c "features.multi_agent=false"
    --json
  )
  [ -n "$schema" ] && [ -f "$schema" ] && args+=(--output-schema "$schema")

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  timeout "$CODEX_TIMEOUT_SECS" "$bin" exec resume "${args[@]}" "$thread_id" - < "$prompt_file" > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR" || rc=$?
  after=$(codex_worktree_fingerprint)

  if [ "$rc" -eq 0 ] && [ -s "$CODEX_RUN_EVENTS" ]; then
    python3 - "$CODEX_RUN_EVENTS" "$out" <<'PY' || true
import sys, json
events_path, out_path = sys.argv[1], sys.argv[2]
last_json_text = None
with open(events_path, "r", encoding="utf-8", errors="replace") as f:
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
            parts = item.get("content") or []
            for p in parts:
                txt = p.get("text") or ""
                if "{" in txt and "}" in txt:
                    last_json_text = txt
if last_json_text:
    start = last_json_text.find("{")
    end = last_json_text.rfind("}")
    if start != -1 and end != -1 and end > start:
        with open(out_path, "w", encoding="utf-8") as out:
            out.write(last_json_text[start:end+1] + "\n")
PY
  fi

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during read-only Codex resume"
    rm -f "$out"
  elif [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Codex resume exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  codex_log_usage "$kind" "codex-resume:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

# -----------------------------------------------------------------------------
# Pool C Runner: Anthropic Claude Code CLI (`claude_run`, strict read-only)
# -----------------------------------------------------------------------------
claude_run() {
  local kind="$1" model="$2" effort="$3" schema="$4" out="$5" prompt_file="$6"
  local ts bin rc=0 before after msgs
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$CODEX_REPORT_DIR"
  CODEX_RUN_EVENTS="${CODEX_REPORT_DIR}/${kind}-claude-${ts}.events.jsonl"
  CODEX_RUN_STDERR="${CODEX_REPORT_DIR}/${kind}-claude-${ts}.stderr.log"
  CODEX_RUN_ERROR=""
  : > "$CODEX_RUN_EVENTS"; : > "$CODEX_RUN_STDERR"

  if ! bin=$(claude_resolve_bin); then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR="Claude binary not found"
    codex_log_usage "$kind" "claude:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  local combined_prompt="${CODEX_REPORT_DIR}/${kind}-claude-${ts}.prompt.md"
  cp "$prompt_file" "$combined_prompt"
  if [ -n "$schema" ] && [ -f "$schema" ]; then
    {
      echo ""
      echo "# STRICT JSON SCHEMA REQUIREMENT"
      echo "Output ONLY a raw valid JSON object (no markdown fences, no commentary before or after) strictly conforming to this JSON Schema:"
      cat "$schema"
    } >> "$combined_prompt"
  fi

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  (
    cd "$CODEX_REPO_ROOT"
    timeout "$CODEX_TIMEOUT_SECS" "$bin" -p \
      --model "$model" \
      --effort "$effort" \
      --permission-mode plan \
      --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
      --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" \
      --max-turns 20 \
      -- < "$combined_prompt" \
      > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR"
  ) || rc=$?
  after=$(codex_worktree_fingerprint)
  rm -f "$combined_prompt"

  if [ "$rc" -eq 0 ] && [ -s "$CODEX_RUN_EVENTS" ]; then
    if [ -n "$schema" ] && [ -f "$schema" ]; then
      python3 - "$CODEX_RUN_EVENTS" "$out" <<'PY' || true
import sys, json, re
events_path, out_path = sys.argv[1], sys.argv[2]
with open(events_path, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()
cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip(), flags=re.S).strip()
start = cleaned.find("{")
end = cleaned.rfind("}")
if start != -1 and end != -1 and end > start:
    try:
        obj = json.loads(cleaned[start:end+1])
        with open(out_path, "w", encoding="utf-8") as out:
            json.dump(obj, out, ensure_ascii=False)
    except Exception:
        sys.exit(1)
else:
    sys.exit(1)
PY
    else
      cp "$CODEX_RUN_EVENTS" "$out"
    fi
  fi

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during read-only Claude run"
    rm -f "$out"
  elif [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Claude exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  codex_log_usage "$kind" "claude:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

# -----------------------------------------------------------------------------
# Pool D Runner: OpenCode CLI + DeepSeek API (`opencode_run`, strict read-only)
# -----------------------------------------------------------------------------
opencode_run() {
  local kind="$1" model="$2" schema="$3" out="$4" prompt_file="$5" req_paid="${6:-1}"
  local ts bin rc=0 before after msgs
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$CODEX_REPORT_DIR"
  CODEX_RUN_EVENTS="${CODEX_REPORT_DIR}/${kind}-opencode-${ts}.events.jsonl"
  CODEX_RUN_STDERR="${CODEX_REPORT_DIR}/${kind}-opencode-${ts}.stderr.log"
  CODEX_RUN_ERROR=""
  : > "$CODEX_RUN_EVENTS"; : > "$CODEX_RUN_STDERR"

  if ! bin=$(opencode_resolve_bin); then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR="OpenCode binary not found"
    codex_log_usage "$kind" "opencode:${model}" "default" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  if ! llm_load_deepseek_key; then
    if [ "$req_paid" -eq 1 ]; then
      CODEX_RUN_STATUS="UNAVAILABLE"
      CODEX_RUN_ERROR="DEEPSEEK_API_KEY not configured yet in ~/.config/llm-council/secrets.env"
      codex_log_usage "$kind" "opencode:${model}" "default" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
      return 0
    fi
    model="$OPENCODE_FREE_MODEL"
  fi

  local combined_prompt="${CODEX_REPORT_DIR}/${kind}-opencode-${ts}.prompt.md"
  cp "$prompt_file" "$combined_prompt"
  if [ -n "$schema" ] && [ -f "$schema" ]; then
    {
      echo ""
      echo "# STRICT JSON SCHEMA REQUIREMENT"
      echo "Output ONLY a raw valid JSON object (no markdown fences, no commentary before or after) strictly conforming to this JSON Schema:"
      cat "$schema"
    } >> "$combined_prompt"
  fi

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  timeout "$CODEX_TIMEOUT_SECS" "$bin" run \
    --dir "$CODEX_REPO_ROOT" \
    --agent readonly-auditor \
    -m "$model" \
    --format json \
    "Follow all instructions received on stdin strictly in read-only mode." \
    < "$combined_prompt" \
    > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR" || rc=$?
  after=$(codex_worktree_fingerprint)
  rm -f "$combined_prompt"

  if [ "$rc" -eq 0 ] && [ -s "$CODEX_RUN_EVENTS" ]; then
    python3 - "$CODEX_RUN_EVENTS" "$out" "${schema:-}" <<'PY' || true
import sys, json, re

events_path, out_path, schema_path = sys.argv[1], sys.argv[2], sys.argv[3]
texts = []
with open(events_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "text":
            part = ev.get("part") or {}
            if part.get("text"):
                texts.append(part["text"])
        elif isinstance(ev.get("text"), str):
            texts.append(ev["text"])

full = "".join(texts).strip()
if not full:
    sys.exit(1)

if schema_path:
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", full, flags=re.S).strip()
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start != -1 and end != -1 and end > start:
        obj = json.loads(cleaned[start:end+1])
        with open(out_path, "w", encoding="utf-8") as out:
            json.dump(obj, out, ensure_ascii=False)
    else:
        sys.exit(1)
else:
    with open(out_path, "w", encoding="utf-8") as out:
        out.write(full + "\n")
PY
  fi

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during OpenCode run"
    rm -f "$out"
  elif [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="OpenCode exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  codex_log_usage "$kind" "opencode:${model}" "default" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

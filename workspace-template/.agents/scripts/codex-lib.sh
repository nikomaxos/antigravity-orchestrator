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

CODEX_REPO_ROOT="/home/nick/Development/messaging-agent"
CODEX_REPORT_DIR="${CODEX_REPO_ROOT}/.agent-reports/codex"
CODEX_USAGE_LOG="${CODEX_REPORT_DIR}/usage.log"
CODEX_SCRIPTS_DIR="${CODEX_REPO_ROOT}/.agents/scripts"
CODEX_REVIEW_STATE_REL=".agent-state/codex-review.json"
CODEX_REVIEW_STATE="${CODEX_REPO_ROOT}/${CODEX_REVIEW_STATE_REL}"
CODEX_REVIEW_SCHEMA="${CODEX_SCRIPTS_DIR}/codex-review-schema.json"
LLM_COUNCIL_SECRETS="/home/nick/.config/llm-council/secrets.env"

# --- Default Model Routing (Dynamic from model-routing.json with Safe Defaults) ---
CODEX_RCA_MODEL="${CODEX_RCA_MODEL:-gpt-6-astra}"
CODEX_RCA_EFFORT="${CODEX_RCA_EFFORT:-xhigh}"
CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-gpt-6-astra}"
CODEX_REVIEW_EFFORT="${CODEX_REVIEW_EFFORT:-high}"

# Tier-specific Review Routing (R1: light UI/test, R2: standard CRUD, R3: critical)
CODEX_R1_MODEL="gpt-6.1-terra"; CODEX_R1_EFFORT="medium"
CODEX_R2_MODEL="gpt-6.1-sol";   CODEX_R2_EFFORT="high"
CODEX_R3_MODEL="gpt-6-astra";   CODEX_R3_EFFORT="high"

CLAUDE_R1_MODEL="claude-sonnet-5-5"; CLAUDE_R1_FALLBACK="sonnet"; CLAUDE_R1_EFFORT="medium"
CLAUDE_R2_MODEL="claude-sonnet-5-5"; CLAUDE_R2_FALLBACK="sonnet"; CLAUDE_R2_EFFORT="high"
CLAUDE_R3_MODEL="claude-opus-5-5";   CLAUDE_R3_FALLBACK="opus";   CLAUDE_R3_EFFORT="high"
CLAUDE_RCA_MODEL="claude-opus-5-5";  CLAUDE_RCA_FALLBACK="opus";  CLAUDE_RCA_EFFORT="high"

OPENCODE_PRO_MODEL="deepseek/deepseek-v4-pro"
OPENCODE_FLASH_MODEL="deepseek/deepseek-flash"
OPENCODE_FREE_MODEL="opencode/deepseek-v4.1-flash-free"

llm_validate_model() {
  local val="$1" default_val="$2"
  # Disallow classifier-matching keywords that could trigger false RATE_LIMITED/UNAVAILABLE
  if [[ "$val" =~ (rate|limit|quota|429|401|unauthori|balance) ]]; then
    echo "$default_val"
    return 0
  fi
  if [[ "$val" =~ ^((deepseek|opencode)/[a-z0-9.-]+|gpt-[0-9.]+-[a-z0-9]+|claude-[a-z0-9.-]+|opus|sonnet|haiku)$ ]]; then
    echo "$val"
  else
    echo "$default_val"
  fi
}
llm_validate_effort() {
  local val="$1" default_val="$2"
  if [[ "$val" =~ ^(low|medium|high|xhigh)$ ]]; then
    echo "$val"
  else
    echo "$default_val"
  fi
}

llm_load_model_routing() {
  local cfg="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
  local repo_cfg=""
  if [ -n "${CODEX_REPO_ROOT:-}" ] && [ -f "${CODEX_REPO_ROOT}/.agents/config/model-routing.json" ]; then
    repo_cfg="${CODEX_REPO_ROOT}/.agents/config/model-routing.json"
  fi
  local active_cfg="$cfg"
  [ ! -f "$active_cfg" ] && active_cfg="$repo_cfg"

  # Review cascades: prefer committed HEAD config if available to prevent uncommitted worktree gate tampering
  local review_json=""
  if [ -n "${CODEX_REPO_ROOT:-}" ]; then
    review_json=$(git -C "$CODEX_REPO_ROOT" show HEAD:.agents/config/model-routing.json 2>/dev/null || true)
  fi
  local review_cfg=""
  if [ -n "$review_json" ]; then
    review_cfg="<COMMITTED_HEAD>"
  elif [ -n "$repo_cfg" ] && [ -f "$repo_cfg" ]; then
    review_cfg="$repo_cfg"
  elif [ -f "$active_cfg" ]; then
    review_cfg="$active_cfg"
  fi

  _jq_review() {
    local query="$1" def="$2"
    if [ "$review_cfg" = "<COMMITTED_HEAD>" ]; then
      printf '%s' "$review_json" | jq -r "$query" 2>/dev/null || echo "$def"
    elif [ -n "$review_cfg" ] && [ -f "$review_cfg" ]; then
      jq -r "$query" "$review_cfg" 2>/dev/null || echo "$def"
    else
      echo "$def"
    fi
  }

  if command -v jq >/dev/null 2>&1; then
    CODEX_R1_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r1.pool_b.model // "gpt-6.1-terra"' 'gpt-6.1-terra')" "gpt-6.1-terra")
    CODEX_R1_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r1.pool_b.effort // "medium"' 'medium')" "medium")
    CODEX_R2_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r2.pool_b.model // "gpt-6.1-sol"' 'gpt-6.1-sol')" "gpt-6.1-sol")
    CODEX_R2_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r2.pool_b.effort // "high"' 'high')" "high")
    CODEX_R3_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r3.pool_b.model // "gpt-6-astra"' 'gpt-6-astra')" "gpt-6-astra")
    CODEX_R3_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r3.pool_b.effort // "high"' 'high')" "high")
    CODEX_REVIEW_MODEL="${CODEX_R3_MODEL}"
    CODEX_REVIEW_EFFORT="${CODEX_R3_EFFORT}"

    CLAUDE_R1_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r1.pool_c.model // "claude-sonnet-5-5"' 'claude-sonnet-5-5')" "claude-sonnet-5-5")
    CLAUDE_R1_FALLBACK=$(llm_validate_model "$(_jq_review '.review_cascades.r1.pool_c.fallback // "sonnet"' 'sonnet')" "sonnet")
    CLAUDE_R1_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r1.pool_c.effort // "medium"' 'medium')" "medium")
    CLAUDE_R2_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r2.pool_c.model // "claude-sonnet-5-5"' 'claude-sonnet-5-5')" "claude-sonnet-5-5")
    CLAUDE_R2_FALLBACK=$(llm_validate_model "$(_jq_review '.review_cascades.r2.pool_c.fallback // "sonnet"' 'sonnet')" "sonnet")
    CLAUDE_R2_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r2.pool_c.effort // "high"' 'high')" "high")
    CLAUDE_R3_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r3.pool_c.model // "claude-opus-5-5"' 'claude-opus-5-5')" "claude-opus-5-5")
    CLAUDE_R3_FALLBACK=$(llm_validate_model "$(_jq_review '.review_cascades.r3.pool_c.fallback // "opus"' 'opus')" "opus")
    CLAUDE_R3_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r3.pool_c.effort // "high"' 'high')" "high")
    OPENCODE_REVIEW_MODEL=$(llm_validate_model "$(_jq_review '.review_cascades.r3.pool_d.model // "deepseek/deepseek-v4-pro"' 'deepseek/deepseek-v4-pro')" "deepseek/deepseek-v4-pro")
  fi

  if [ -f "$active_cfg" ] && command -v jq >/dev/null 2>&1; then
    CODEX_RCA_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_b.models.rca.primary // "gpt-6-astra"' "$active_cfg" 2>/dev/null || echo "gpt-6-astra")" "gpt-6-astra")
    CODEX_RCA_EFFORT=$(llm_validate_effort "$(jq -r '.pools.pool_b.models.rca.primary_effort // "xhigh"' "$active_cfg" 2>/dev/null || echo "xhigh")" "xhigh")
    CLAUDE_RCA_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_c.models.rca.primary // "claude-opus-5-5"' "$active_cfg" 2>/dev/null || echo "claude-opus-5-5")" "claude-opus-5-5")
    CLAUDE_RCA_FALLBACK=$(llm_validate_model "$(jq -r '.pools.pool_c.models.rca.fallback // "opus"' "$active_cfg" 2>/dev/null || echo "opus")" "opus")
    CLAUDE_RCA_EFFORT=$(llm_validate_effort "$(jq -r '.pools.pool_c.models.rca.primary_effort // "high"' "$active_cfg" 2>/dev/null || echo "high")" "high")
    OPENCODE_PRO_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.pro_fallback.primary // "deepseek/deepseek-v4-pro"' "$active_cfg" 2>/dev/null || echo "deepseek/deepseek-v4-pro")" "deepseek/deepseek-v4-pro")
    OPENCODE_FLASH_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.t1_flash.primary // "deepseek/deepseek-flash"' "$active_cfg" 2>/dev/null || echo "deepseek/deepseek-flash")" "deepseek/deepseek-flash")
    OPENCODE_FREE_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.t1_flash.free_fallback // "opencode/deepseek-v4.1-flash-free"' "$active_cfg" 2>/dev/null || echo "opencode/deepseek-v4.1-flash-free")" "opencode/deepseek-v4.1-flash-free")
  fi
}
llm_load_model_routing

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
)

# Shared non-code exclusions for QA/Regression/Skills worktree hashes
NON_CODE_WORKTREE_EXCLUDES=(
  ":(exclude).agent-state"
  ":(exclude).agent-reports"
  ":(exclude).last-staging-deploy"
  ":(exclude)*.md"
  ":(exclude).agents/skills"
  ":(exclude)platform-docs"
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
  local home="${HOME:-/home/nick}" candidate=""
  if [ -x "${home}/.npm-global/bin/codex" ]; then echo "${home}/.npm-global/bin/codex"; return 0; fi
  candidate=$(ls -d "${home}"/.antigravity/extensions/openai.chatgpt-*/bin/linux-*/codex 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
  if command -v codex >/dev/null 2>&1; then command -v codex; return 0; fi
  return 1
}

claude_resolve_bin() {
  local home="${HOME:-/home/nick}"
  if [ -x "${home}/.local/bin/claude" ]; then echo "${home}/.local/bin/claude"; return 0; fi
  if [ -x "${home}/.npm-global/bin/claude" ]; then echo "${home}/.npm-global/bin/claude"; return 0; fi
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  return 1
}

opencode_resolve_bin() {
  local home="${HOME:-/home/nick}"
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

codex_pool_in_cooldown() {  # $1 = provider_model (e.g. "codex:gpt-6-astra"), $2 = cooldown_secs (default 900)
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

# Classify staged diff into R1 (light UI/test), R2 (standard CRUD/fullstack), or R3 (critical)
codex_classify_diff_tier() {
  local files diff_lines
  files=$(codex_staged_files)
  diff_lines=$(codex_staged_diff | grep -cE '^[+-][^+-]' || true)

  if grep -qE '(\.lua$|/V[0-9]+__.*\.sql$|SmscConnectionManager|Smpp|RateLimit|RfSegment|RfCapacity|FallbackScheduler|SmsInboundConsumer|SmsOutbound|Ejoin|SecurityConfig|Jwt|Auth|EncryptionService|deploy-k8s|Dockerfile|docker-compose|apisix|update-hetzner-firewall|setup-git-hooks\.sh|\.agents/scripts/|\.agents/hooks\.json)' <<< "$files" \
     || [ "${diff_lines:-0}" -ge 350 ]; then
    echo "R3"
    return 0
  fi

  if [ "${diff_lines:-0}" -lt 60 ] && ! grep -qE '(^services/|^shared-libs/|pom\.xml$|\.sh$)' <<< "$files"; then
    echo "R1"
    return 0
  fi

  echo "R2"
}

codex_is_security_sensitive_files() {  # $1 = newline-separated file list
  grep -qE '(SecurityConfig|Jwt|Auth|EncryptionService|apisix|deploy-k8s|Dockerfile|docker-compose|update-hetzner-firewall|setup-git-hooks\.sh|\.agents/scripts/|\.agents/hooks\.json)' <<< "${1:-}"
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
  cat "$root/.agents/AGENTS.md" 2>/dev/null || echo "(missing)"
  local f
  for f in "$root"/.agents/rules/*.md; do
    [ -f "$f" ] || continue
    echo
    echo "### ${f#"$root"/}"
    cat "$f"
  done
  echo
  echo "### .agents/PROJECT_KNOWLEDGE.md (index + operating rules; changelog omitted)"
  sed -n '1,/^## 📝 Recent Chat Outcomes/p' "$root/.agents/PROJECT_KNOWLEDGE.md" 2>/dev/null | sed '$d'
  echo
  echo "Domain knowledge files — read ONLY the 1-2 directly relevant to changed files:"
  ls -1 "$root"/.agents/knowledge/*.md 2>/dev/null | sed "s|^$root/|- |"
}

codex_build_compact_ui_context() {
  local root="$CODEX_REPO_ROOT"
  echo "### UI & Security Rules (Compact R1 Mode — Do NOT scan unrelated backend services)"
  echo "- Preserve UI Design System (.agents/knowledge/ui-design-system.md): never arbitrarily alter fonts, colors, pill badges, table headers, or fill-current on Play/Square icons."
  echo "- No-Hardcoded-Routing invariant: never hardcode routing/retry/TPS constants in TS/JS."
  echo "- Security: verify zero XSS (dangerouslySetInnerHTML / unescaped URLs), zero leaked secrets, and clean TypeScript types."
  if [ -f "$root/.agents/knowledge/ui-design-system.md" ]; then
    echo
    echo "### .agents/knowledge/ui-design-system.md (excerpt)"
    head -n 80 "$root/.agents/knowledge/ui-design-system.md"
  fi
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
  grep -qiE '401|unauthori[sz]ed|not logged in|login required|please (log|sign) ?in|token (expired|invalid)|refresh token|authentication|invalid api key|api_key|claude login|credit balance is too low'
}

codex_log_usage() {  # kind provider_model effort status events_file
  local usage=""
  if [ -f "${5:-}" ]; then
    usage=$(jq -c -R 'fromjson? | select(.usage) | .usage' "$5" 2>/dev/null | tail -1 || true)
  fi
  [ -z "$usage" ] && usage="{}"
  mkdir -p "$CODEX_REPORT_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$usage" >> "$CODEX_USAGE_LOG"
}

codex_prune_logs() {
  local pattern
  for pattern in '*.events.jsonl' '*.stderr.log' '*.prompt.md'; do
    # shellcheck disable=SC2012
    ls -1t "$CODEX_REPORT_DIR"/$pattern 2>/dev/null | tail -n +"$((CODEX_KEEP_RUN_LOGS + 1))" | xargs -r rm -f || true
  done
}

# -----------------------------------------------------------------------------
# Pool B Runner: OpenAI Codex CLI (`codex_run` & `codex_run_resume`)
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

  local args=(exec -C "$CODEX_REPO_ROOT" -s read-only -m "$model"
              -c "model_reasoning_effort=\"${effort}\""
              -c 'features.multi_agent=false'
              -c 'approval_policy="never"'
              --json -o "$out")
  [ -n "$schema" ] && args+=(--output-schema "$schema")

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  timeout "$CODEX_TIMEOUT_SECS" "$bin" "${args[@]}" - < "$prompt_file" \
    > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR" || rc=$?
  after=$(codex_worktree_fingerprint)

  CODEX_LAST_THREAD_ID=$(jq -r -R 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$CODEX_RUN_EVENTS" 2>/dev/null | head -1 || true)
  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during Codex run"
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
  codex_prune_logs
  return 0
}

codex_run_resume() {  # kind thread_id model effort schema out prompt_file
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
    return 0
  fi

  local args=(exec resume "$thread_id" -s read-only -m "$model"
              -c "model_reasoning_effort=\"${effort}\""
              -c 'features.multi_agent=false'
              -c 'approval_policy="never"'
              --json -o "$out")
  [ -n "$schema" ] && args+=(--output-schema "$schema")

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  (
    cd "$CODEX_REPO_ROOT"
    timeout "$CODEX_TIMEOUT_SECS" "$bin" "${args[@]}" - < "$prompt_file" \
      > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR"
  ) || rc=$?
  after=$(codex_worktree_fingerprint)

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during Codex resume run"
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

  codex_log_usage "${kind}-resume" "codex:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

# -----------------------------------------------------------------------------
# Pool C Runner: Anthropic Claude Code CLI (`claude_run`, strict read-only)
# -----------------------------------------------------------------------------
claude_run() {  # kind model effort schema_or_empty out prompt_file
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
    CODEX_RUN_ERROR="Claude CLI binary not found"
    codex_log_usage "$kind" "claude:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  local args=(-p --model "$model" --effort "$effort" --permission-mode plan
              --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)"
              --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit"
              --max-turns 25)
  if [ -n "$schema" ] && [ -f "$schema" ]; then
    args+=(--output-format json --json-schema "$(tr -d '\n' < "$schema")")
  else
    args+=(--output-format json)
  fi

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  (
    cd "$CODEX_REPO_ROOT"
    timeout "$CODEX_TIMEOUT_SECS" "$bin" "${args[@]}" < "$prompt_file" \
      > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR"
  ) || rc=$?
  after=$(codex_worktree_fingerprint)

  # Extract structured JSON or markdown text from Claude's JSON wrapper
  if [ "$rc" -eq 0 ] && [ -s "$CODEX_RUN_EVENTS" ]; then
    local is_err
    is_err=$(jq -r 'if type=="object" then (.is_error // false) else false end' "$CODEX_RUN_EVENTS" 2>/dev/null || echo "false")
    if [ "$is_err" = "true" ]; then
      rc=1
    elif [ -n "$schema" ]; then
      jq -c 'if .structured_output then .structured_output elif (.result | type == "string") then (.result | fromjson) else . end' \
        "$CODEX_RUN_EVENTS" > "$out" 2>/dev/null || rm -f "$out"
    else
      jq -r '.result // empty' "$CODEX_RUN_EVENTS" > "$out" 2>/dev/null || rm -f "$out"
    fi
  fi

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  # 1. Immediate Integrity Verification: If worktree mutated, abort instantly without retry!
  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during Claude CLI run"
    rm -f "$out"
    codex_log_usage "$kind" "claude:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
    return 0
  fi

  # 2. Check if model was rejected by Claude CLI version and fallback is available (only on clean worktree)
  if [ "$rc" -ne 0 ] && printf '%s' "$msgs" | grep -qiE '(unknown model|invalid model|model.*not found|model.*not supported|valid models are)'; then
    local fallback_model=""
    case "$model" in
      *sonnet*) fallback_model="sonnet" ;;
      *opus*)   fallback_model="opus" ;;
      *haiku*)  fallback_model="haiku" ;;
    esac
    if [ -n "$fallback_model" ] && [ "$fallback_model" != "$model" ]; then
      echo "ℹ️  Claude CLI rejected model '${model}'; retrying with fallback model '${fallback_model}'..." >&2
      codex_log_usage "$kind" "claude:${model}" "$effort" "MODEL_FALLBACK" "$CODEX_RUN_EVENTS"
      claude_run "$kind" "$fallback_model" "$effort" "$schema" "$out" "$prompt_file"
      return $?
    fi
  fi

  if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Claude CLI exceeded ${CODEX_TIMEOUT_SECS}s"
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
opencode_run() {  # kind model schema_or_empty out prompt_file [require_paid_key: 0|1]
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
      CODEX_RUN_ERROR="DEEPSEEK_API_KEY not configured yet (run set-deepseek-key)"
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
    # Strip markdown code fences if present and extract outermost JSON object
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

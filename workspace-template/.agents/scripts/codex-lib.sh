#!/usr/bin/env bash
# =============================================================================
# Multi-CLI Cross-Model Council — Shared Library (`codex-lib.sh`)
# =============================================================================
# Sourced by: codex-rca.sh, run-codex-review-gate.sh, stage0-precheck.sh,
#             sync-security-from-review.sh, commit-gate.sh, preflight.sh
# Do NOT execute directly.
#
# Active Automated Pools (Single-Writer Invariant: ONLY Antigravity writes files):
#   - Pool 0: Deterministic Linux Offload Bots (`0` LLM tokens)
#   - Pool B: OpenAI Codex CLI (`codex exec` / `codex exec resume`, `-s read-only`)
#   - Pool C: Anthropic Claude Code CLI (`claude -p --permission-mode plan`)
#   - Pool A: Antigravity Native (`--fallback` subagent ONLY if B+C both fail)
#   - Pool D (Manual-Only): OpenCode CLI + DeepSeek API — NEVER invoked automatically;
#     only runs when explicitly triggered by the user (`/opencode`, `--cli opencode`,
#     or `stage0-precheck.sh --manual`).
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
CLAUDE_R3_MODEL="claude-opus-5-5";   CLAUDE_R3_FALLBACK="opus";   CLAUDE_R3_EFFORT="high"; CLAUDE_R3_FALLBACK2="claude-sonnet-5-5"
CLAUDE_RCA_MODEL="claude-sonnet-5-5"; CLAUDE_RCA_FALLBACK="sonnet"; CLAUDE_RCA_EFFORT="high"
CLAUDE_RCA_OPUS_MODEL="claude-opus-5-5"

CLAUDE_MAX_TURNS_REVIEW="${CLAUDE_MAX_TURNS_REVIEW:-12}"
CLAUDE_R1_MAX_TURNS="${CLAUDE_R1_MAX_TURNS:-10}"
CLAUDE_R2_MAX_TURNS="${CLAUDE_R2_MAX_TURNS:-12}"
CLAUDE_R3_MAX_TURNS="${CLAUDE_R3_MAX_TURNS:-16}"
CLAUDE_MAX_TURNS_RCA="${CLAUDE_MAX_TURNS_RCA:-16}"
CLAUDE_MAX_TURNS_DEFAULT="${CLAUDE_MAX_TURNS_DEFAULT:-25}"

POOL_COOLDOWN_ENABLED="true"
POOL_COOLDOWN_DEFAULT_TTL="${FRONTIER_COOLDOWN_SECS:-1800}"
POOL_COOLDOWN_MIN_TTL="60"
POOL_COOLDOWN_MAX_TTL="21600"
POOL_COOLDOWN_FILE="${HOME}/.gemini/cache/pool-cooldowns.json"

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
    CLAUDE_R3_FALLBACK2=$(llm_validate_model "$(_jq_review '.pools.pool_c.models.review.r3.secondary_fallback // "claude-sonnet-5-5"' 'claude-sonnet-5-5')" "claude-sonnet-5-5")
    CLAUDE_R3_EFFORT=$(llm_validate_effort "$(_jq_review '.review_cascades.r3.pool_c.effort // "high"' 'high')" "high")
    OPENCODE_REVIEW_MODEL="$OPENCODE_PRO_MODEL"
    local mt_r1 mt_r2 mt_r3
    mt_r1=$(_jq_review '.review_cascades.r1.claude_max_turns // "10"' '10')
    [[ "$mt_r1" =~ ^[0-9]+$ ]] && [ "$mt_r1" -ge 1 ] && [ "$mt_r1" -le 50 ] && CLAUDE_R1_MAX_TURNS="$mt_r1"
    mt_r2=$(_jq_review '.review_cascades.r2.claude_max_turns // "12"' '12')
    [[ "$mt_r2" =~ ^[0-9]+$ ]] && [ "$mt_r2" -ge 1 ] && [ "$mt_r2" -le 50 ] && CLAUDE_R2_MAX_TURNS="$mt_r2"
    mt_r3=$(_jq_review '.review_cascades.r3.claude_max_turns // "16"' '16')
    [[ "$mt_r3" =~ ^[0-9]+$ ]] && [ "$mt_r3" -ge 1 ] && [ "$mt_r3" -le 50 ] && CLAUDE_R3_MAX_TURNS="$mt_r3"
    CLAUDE_MAX_TURNS_REVIEW="$CLAUDE_R3_MAX_TURNS"
  fi

  if [ -f "$active_cfg" ] && command -v jq >/dev/null 2>&1; then
    CODEX_RCA_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_b.models.rca.primary // "gpt-6-astra"' "$active_cfg" 2>/dev/null || echo "gpt-6-astra")" "gpt-6-astra")
    CODEX_RCA_EFFORT=$(llm_validate_effort "$(jq -r '.pools.pool_b.models.rca.primary_effort // "xhigh"' "$active_cfg" 2>/dev/null || echo "xhigh")" "xhigh")
    CLAUDE_RCA_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_c.models.rca.primary // "claude-sonnet-5-5"' "$active_cfg" 2>/dev/null || echo "claude-sonnet-5-5")" "claude-sonnet-5-5")
    CLAUDE_RCA_FALLBACK=$(llm_validate_model "$(jq -r '.pools.pool_c.models.rca.fallback // "sonnet"' "$active_cfg" 2>/dev/null || echo "sonnet")" "sonnet")
    CLAUDE_RCA_EFFORT=$(llm_validate_effort "$(jq -r '.pools.pool_c.models.rca.primary_effort // "high"' "$active_cfg" 2>/dev/null || echo "high")" "high")
    CLAUDE_RCA_OPUS_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_c.models.rca.opus_escalation // "claude-opus-5-5"' "$active_cfg" 2>/dev/null || echo "claude-opus-5-5")" "claude-opus-5-5")
    local mt_rca
    mt_rca=$(jq -r '.pools.pool_c.models.rca.max_turns // "16"' "$active_cfg" 2>/dev/null || echo "16")
    [[ "$mt_rca" =~ ^[0-9]+$ ]] && [ "$mt_rca" -ge 1 ] && [ "$mt_rca" -le 50 ] && CLAUDE_MAX_TURNS_RCA="$mt_rca"
    OPENCODE_PRO_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.pro_fallback.primary // "deepseek/deepseek-v4-pro"' "$active_cfg" 2>/dev/null || echo "deepseek/deepseek-v4-pro")" "deepseek/deepseek-v4-pro")
    OPENCODE_FLASH_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.t1_flash.primary // "deepseek/deepseek-flash"' "$active_cfg" 2>/dev/null || echo "deepseek/deepseek-flash")" "deepseek/deepseek-flash")
    OPENCODE_FREE_MODEL=$(llm_validate_model "$(jq -r '.pools.pool_d.models.t1_flash.free_fallback // "opencode/deepseek-v4.1-flash-free"' "$active_cfg" 2>/dev/null || echo "opencode/deepseek-v4.1-flash-free")" "opencode/deepseek-v4.1-flash-free")

    local cd_en cd_def cd_min cd_max cd_file
    cd_en=$(jq -r 'if .pool_cooldown.enabled == false then "false" else "true" end' "$active_cfg" 2>/dev/null || echo "true")
    POOL_COOLDOWN_ENABLED="$cd_en"
    cd_min=$(jq -r '.pool_cooldown.min_ttl_secs // 60' "$active_cfg" 2>/dev/null || echo "60")
    [[ "$cd_min" =~ ^[0-9]+$ ]] && [ "$cd_min" -ge 1 ] && POOL_COOLDOWN_MIN_TTL="$cd_min"
    cd_max=$(jq -r '.pool_cooldown.max_ttl_secs // 21600' "$active_cfg" 2>/dev/null || echo "21600")
    [[ "$cd_max" =~ ^[0-9]+$ ]] && [ "$cd_max" -ge "$POOL_COOLDOWN_MIN_TTL" ] && POOL_COOLDOWN_MAX_TTL="$cd_max"
    if [ -z "${FRONTIER_COOLDOWN_SECS:-}" ]; then
      cd_def=$(jq -r '.pool_cooldown.default_ttl_secs // 1800' "$active_cfg" 2>/dev/null || echo "1800")
      [[ "$cd_def" =~ ^[0-9]+$ ]] && POOL_COOLDOWN_DEFAULT_TTL="$cd_def"
    fi
    if [ -z "${AGY_POOL_COOLDOWN_FILE:-}" ]; then
      cd_file=$(jq -r '.pool_cooldown.state_file // ""' "$active_cfg" 2>/dev/null || true)
      if [ -n "$cd_file" ] && [[ "$cd_file" != *".."* ]]; then
        local cache_base resolved_cache candidate=""
        cache_base="${HOME}/.gemini/cache"
        if [[ "$cd_file" == "~/"* ]]; then
          candidate="${HOME}/${cd_file#"~/"}"
        elif [[ "$cd_file" == /* ]]; then
          candidate="$cd_file"
        fi
        if [ -n "$candidate" ] && [[ "$candidate" == *.json ]] && command -v realpath >/dev/null 2>&1; then
          resolved_cache=$(realpath -m "$cache_base" 2>/dev/null || echo "$cache_base")
          candidate=$(realpath -m "$candidate" 2>/dev/null || echo "")
          if [ -n "$candidate" ] && [[ "$candidate" == "${resolved_cache}/"* ]]; then
            POOL_COOLDOWN_FILE="$candidate"
          fi
        fi
      fi
    fi
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

_pool_cooldown_state_file() {
  local f="${AGY_POOL_COOLDOWN_FILE:-${POOL_COOLDOWN_FILE:-${HOME}/.gemini/cache/pool-cooldowns.json}}"
  printf '%s' "$f"
}

_pool_cooldown_normalize() {  # $1 = raw_key -> outputs "primary_key<TAB>parent_pool_or_empty"
  local raw="${1:-}"
  case "$raw" in
    codex:*)    printf 'pool_b:%s\tpool_b' "${raw#codex:}" ;;
    claude:*)   printf 'pool_c:%s\tpool_c' "${raw#claude:}" ;;
    opencode:*) printf 'pool_d:%s\tpool_d' "${raw#opencode:}" ;;
    pool_b:*)   printf '%s\tpool_b' "$raw" ;;
    pool_c:*)   printf '%s\tpool_c' "$raw" ;;
    pool_d:*)   printf '%s\tpool_d' "$raw" ;;
    *)          printf '%s\t' "$raw" ;;
  esac
}

# Read provider error text via stdin; output "<until_epoch>\t<until_iso>\t<ttl>\t<source>"
pool_cooldown_parse_reset_epoch() {
  local def_ttl="${1:-${POOL_COOLDOWN_DEFAULT_TTL:-1800}}"
  local min_ttl="${2:-${POOL_COOLDOWN_MIN_TTL:-60}}"
  local max_ttl="${3:-${POOL_COOLDOWN_MAX_TTL:-21600}}"
  local now_ep="${4:-$(date -u +%s)}"

  if ! command -v node >/dev/null 2>&1; then
    local ttl="$def_ttl"
    [ "$ttl" -lt "$min_ttl" ] && ttl="$min_ttl"
    [ "$ttl" -gt "$max_ttl" ] && ttl="$max_ttl"
    local u=$((now_ep + ttl))
    printf '%s\t%s\t%s\tdefault\n' "$u" "$(date -u -d "@$u" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" "$ttl"
    return 0
  fi

  node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(0, "utf8").slice(0, 65536);
    const nowEp = Number(process.argv[1]) || Math.floor(Date.now() / 1000);
    const defTtl = Math.max(1, Number(process.argv[2]) || 1800);
    const minTtl = Math.max(1, Number(process.argv[3]) || 60);
    const maxTtl = Math.max(minTtl, Number(process.argv[4]) || 21600);

    let parsedEp = null;

    // 1. Explicit ISO-8601 datetime (e.g. 2026-11-23T18:01:00Z or +02:00)
    const isoRe = /\b(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2}|\s*UTC))\b/gi;
    let m;
    while ((m = isoRe.exec(raw)) !== null) {
      let s = m[1].trim().replace(/ UTC$/i, "Z").replace(" ", "T");
      const ms = Date.parse(s);
      if (Number.isFinite(ms)) {
        const ep = Math.floor(ms / 1000);
        if (ep > nowEp) { parsedEp = ep; break; }
      }
    }

    // 2. Retry-After HTTP header (unit optional) OR natural prose seconds (seconds unit REQUIRED)
    if (parsedEp === null) {
      const hdrSecRe = /\bretry-after\s*[:=]\s*(\d+)\b/i;
      const proseSecRe = /(?:retry\s+after|try\s+again\s+(?:after|in))\s+(\d+)\s*(?:s|sec|secs|second|seconds)\b/i;
      const sm = hdrSecRe.exec(raw) || proseSecRe.exec(raw);
      if (sm) {
        const secs = parseInt(sm[1], 10);
        if (Number.isFinite(secs) && secs > 0) parsedEp = nowEp + secs;
      }
    }

    // 3. Relative duration (in Xh Ym Zs)
    if (parsedEp === null) {
      const relRe = /(?:try\s+again|resets?|available|wait|cooldown)\s+(?:in|after)\s+(?:(\d+)\s*h(?:ours?|rs?)?[\s,]*)?(?:(\d+)\s*m(?:in(?:utes?)?)?[\s,]*)?(?:(\d+)\s*s(?:ec(?:onds?)?)?)?/i;
      const rm = relRe.exec(raw);
      if (rm && (rm[1] || rm[2] || rm[3])) {
        const h = parseInt(rm[1] || "0", 10);
        const min = parseInt(rm[2] || "0", 10);
        const s = parseInt(rm[3] || "0", 10);
        const tot = h * 3600 + min * 60 + s;
        if (tot > 0) parsedEp = nowEp + tot;
      }
    }

    // 4. Month Day [at] HH[:MM] [AM/PM] (e.g. "resets Nov 24 at 2:00pm")
    if (parsedEp === null) {
      const mdRe = /(?:try\s+again|resets?)\s+(?:on\s+|at\s+)?([A-Za-z]{3,9}\s+\d{1,2}(?:,?\s*\d{4})?(?:\s+at)?\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?(?:\s*\(?(?:UTC|GMT)\)?)?)/i;
      const mm = mdRe.exec(raw);
      if (mm) {
        const nowD = new Date(nowEp * 1000);
        let str = mm[1].replace(/\s+at\s+/i, " ").replace(/\(?(UTC|GMT)\)?/i, " $1").trim();
        if (!/\b\d{4}\b/.test(str)) str = `${nowD.getFullYear()} ${str}`;
        const ms = Date.parse(str);
        if (Number.isFinite(ms)) {
          let ep = Math.floor(ms / 1000);
          if (ep <= nowEp - 30 && !/\b\d{4}\b/.test(mm[1])) {
            const msNext = Date.parse(`${nowD.getFullYear() + 1} ` + mm[1].replace(/\s+at\s+/i, " "));
            if (Number.isFinite(msNext)) ep = Math.floor(msNext / 1000);
          }
          if (ep > nowEp) parsedEp = ep;
        }
      }
    }

    // 5. Time of day ("try again at 6:01 PM", "resets at 18:01", "resets 5pm", "at 18:01 UTC")
    if (parsedEp === null) {
      const todRe = /(?:try\s+again|resets?|until)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?(?:\s*\(?(UTC|GMT)\)?)?\b/i;
      const tm = todRe.exec(raw);
      if (tm && (tm[2] !== undefined || tm[4] !== undefined)) {
        let hr = parseInt(tm[1], 10);
        const mn = parseInt(tm[2] || "0", 10);
        const sc = parseInt(tm[3] || "0", 10);
        const ampm = (tm[4] || "").toLowerCase();
        const isUtc = Boolean(tm[5]);
        let valid = mn >= 0 && mn < 60 && sc >= 0 && sc < 60;
        if (ampm) {
          if (hr < 1 || hr > 12) valid = false;
          if (ampm === "am") hr = (hr === 12 ? 0 : hr);
          if (ampm === "pm") hr = (hr === 12 ? 12 : hr + 12);
        } else if (hr < 0 || hr > 23) {
          valid = false;
        }
        if (valid) {
          const d = new Date(nowEp * 1000);
          if (isUtc) {
            d.setUTCHours(hr, mn, sc, 0);
          } else {
            d.setHours(hr, mn, sc, 0);
          }
          let ep = Math.floor(d.getTime() / 1000);
          if (ep <= nowEp - 30) ep += 86400;
          if (ep > nowEp) parsedEp = ep;
        }
      }
    }

    let ttl, src;
    if (parsedEp !== null && Number.isFinite(parsedEp) && parsedEp > nowEp) {
      const rawTtl = Math.round(parsedEp - nowEp);
      ttl = Math.max(minTtl, Math.min(maxTtl, rawTtl));
      src = ttl === rawTtl ? "parsed" : "parsed_clamped";
    } else {
      ttl = Math.max(minTtl, Math.min(maxTtl, defTtl));
      src = "default";
    }
    const untilEp = nowEp + ttl;
    const untilIso = new Date(untilEp * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
    process.stdout.write(`${untilEp}\t${untilIso}\t${ttl}\t${src}\n`);
  ' "$now_ep" "$def_ttl" "$min_ttl" "$max_ttl"
}

pool_cooldown_set() {  # $1 = pool_key, $2 = reason, [$3 = ttl_secs | file...], [$4+ = extra files]
  local raw_key="${1:-}" reason="${2:-rate_limited}" arg3="${3:-}"
  shift 2 || true
  [ "${POOL_COOLDOWN_ENABLED:-true}" = "false" ] && return 0
  if ! [[ "$raw_key" =~ ^[A-Za-z0-9_.:/-]{1,80}$ ]]; then
    echo "⚠️  Invalid pool cooldown key rejected: '${raw_key}'" >&2
    return 1
  fi

  local norm primary_key
  norm=$(_pool_cooldown_normalize "$raw_key")
  primary_key="${norm%%	*}"

  local cd_file cd_dir
  cd_file=$(_pool_cooldown_state_file)
  cd_dir=$(dirname "$cd_file")
  if [ -L "$cd_dir" ] || [ -L "$cd_file" ]; then
    echo "⚠️  Refusing symlink pool cooldown path: ${cd_file}" >&2
    return 1
  fi
  mkdir -p "$cd_dir" 2>/dev/null || return 1
  chmod 700 "$cd_dir" 2>/dev/null || true

  local now_ep parsed until_ep until_iso ttl src
  now_ep=$(date -u +%s)
  local def_ttl="${POOL_COOLDOWN_DEFAULT_TTL:-1800}"
  local min_ttl="${POOL_COOLDOWN_MIN_TTL:-60}"
  local max_ttl="${POOL_COOLDOWN_MAX_TTL:-21600}"

  if [[ "$arg3" =~ ^[0-9]+$ ]]; then
    ttl="$arg3"
    [ "$ttl" -lt "$min_ttl" ] && ttl="$min_ttl"
    [ "$ttl" -gt "$max_ttl" ] && ttl="$max_ttl"
    until_ep=$((now_ep + ttl))
    until_iso=$(date -u -d "@$until_ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    src="explicit"
  else
    parsed=$(
      {
        printf '%s\n' "$reason"
        local f
        for f in "$@"; do
          if [ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ]; then
            head -c 65536 "$f" 2>/dev/null || true
            printf '\n'
          fi
        done
      } | pool_cooldown_parse_reset_epoch "$def_ttl" "$min_ttl" "$max_ttl" "$now_ep"
    )
    until_ep=$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')
    until_iso=$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')
    ttl=$(printf '%s' "$parsed" | awk -F'\t' '{print $3}')
    src=$(printf '%s' "$parsed" | awk -F'\t' '{print $4}')
  fi

  [ -L "$cd_file" ] && { echo "⚠️  Refusing symlink pool cooldown file: ${cd_file}" >&2; return 1; }
  local lock_file="${cd_file}.lock"
  if [ -L "$lock_file" ]; then
    echo "⚠️  Refusing symlink lock file: ${lock_file}" >&2
    return 1
  fi
  command -v node >/dev/null 2>&1 || return 1

  (
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$lock_file"
      chmod 600 "$lock_file" 2>/dev/null || true
      flock -w 2 9 || true
    fi
    node -e '
      const fs = require("fs");
      const crypto = require("crypto");
      const file = process.argv[1];
      const key = process.argv[2];
      const reason = (process.argv[3] || "").slice(0, 240);
      const untilEp = Number(process.argv[4]);
      const untilIso = process.argv[5];
      const ttlSecs = Number(process.argv[6]);
      const nowEp = Number(process.argv[7]);
      const source = process.argv[8] || "default";
      const maxTtl = Number(process.argv[9]) || 21600;

      try {
        if (fs.lstatSync(file).isSymbolicLink()) process.exit(1);
      } catch (e) {
        if (e.code !== "ENOENT") process.exit(1);
      }

      let data = { version: 1, pools: {} };
      try {
        const raw = JSON.parse(fs.readFileSync(file, "utf8"));
        if (raw && typeof raw === "object" && raw.pools && typeof raw.pools === "object") {
          data = raw;
        }
      } catch {}

      const pruned = {};
      for (const [k, v] of Object.entries(data.pools || {})) {
        if (v && typeof v.until_epoch === "number") {
          const setAt = typeof v.set_at_epoch === "number" ? v.set_at_epoch : nowEp;
          if (setAt <= nowEp + 60) {
            const eff = Math.min(v.until_epoch, setAt + maxTtl);
            if (eff > nowEp) pruned[k] = v;
          }
        }
      }
      pruned[key] = {
        until_epoch: untilEp,
        until_iso: untilIso,
        set_at_epoch: nowEp,
        set_at_iso: new Date(nowEp * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
        ttl_secs: ttlSecs,
        source,
        reason,
      };
      const out = JSON.stringify({ version: 1, pools: pruned }, null, 2) + "\n";
      const tmp = `${file}.tmp.${process.pid}.${crypto.randomBytes(6).toString("hex")}`;
      fs.writeFileSync(tmp, out, { mode: 0o600, flag: "wx" });
      fs.chmodSync(tmp, 0o600);
      fs.renameSync(tmp, file);
    ' "$cd_file" "$primary_key" "$reason" "$until_ep" "$until_iso" "$ttl" "$now_ep" "$src" "$max_ttl"
  )
}

# Prints "<human> remaining (until <iso>)" if active & returns 0; returns 1 otherwise (100% read-only; clamps read expiry to max_ttl).
pool_cooldown_is_active() {  # $1 = pool_key
  local raw_key="${1:-}"
  [ "${AGY_IGNORE_COOLDOWN:-0}" = "1" ] && return 1
  [ "${POOL_COOLDOWN_ENABLED:-true}" = "false" ] && return 1
  [ -n "$raw_key" ] || return 1

  local cd_file
  cd_file=$(_pool_cooldown_state_file)
  if [ -L "$cd_file" ]; then
    echo "⚠️  Refusing symlink pool cooldown file: ${cd_file}" >&2
    return 1
  fi
  [ -f "$cd_file" ] || return 1

  local norm primary_key parent_key
  norm=$(_pool_cooldown_normalize "$raw_key")
  primary_key="${norm%%	*}"
  parent_key="${norm#*	}"

  local now_ep max_ttl
  now_ep=$(date -u +%s)
  max_ttl="${POOL_COOLDOWN_MAX_TTL:-21600}"

  if command -v jq >/dev/null 2>&1; then
    local res
    res=$(jq -r --arg k1 "$primary_key" --arg k2 "$parent_key" --argjson now "$now_ep" --argjson max_ttl "$max_ttl" '
      def eff(e):
        if (e | type) != "object" or ((e.until_epoch // 0) | type) != "number" then 0
        else
          (if ((e.set_at_epoch // 0) | type) == "number" and (e.set_at_epoch // 0) > 0 then e.set_at_epoch else $now end) as $sat |
          if $sat > ($now + 60) then 0
          else ([e.until_epoch, ($sat + $max_ttl)] | min)
          end
        end;
      .pools // {} |
      [
        (if $k1 != "" and (eff(.[$k1]) > $now) then {until_epoch: eff(.[$k1]), until_iso: (.[$k1].until_iso // "")} else empty end),
        (if $k2 != "" and (eff(.[$k2]) > $now) then {until_epoch: eff(.[$k2]), until_iso: (.[$k2].until_iso // "")} else empty end)
      ] | sort_by(.until_epoch) | last // empty |
      "\(.until_epoch)\t\(.until_iso // "")"
    ' "$cd_file" 2>/dev/null || true)

    if [ -n "$res" ]; then
      local u_ep u_iso rem hum h m
      u_ep="${res%%	*}"
      u_iso="${res#*	}"
      if [[ "$u_ep" =~ ^[0-9]+$ ]] && [ "$u_ep" -gt "$now_ep" ]; then
        rem=$((u_ep - now_ep))
        h=$((rem / 3600))
        m=$(((rem % 3600) / 60))
        if [ "$h" -gt 0 ]; then
          hum="${h}h ${m}m"
        elif [ "$m" -gt 0 ]; then
          hum="${m}m"
        else
          hum="${rem}s"
        fi
        printf '%s remaining (until %s)\n' "$hum" "${u_iso:-unknown}"
        return 0
      fi
    fi
    return 1
  fi
  return 1
}

pool_cooldown_clear() {  # $1 = pool_key
  local raw_key="${1:-}"
  [ -n "$raw_key" ] || return 0
  local cd_file
  cd_file=$(_pool_cooldown_state_file)
  if [ -L "$cd_file" ]; then
    echo "⚠️  Refusing symlink pool cooldown file: ${cd_file}" >&2
    return 1
  fi
  [ -f "$cd_file" ] || return 0
  local lock_file="${cd_file}.lock"
  if [ -L "$lock_file" ]; then
    echo "⚠️  Refusing symlink lock file: ${lock_file}" >&2
    return 1
  fi
  local norm primary_key
  norm=$(_pool_cooldown_normalize "$raw_key")
  primary_key="${norm%%	*}"
  command -v node >/dev/null 2>&1 || return 0
  (
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$lock_file"
      chmod 600 "$lock_file" 2>/dev/null || true
      flock -w 2 9 || true
    fi
    node -e '
      const fs = require("fs");
      const crypto = require("crypto");
      const file = process.argv[1], key = process.argv[2], nowEp = Number(process.argv[3]);
      try {
        if (fs.lstatSync(file).isSymbolicLink()) process.exit(1);
        const raw = JSON.parse(fs.readFileSync(file, "utf8"));
        const pruned = {};
        for (const [k, v] of Object.entries((raw && raw.pools) || {})) {
          if (k !== key && v && typeof v.until_epoch === "number" && v.until_epoch > nowEp) pruned[k] = v;
        }
        const tmp = `${file}.tmp.${process.pid}.${crypto.randomBytes(6).toString("hex")}`;
        fs.writeFileSync(tmp, JSON.stringify({ version: 1, pools: pruned }, null, 2) + "\n", { mode: 0o600, flag: "wx" });
        fs.chmodSync(tmp, 0o600);
        fs.renameSync(tmp, file);
      } catch (e) {
        if (e.code !== "ENOENT") process.exit(1);
      }
    ' "$cd_file" "$primary_key" "$(date -u +%s)"
  )
}

routing_get_review_cascade() {  # $1 = R1|R2|R3 -> always outputs normalized space-separated automated pools (pool_b & pool_c; pool_d is manual-only)
  local tier_raw="${1:-R3}" t=""
  case "$tier_raw" in
    R1|r1) t="r1" ;;
    R2|r2) t="r2" ;;
    *)     t="r3" ;;
  esac
  local def_list="pool_b pool_c"
  [ "$t" = "r3" ] && def_list="pool_c pool_b"

  local arr=""
  if command -v jq >/dev/null 2>&1; then
    local head_json=""
    if [ -n "${CODEX_REPO_ROOT:-}" ] && [ -z "${MODEL_ROUTING_FILE:-}" ]; then
      head_json=$(git -C "$CODEX_REPO_ROOT" show HEAD:.agents/config/model-routing.json 2>/dev/null || true)
    fi
    if [ -n "$head_json" ]; then
      # Strictly honor committed HEAD only when inside repo (prevents agent-writable home config tampering)
      # Allowlist strictly automated pools (pool_b, pool_c) — pool_d (DeepSeek) is manual-only.
      arr=$(printf '%s' "$head_json" | jq -r --arg t "$t" '(.review_cascades[$t].cascade // []) | map(select(. == "pool_b" or . == "pool_c")) | join(" ")' 2>/dev/null || true)
    else
      local cfg="${MODEL_ROUTING_FILE:-${HOME}/.gemini/config/model-routing.json}"
      [ ! -f "$cfg" ] && [ -n "${CODEX_REPO_ROOT:-}" ] && [ -f "${CODEX_REPO_ROOT}/.agents/config/model-routing.json" ] && cfg="${CODEX_REPO_ROOT}/.agents/config/model-routing.json"
      if [ -f "$cfg" ]; then
        arr=$(jq -r --arg t "$t" '(.review_cascades[$t].cascade // []) | map(select(. == "pool_b" or . == "pool_c")) | join(" ")' "$cfg" 2>/dev/null || true)
      fi
    fi
  fi

  # Normalize: deduplicate and ensure BOTH automated external pools (pool_b, pool_c) are always present
  local out="" p
  for p in $arr $def_list; do
    case "$p" in
      pool_b|pool_c)
        case " $out " in
          *" $p "*) ;;
          *) out="${out:+${out} }${p}" ;;
        esac
        ;;
    esac
  done
  echo "$out"
}

codex_attach_file() {  # $1 = filepath, [$2 = max_bytes]
  local f="$1" max_b="${2:-${CODEX_MAX_ATTACH_BYTES:-100000}}"
  [ -f "$f" ] || return 1
  local sz
  sz=$(wc -c < "$f")
  if [ "$sz" -le "$max_b" ]; then
    cat "$f"
  else
    local head_b=$((max_b * 30 / 100))
    local tail_b=$((max_b - head_b))
    head -c "$head_b" "$f"
    printf '\n\n[... truncated %d bytes (showing first %d + last %d bytes of %d total) ...]\n\n' \
      "$((sz - max_b))" "$head_b" "$tail_b" "$sz"
    tail -c "$tail_b" "$f"
  fi
}

codex_pool_in_cooldown() {  # $1 = provider_model (e.g. "codex:gpt-6-astra"), $2 = cooldown_secs (fallback)
  local pm="$1"
  if pool_cooldown_is_active "$pm" >/dev/null 2>&1; then
    return 0
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
    if printf '%s\n' "$msgs" | grep -qiE 'usage limit|usage_limit|5-hour|weekly limit|try again (at|in)|limit reached'; then
      pool_cooldown_set "pool_b:${model}" "Codex RATE_LIMITED: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
      pool_cooldown_set "pool_b" "Codex account usage limit: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
    else
      pool_cooldown_set "pool_b:${model}" "Codex transient rate limit" 300 >/dev/null 2>&1 || true
    fi
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_b:${model}" "Codex UNAVAILABLE" 300 >/dev/null 2>&1 || true
    if printf '%s\n' "$msgs" | grep -qiE '401|unauthori[sz]ed|not logged in|login required|please (log|sign) ?in|token (expired|invalid)'; then
      pool_cooldown_set "pool_b" "Codex auth UNAVAILABLE" 300 >/dev/null 2>&1 || true
    fi
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  if [ "$CODEX_RUN_STATUS" = "OK" ]; then
    pool_cooldown_clear "pool_b:${model}" >/dev/null 2>&1 || true
    pool_cooldown_clear "pool_b" >/dev/null 2>&1 || true
  fi

  codex_log_usage "$kind" "codex:${model}" "$effort" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  codex_prune_logs
  return 0
}

codex_build_resume_args() {  # thread_id model effort schema out -> prints args one per line cleanly (for tests & verification)
  local thread_id="$1" model="$2" effort="$3" schema="$4" out="$5"
  local a
  local -a args=(
    -s read-only
    -C "$CODEX_REPO_ROOT"
    exec resume "$thread_id"
    -m "$model"
    -c 'sandbox_mode="read-only"'
    -c "model_reasoning_effort=\"${effort}\""
    -c 'features.multi_agent=false'
    -c 'approval_policy="never"'
    --skip-git-repo-check
    --json
    -o "$out"
  )
  [ -n "$schema" ] && args+=(--output-schema "$schema")
  for a in "${args[@]}"; do
    printf '%s\n' "$a"
  done
}

codex_run_resume() {  # kind thread_id model effort schema out prompt_file
  local kind="$1" thread_id="$2" model="$3" effort="$4" schema="$5" out="$6" prompt_file="$7"
  local ts bin rc=0 before after msgs
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$CODEX_REPORT_DIR"
  CODEX_RUN_EVENTS="${CODEX_REPORT_DIR}/${kind}-codex-resume-${ts}.events.jsonl"
  CODEX_RUN_STDERR="${CODEX_REPORT_DIR}/${kind}-codex-resume-${ts}.stderr.log"
  CODEX_RUN_ERROR=""
  CODEX_LAST_THREAD_ID=""
  : > "$CODEX_RUN_EVENTS"; : > "$CODEX_RUN_STDERR"

  if ! [[ "$thread_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{7,127}$ ]]; then
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="Invalid thread_id format"
    return 0
  fi
  CODEX_LAST_THREAD_ID="$thread_id"

  if ! bin=$(codex_resolve_bin); then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR="Codex binary not found"
    return 0
  fi

  local -a args=()
  mapfile -t args < <(codex_build_resume_args "$thread_id" "$model" "$effort" "$schema" "$out")

  rm -f "$out"
  before=$(codex_worktree_fingerprint)
  timeout "$CODEX_TIMEOUT_SECS" "$bin" "${args[@]}" - < "$prompt_file" \
    > "$CODEX_RUN_EVENTS" 2> "$CODEX_RUN_STDERR" || rc=$?
  after=$(codex_worktree_fingerprint)

  msgs=$(codex_error_messages "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR")

  if [ "$before" != "$after" ]; then
    CODEX_RUN_STATUS="INTEGRITY_VIOLATION"
    CODEX_RUN_ERROR="Worktree changed during Codex resume run"
  elif [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    CODEX_RUN_STATUS="OK"
    pool_cooldown_clear "pool_b:${model}" >/dev/null 2>&1 || true
    pool_cooldown_clear "pool_b" >/dev/null 2>&1 || true
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Codex resume exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    if printf '%s\n' "$msgs" | grep -qiE 'usage limit|usage_limit|5-hour|weekly limit|try again (at|in)|limit reached'; then
      pool_cooldown_set "pool_b:${model}" "Codex resume RATE_LIMITED: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
      pool_cooldown_set "pool_b" "Codex account usage limit: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
    else
      pool_cooldown_set "pool_b:${model}" "Codex resume transient rate limit" 300 >/dev/null 2>&1 || true
    fi
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_b:${model}" "Codex UNAVAILABLE" 300 >/dev/null 2>&1 || true
    if printf '%s\n' "$msgs" | grep -qiE '401|unauthori[sz]ed|not logged in|login required|please (log|sign) ?in|token (expired|invalid)'; then
      pool_cooldown_set "pool_b" "Codex auth UNAVAILABLE" 300 >/dev/null 2>&1 || true
    fi
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

  local max_turns="${CLAUDE_RUN_MAX_TURNS:-}"
  if [ -z "$max_turns" ]; then
    case "$kind" in
      review*)       max_turns="${CLAUDE_MAX_TURNS_REVIEW:-12}" ;;
      rca*|frontier-*) max_turns="${CLAUDE_MAX_TURNS_RCA:-16}" ;;
      *)             max_turns="${CLAUDE_MAX_TURNS_DEFAULT:-25}" ;;
    esac
  fi

  local args=(-p --model "$model" --effort "$effort" --permission-mode plan
              --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)"
              --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit"
              --max-turns "$max_turns")
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
  local claude_subtype=""
  if [ -s "$CODEX_RUN_EVENTS" ]; then
    claude_subtype=$(jq -r 'if type=="object" then (.subtype // "") else "" end' "$CODEX_RUN_EVENTS" 2>/dev/null || echo "")
  fi
  if [ "$rc" -eq 0 ] && [ -s "$CODEX_RUN_EVENTS" ]; then
    local is_err
    is_err=$(jq -r 'if type=="object" then (.is_error // false) else false end' "$CODEX_RUN_EVENTS" 2>/dev/null || echo "false")
    if [ "$is_err" = "true" ] || [ "$claude_subtype" = "error_max_turns" ]; then
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
    pool_cooldown_clear "pool_c:${model}" >/dev/null 2>&1 || true
    pool_cooldown_clear "pool_c" >/dev/null 2>&1 || true
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="Claude CLI exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_c:${model}" "Claude RATE_LIMITED: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
    case "$model" in
      *opus*) ;;
      *) pool_cooldown_set "pool_c" "Claude RATE_LIMITED: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true ;;
    esac
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_c" "Claude UNAVAILABLE" 300 >/dev/null 2>&1 || true
  elif [ "$claude_subtype" = "error_max_turns" ] || printf '%s\n' "$msgs" | grep -qiE 'error_max_turns|reached max turns|exceeded.*max.*turns'; then
    CODEX_RUN_STATUS="MAX_TURNS"
    CODEX_RUN_ERROR="Claude CLI hit max turns (${max_turns}): $(printf '%s' "$msgs" | head -2 | tr '\n"\\' '   ')"
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
    pool_cooldown_clear "pool_d:${model}" >/dev/null 2>&1 || true
  elif [ "$rc" -eq 124 ]; then
    CODEX_RUN_STATUS="TIMEOUT"
    CODEX_RUN_ERROR="OpenCode exceeded ${CODEX_TIMEOUT_SECS}s"
  elif printf '%s\n' "$msgs" | codex_is_rate_limited; then
    CODEX_RUN_STATUS="RATE_LIMITED"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_d:${model}" "OpenCode RATE_LIMITED: ${CODEX_RUN_ERROR}" "$CODEX_RUN_EVENTS" "$CODEX_RUN_STDERR" >/dev/null 2>&1 || true
  elif printf '%s\n' "$msgs" | codex_is_unavailable; then
    CODEX_RUN_STATUS="UNAVAILABLE"
    CODEX_RUN_ERROR=$(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')
    pool_cooldown_set "pool_d:${model}" "OpenCode UNAVAILABLE" 300 >/dev/null 2>&1 || true
  else
    CODEX_RUN_STATUS="ERROR"
    CODEX_RUN_ERROR="exit=${rc}: $(printf '%s' "$msgs" | head -3 | tr '\n"\\' '   ')"
  fi

  codex_log_usage "$kind" "opencode:${model}" "default" "$CODEX_RUN_STATUS" "$CODEX_RUN_EVENTS"
  return 0
}

# Cross-Model Council Integration (Read-Only Analysts + Tiered Review Gate)

Two automated external frontier CLIs — **Pool B (`OpenAI Codex CLI`)** and **Pool C (`Anthropic Claude Code CLI`)** — are wired alongside Antigravity (**Pool A** + **Pool A+** bundle) and **Pool 0** deterministic Linux Offload Bots.
**Pool D (`OpenCode + DeepSeek API`) is STRICTLY MANUAL-ONLY (`/opencode`)** and is excluded from every automatic cascade, review gate, RCA auto-mode, and `<10%` reserve pass-through.

**Antigravity (Pool A) is the SINGLE WRITER**; all external CLIs execute in strict **READ-ONLY** sandboxes with cryptographic before/after worktree fingerprinting (`INTEGRITY_VIOLATION` on any mutation).

| Role / Stage | Primary Pool | Automatic Failover Cascade | Script |
|--------------|-------------|----------------------------|--------|
| **External-First Task & Patch Orchestrator (`T1`–`T4`)** | `--tier ui`: **Pool C** (`Claude Sonnet 5.5 med`)<br>`--tier backend`: **Pool B** (`Codex gpt-6.1-sol high`)<br>`--tier deep`: **Pool B** (`Codex gpt-6-astra xhigh`)<br>`--tier flash`: **Pool C** (`Claude Sonnet 5.5 low`) | `--tier ui`: Pool B (`gpt-6.1-terra med / sol`) → Exit `2` (Pool A `Hydrogen Med` / `Neon Med`)<br>`--tier backend`: Pool C (`Sonnet 5.5 high`) → Exit `2` (Pool A `Neon High` / `Hydrogen High`)<br>`--tier deep`: Pool C (`Sonnet 5.5 high`, `--opus` opt-in) → Exit `2` (Pool A `Carbon High` / `Neon xhigh` / `Hydrogen xhigh`)<br>`--tier flash`: Pool B (`gpt-6-luna / reserve low`) → Exit `2` (Pool A `Hydrogen Low`) | `bash .agents/scripts/frontier-orchestrate.sh --tier <ui\|backend\|deep\|flash> [--opus]` |
| **Deep Root-Cause Analysis (RCA)** | **Pool B**: Codex (`gpt-6-astra`, `xhigh`, fallback `gpt-6.1-sol`) | **Pool C**: Claude (`claude-sonnet-5-5 high` bounded `16` turns, `--opus` opt-in) → Exit `2` (**Pool A** `Gemini 4 Carbon High` / `Neon XHigh`) | `bash .agents/scripts/codex-rca.sh "<symptom>" [-a <log>]...` |
| **Tiered Pre-Commit Code + OWASP Gate** (`R1` / `R2` / `R3`) | `R1`/`R2`: **Pool B** Codex (`gpt-6.1-terra med` / `gpt-6.1-sol high`)<br>`R3`: **Pool C** Claude (`claude-opus-5-5 high`, bounded `16` turns)<br>+ **Round-2+ Delta Resume** (`codex -s read-only -C ... exec resume`) when Round 1 was Codex | `R1`/`R2`: Pool C (`claude-sonnet-5-5 med/high`) → Exit `2`<br>`R3`: Pool B (`gpt-6-astra high`) → Exit `2` (**Pool A** `--fallback`) | `bash .agents/scripts/run-codex-review-gate.sh` |
| **Post-Commit Security & Dependabot Sync** | Deterministic OWASP binding from `codex-review.json` + `gh api` Dependabot check (`R1`/`R2`) | Exit `2` on `R3` security-sensitive paths → dedicated `Gemini 4 Carbon High` / `Claude Opus 5.5 High` Security Reviewer | `bash .agents/scripts/sync-security-from-review.sh` |
| **Manual-Only DeepSeek Audit (Opt-In ONLY)** | **Pool D**: OpenCode (`deepseek/deepseek-v4-pro` / `deepseek-flash`) — **NEVER auto-invoked** | Manual user trigger only (`/opencode`, `opencode-orchestrate.sh`, `stage0-precheck.sh --manual`, or `codex-rca.sh --cli opencode`) | `bash .agents/scripts/opencode-orchestrate.sh` / `stage0-precheck.sh --manual` |

## Automatic Diff Risk Tiering (`codex_classify_diff_tier`)

- **`R1` (Light UI / Tests / Config `< 60` changed lines, no Java/Lua/SQL/Shell)**: Compact UI/OWASP context (`~4 KB`), routing `Pool B (gpt-6.1-terra med)` → `Pool C (claude-sonnet-5-5 med)` (Pool A fallback: `gemini-4-hydrogen-medium`).
- **`R2` (Standard Backend / Fullstack CRUD `< 350` lines)**: Routes `Pool B (gpt-6.1-sol high)` → `Pool C (claude-sonnet-5-5 high)` (Pool A fallback: `gemini-4-neon-high`).
- **`R3` (Critical Paths or `>= 350` lines)**: Triggered automatically on `.lua`, Flyway `V*__*.sql`, `SmscConnectionManager`, `Smpp*`, `RateLimit*`, `RfSegment*`, `RfCapacity*`, `FallbackScheduler`, `SmsInboundConsumer`, `SmsOutbound*`, `Ejoin*`, `SecurityConfig`, `Jwt*`, `Auth*`, `EncryptionService`, `apisix`, `deploy-k8s`, `docker-compose`, `.agents/scripts/`, or `.agents/hooks.json`. Routes **`Pool C (claude-opus-5-5 high` → `claude-sonnet-5-5 high)` primary** → **`Pool B (gpt-6-astra high)`** (Pool A fallback: `gemini-4-carbon-high`).

## Dynamic Model Routing (`model-routing.json` `2026.11.7`) & Shared Persistent Cooldown Cache
All orchestration and review scripts dynamically read models, cascade orders (`review_cascades.<tier>.cascade`, strictly allowlisting `pool_b` and `pool_c`), bounded Claude `--max-turns`, and cooldown limits from committed `HEAD:.agents/config/model-routing.json` (for review gates) or `${MODEL_ROUTING_FILE:-$HOME/.gemini/config/model-routing.json}`. Rate-limit cooldowns (`try again at ...`, `Retry-After`, `usage limit`) are stored atomically (`0600`, symlink-protected) in `${AGY_POOL_COOLDOWN_FILE:-$HOME/.gemini/cache/pool-cooldowns.json}` (`60s–21600s` clamp, `1800s` default) and surfaced in `preflight.sh` as `⏳`; set `AGY_IGNORE_COOLDOWN=1` to bypass manually.

## Mandatory Rules

1. **External CLIs never write.**
   - Codex runs with `-s read-only -C <dir>` (including top-level `-s read-only -C <dir> exec resume <id> -c 'sandbox_mode="read-only"'`) and `-c features.multi_agent=false`.
   - Claude Code runs with `-p --permission-mode plan --disallowedTools Write Edit MultiEdit NotebookEdit` and bounded `--max-turns` (`10–16` review, `16` RCA/deep).
   - Manual OpenCode runs strictly with `opencode run --agent readonly-auditor` (`edit: deny`, `write: deny`).
   - Mutating flags on `codex`, `claude`, or `opencode` are blocked by `protect-enforcement.sh`.
2. **Exclude non-code churn from review & QA hashes.** `.last-staging-deploy`, `*.md`, `platform-docs/**`, `.agent-state`, and `.agent-reports` are excluded from `codex_staged_fingerprint` and `codex_code_worktree_hash`.
3. **Zero Automatic DeepSeek Execution.** Never invoke `stage0-precheck.sh`, `opencode-orchestrate.sh`, or `--cli opencode` automatically. `stage0-precheck.sh` is a no-op without explicit `--manual` (or `AGY_ALLOW_MANUAL_DEEPSEEK=1`).
4. **Stateful Round-2+ Delta Convergence.** If Round 1 returns `FAIL` on Codex (`R1`/`R2` or `R3` failover), re-running automatically invokes `codex -s read-only -C <dir> exec resume <thread_id>` with only the interdiff and previous `CRITICAL`/`HIGH` findings. When Round 1 ran on Claude (`R3`), Round 2 embeds previous blocking findings & interdiff in the bounded review prompt.
5. **Commit Gate Order.**
   `git add <explicit paths>` → `bash .agents/scripts/run-codex-review-gate.sh` → `git add -u .agent-state/...` → `git commit` → `bash .agents/scripts/sync-security-from-review.sh`.
6. **Last-Resort Internal Fallback (`exit 2`).** Unlocked **ONLY** when both automated external pools (`Codex` + `Claude`) return `RATE_LIMITED` or `UNAVAILABLE`:
   - Spawn an internal subagent on **Gemini 4 Carbon** (`High` thinking level), explicitly announcing model and thinking level in Greek.
   - Review `git diff --cached` against `.agents/scripts/codex-review-schema.json` (including `owasp_checklist` >= 5 items, `reviewer_agent_id`, `staged_fingerprint`, `model: "Gemini 4 Carbon High"`), save to `.agent-reports/codex/fallback-review.json`, and run `bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json`.
   - `TIMEOUT` / `ERROR` / `INTEGRITY_VIOLATION` do **not** unlock `--fallback`.
7. **Credentials Setup (One-Time on DevBox).**
   - Pool B (Codex): `codex login` (ChatGPT subscription).
   - Pool C (Claude): `~/.local/bin/claude login` (Claude Pro/Max subscription).
   - Pool D (Manual-Only DeepSeek, optional): `set-deepseek-key` (`~/.config/llm-council/secrets.env`, `0600`).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Limit — Zero-Gemini Pass-Through Mode)
- Όταν το metered 5h/7d υπόλοιπο Gemini πέσει κάτω από `10%` (`~/.gemini/config/gemini-quota.json`, `source:"auto-meter"` ή χειροκίνητο `--set-reserve`), **ΑΠΑΓΟΡΕΥΕΤΑΙ** οποιοδήποτε `invoke_subagent` ή Gemini `swarm` worker (`Carbon`/`Neon`/`Hydrogen`/`Argon`/`3.8 Flash`).
- Ο Parent Agent δρομολογεί 100% μέσω `frontier-orchestrate.sh` αποκλειστικά σε **Pools B/C** (μηδέν αυτόματο DeepSeek):
  - **`T1`**: `--tier flash` → **Pool C (`Claude Sonnet 5.5 low`)** → **Pool B (`Codex gpt-6-luna / reserve low`)**.
  - **`T2`**: `--tier ui` → **Pool C (`Claude Sonnet 5.5 med`)** → **Pool B (`Codex gpt-6.1-terra med / sol`)**.
  - **`T3`**: `--tier backend` → **Pool B (`Codex gpt-6.1-sol high / astra`)** → **Pool C (`Claude Sonnet 5.5 high`)**.
  - **`T4`**: `--tier deep` → **Pool B (`Codex gpt-6-astra xhigh / sol`)** → **Pool C (`Claude Opus 5.5 high / Sonnet 5.5 high`)**.
- Επαναφορά: αυτόματα στο `>= 25%` (`auto-meter`) ή χειροκίνητα με `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

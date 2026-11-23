# 4-Pool Cross-Model Council Integration (Read-Only Analysts + Tiered Review Gate)

Three external frontier CLIs are wired alongside Antigravity across **4 orthogonal quota pools** + Pool A+ credits bundle.
**Antigravity (Pool A) is the SINGLE WRITER**; all external CLIs execute in strict **READ-ONLY** sandboxes with cryptographic before/after worktree fingerprinting (`INTEGRITY_VIOLATION` on any mutation).

| Role / Stage | Primary Pool | Automatic Failover Cascade | Script |
|--------------|-------------|----------------------------|--------|
| **External-First Task & Patch Orchestrator (`T1`–`T4`)** | `--tier ui`: **Pool C** (`Claude Sonnet 5.5 med`)<br>`--tier backend`: **Pool B** (`Codex gpt-6.1-sol high`)<br>`--tier deep`: **Pool B** (`Codex gpt-6-astra xhigh`)<br>`--tier flash`: **Pool D** (`DeepSeek-Flash`) | `--tier ui`: Pool B (`gpt-6.1-terra med / sol`) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Hydrogen Med` / `Neon Med`)<br>`--tier backend`: Pool C (`Sonnet 5.5 high`) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Neon High` / `Hydrogen High`)<br>`--tier deep`: Pool C (`Sonnet 5.5 high`, `--opus` opt-in) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Carbon High` / `Neon xhigh` / `Hydrogen xhigh`) | `bash .agents/scripts/frontier-orchestrate.sh --tier <ui\|backend\|deep\|flash> [--opus]` |
| **Stage-0 Cheap Pre-Check** (before Staging/Gate) | **Pool D**: OpenCode (`deepseek/deepseek-v4-pro` or `deepseek-v4.1-flash-free`) | Advisory skip if offline | `bash .agents/scripts/stage0-precheck.sh` |
| **Deep Root-Cause Analysis (RCA)** | **Pool B**: Codex (`gpt-6-astra`, `xhigh`, fallback `gpt-6.1-sol`) | **Pool C**: Claude (`claude-sonnet-5-5 high` bounded `16` turns, `--opus` opt-in) → **Pool D**: OpenCode (`deepseek-v4-pro`) → Exit `2` (**Pool A** `Gemini 4 Carbon High` / `Neon XHigh`) | `bash .agents/scripts/codex-rca.sh "<symptom>" [-a <log>]...` |
| **Tiered Pre-Commit Code + OWASP Gate** (`R1` / `R2` / `R3`) | `R1`/`R2`: **Pool B** Codex (`gpt-6.1-terra med` / `gpt-6.1-sol high`)<br>`R3`: **Pool C** Claude (`claude-opus-5-5 high`, bounded `16` turns)<br>+ **Round-2+ Delta Resume** (`codex -s read-only -C ... exec resume`) when Round 1 was Codex | `R1`/`R2`: Pool C (`claude-sonnet-5-5 med/high`) → Pool D (`deepseek-v4-pro`) → Exit `2`<br>`R3`: Pool B (`gpt-6-astra high`) → Pool D (`deepseek-v4-pro`) → Exit `2` (**Pool A** `--fallback`) | `bash .agents/scripts/run-codex-review-gate.sh` |
| **Post-Commit Security & Dependabot Sync** | Deterministic OWASP binding from `codex-review.json` + `gh api` Dependabot check (`R1`/`R2`) | Exit `2` on `R3` security-sensitive paths → dedicated `Gemini 4 Carbon High` / `Claude Opus 5.5 High` Security Reviewer | `bash .agents/scripts/sync-security-from-review.sh` |

## Automatic Diff Risk Tiering (`codex_classify_diff_tier`)

- **`R1` (Light UI / Tests / Config `< 60` changed lines, no Java/Lua/SQL/Shell)**: Uses compact UI/OWASP context (`~4 KB` instead of `~35 KB`), routing `Pool B (gpt-6.1-terra med)` → `Pool C (claude-sonnet-5-5 med)` → `Pool D (deepseek-v4-pro)`.
- **`R2` (Standard Backend / Fullstack CRUD `< 350` lines)**: Routes `Pool B (gpt-6.1-sol high)` → `Pool C (claude-sonnet-5-5 high)` → `Pool D (deepseek-v4-pro)` (Pool A fallback: `gemini-4-neon-high`).
- **`R3` (Critical Paths or `>= 350` lines)**: Triggered automatically on `.lua`, Flyway `V*__*.sql`, `SmscConnectionManager`, `Smpp*`, `RateLimit*`, `RfSegment*`, `RfCapacity*`, `FallbackScheduler`, `SmsInboundConsumer`, `SmsOutbound*`, `Ejoin*`, `SecurityConfig`, `Jwt*`, `Auth*`, `EncryptionService`, `apisix`, `deploy-k8s`, `docker-compose`, `.agents/scripts/`, or `.agents/hooks.json`. Routes **`Pool C (claude-opus-5-5 high` → `claude-sonnet-5-5 high)` primary** → **`Pool B (gpt-6-astra high)`** → **`Pool D (deepseek-v4-pro)`** (Pool A fallback: `gemini-4-carbon-high`).

## Dynamic Model Routing (`model-routing.json`) & Shared Persistent Cooldown Cache
All orchestration and review scripts dynamically read models, cascade orders (`review_cascades.<tier>.cascade`), bounded Claude `--max-turns`, and cooldown limits from committed `HEAD:.agents/config/model-routing.json` (for review gates) or `${MODEL_ROUTING_FILE:-$HOME/.gemini/config/model-routing.json}`. Rate-limit cooldowns (`try again at ...`, `Retry-After`, `usage limit`) are stored atomically (`0600`, symlink-protected) in `${AGY_POOL_COOLDOWN_FILE:-$HOME/.gemini/cache/pool-cooldowns.json}` (`60s–21600s` clamp, `1800s` default) and surfaced in `preflight.sh` as `⏳`; set `AGY_IGNORE_COOLDOWN=1` to bypass manually. The multi-machine matrix is pushed in real time via `agy-sync-daemon` (outbound SSE Push from `agy-fleet-hub` + `agy-fleet` MCP) and backed by a `1x Daily` (`86400s`) `systemd --user` / Scheduled Task and preflight safety fallback.

## Mandatory Rules

1. **External CLIs never write.**
   - Codex runs with `-s read-only -C <dir>` (including top-level `-s read-only -C <dir> exec resume <id> -c 'sandbox_mode="read-only"'`) and `-c features.multi_agent=false` (kernel Landlock/bubblewrap sandbox; subagent fan-out disabled by default to prevent 3x–5x quota burn).
   - Claude Code runs with `-p --permission-mode plan --disallowedTools Write Edit MultiEdit NotebookEdit` and bounded `--max-turns` (`10–16` review, `16` RCA/deep).
   - OpenCode runs with `opencode run --agent readonly-auditor` (`edit: deny`, `write: deny` in `~/.config/opencode/opencode.json`).
   - Mutating flags on `codex`, `claude`, or `opencode` are blocked by `protect-enforcement.sh`.
2. **Exclude non-code churn from review & QA hashes.** `.last-staging-deploy`, `*.md`, `platform-docs/**`, `.agent-state`, and `.agent-reports` are automatically excluded from `codex_staged_fingerprint` and `codex_code_worktree_hash` so docs/vault/deploy-marker updates never invalidate reviews or QA gates.
3. **Stage-0 before Commit Gate on non-trivial diffs.** Run `bash .agents/scripts/stage0-precheck.sh` before staging/committing multi-file changes to catch obvious bugs for ~$0.01 instead of burning multiple Codex/Claude rounds.
4. **Stateful Round-2+ Delta Convergence.** If Round 1 of `run-codex-review-gate.sh` returns `FAIL` on Codex (`R1`/`R2` or `R3` failover), re-running automatically invokes `codex -s read-only -C <dir> exec resume <thread_id>` with only the interdiff (`diff -u last-reviewed.patch current-staged.patch`) and previous `CRITICAL`/`HIGH` findings — preventing moving-goalpost nitpicks and saving ~75% tokens! When Round 1 ran on Claude (`R3`), Round 2 embeds the Round-2+ findings & interdiff inside the bounded review prompt.
5. **Commit Gate Order.**
   `git add <explicit paths>` → `bash .agents/scripts/run-codex-review-gate.sh` → `git add .agent-state/codex-review.json` (plus other gate files) → `git commit` → `bash .agents/scripts/sync-security-from-review.sh`.
6. **Last-Resort Internal Fallback (`exit 2`).** Unlocked **ONLY** when all 3 external pools (`Codex`, `Claude`, `DeepSeek`) return `RATE_LIMITED` or `UNAVAILABLE`:
   - Spawn an internal subagent on **Gemini 4 Carbon** (`High` thinking level), explicitly announcing the model and thinking level in Greek to the user.
   - Have it review `git diff --cached` against `.agents/scripts/codex-review-schema.json` (including `owasp_checklist` >= 5 items, `reviewer_agent_id`, `staged_fingerprint`, `model: "Gemini 4 Carbon High"`), save to `.agent-reports/codex/fallback-review.json`, and run `bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json`.
   - `TIMEOUT` / `ERROR` / `INTEGRITY_VIOLATION` do **not** unlock `--fallback`.
7. **Credentials Setup (One-Time on DevBox).**
   - Pool B (Codex): `codex login` (ChatGPT subscription).
   - Pool C (Claude): `~/.local/bin/claude login` (Claude Pro subscription).
   - Pool D (DeepSeek): `set-deepseek-key` (stores `DEEPSEEK_API_KEY` in `~/.config/llm-council/secrets.env` with `0600` permissions; never echo or commit the key).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (`Gemini 4 Carbon`, `Gemini 4 Neon`, `Gemini 4 Hydrogen`, `Gemini 4 Argon` ΚΑΙ `Gemini 3.8 Flash`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` ή Gemini `swarm` workers (συμπεριλαμβανομένων `Gemini 4 Neon`, `Gemini 4 Hydrogen` & `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 4 Hydrogen Low` & `3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` -> **Pool D (`deepseek/deepseek-flash` / `deepseek-v4-pro`)** -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Hydrogen Medium`, `Neon Medium` & `Carbon Medium` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Hydrogen High`, `Neon High` & `Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` / `Neon XHigh` / `Argon High` / `Hydrogen XHigh`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / sonnet`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

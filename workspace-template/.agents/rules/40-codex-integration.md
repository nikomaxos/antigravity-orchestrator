# 4-Pool Cross-Model Council Integration (Read-Only Analysts + Tiered Review Gate)

Three external frontier CLIs are wired alongside Antigravity across **4 orthogonal quota pools**.
**Antigravity (Pool A) is the SINGLE WRITER**; all external CLIs execute in strict **READ-ONLY** sandboxes with cryptographic before/after worktree fingerprinting (`INTEGRITY_VIOLATION` on any mutation).

| Role / Stage | Primary Pool | Automatic Failover Cascade | Script |
|--------------|-------------|----------------------------|--------|
| **External-First Task & Patch Orchestrator (`T1`–`T4`)** | `--tier ui`: **Pool C** (`Claude Sonnet 4.6`)<br>`--tier backend`: **Pool B** (`Codex gpt-6-astra high`)<br>`--tier deep`: **Pool B** (`Codex gpt-6-astra xhigh`)<br>`--tier flash`: **Pool D** (`DeepSeek-Flash`) | `--tier ui`: Pool B (`terra med`) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Carbon Med`)<br>`--tier backend`: Pool C (`Sonnet 4.6`) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Carbon Med`)<br>`--tier deep`: Pool C (`Opus 4.6 high`) → Pool D (`DeepSeek-V4-Pro`) → Exit `2` (Pool A `Carbon High`) | `bash .agents/scripts/frontier-orchestrate.sh --tier <ui\|backend\|deep\|flash>` |
| **Stage-0 Cheap Pre-Check** (before Staging/Gate) | **Pool D**: OpenCode (`deepseek/deepseek-v4-pro` or `deepseek-v4.1-flash-free`) | Advisory skip if offline | `bash .agents/scripts/stage0-precheck.sh` |
| **Deep Root-Cause Analysis (RCA)** | **Pool B**: Codex (`gpt-6-astra`, `xhigh`) | **Pool C**: Claude (`opus` → `sonnet`, `high`) → **Pool D**: OpenCode (`deepseek-v4-pro`) → Exit `2` (**Pool A** `Gemini 4 Carbon High`) | `bash .agents/scripts/codex-rca.sh "<symptom>" [-a <log>]...` |
| **Tiered Pre-Commit Code + OWASP Gate** (`R1` / `R2` / `R3`) | **Pool B**: Codex (`R1`: `gpt-5.6-terra med`; `R2`: `gpt-6-astra med`; `R3`: `gpt-6-astra high`) + **Round-2+ Delta Resume** (`codex exec resume`) | **Pool C**: Claude (`R1`: `sonnet low`; `R2`: `sonnet high`; `R3`: `opus`/`sonnet high`) → **Pool D**: OpenCode (`deepseek-v4-pro`) → Exit `2` (**Pool A** `--fallback`) | `bash .agents/scripts/run-codex-review-gate.sh` |
| **Post-Commit Security & Dependabot Sync** | Deterministic OWASP binding from `codex-review.json` + `gh api` Dependabot check (`R1`/`R2`) | Exit `2` on `R3` security-sensitive paths → dedicated `Gemini 4 Carbon High` / `Claude Opus High` Security Reviewer | `bash .agents/scripts/sync-security-from-review.sh` |

## Automatic Diff Risk Tiering (`codex_classify_diff_tier`)

- **`R1` (Light UI / Tests / Config `< 60` changed lines)**: Uses compact UI/OWASP context, routing to `gpt-5.6-terra (medium)` or `claude sonnet (low)`.
- **`R2` (Standard Backend / Fullstack CRUD `< 350` lines)**: Routes to `gpt-6-astra (medium)` or `claude sonnet (high)`.
- **`R3` (Critical Paths or `>= 350` lines)**: Triggered automatically on concurrency, crypto, auth, schema migrations, or enforcement scripts. Routes to `gpt-6-astra (high)` or `claude opus (high)`.

## Mandatory Rules

1. **External CLIs never write.**
   - Codex runs with `-s read-only -c features.multi_agent=false`.
   - Claude Code runs with `-p --permission-mode plan --disallowedTools Write Edit MultiEdit NotebookEdit`.
   - OpenCode runs with `opencode run --agent readonly-auditor` (`edit: deny`, `write: deny`).
   - Mutating flags on `codex`, `claude`, or `opencode` are blocked by `protect-enforcement.sh`.
2. **Exclude non-code churn from review & QA hashes.** `*.md`, `.agent-state`, and `.agent-reports` are automatically excluded from `codex_staged_fingerprint` and `codex_code_worktree_hash` so docs/vault updates never invalidate reviews or QA gates.
3. **Stage-0 before Commit Gate on non-trivial diffs.** Run `bash .agents/scripts/stage0-precheck.sh` before staging/committing multi-file changes to catch obvious bugs for ~$0.01 instead of burning multiple Codex/Claude rounds.
4. **Stateful Round-2+ Delta Convergence.** If Round 1 of `run-codex-review-gate.sh` returns `FAIL` on Codex, fixing the findings and re-running automatically invokes `codex exec resume <thread_id>` with only the interdiff.
5. **Commit Gate Order.**
   `git add <explicit paths>` → `bash .agents/scripts/run-codex-review-gate.sh` → `git add .agent-state/codex-review.json` (plus other gate files) → `git commit` → `bash .agents/scripts/sync-security-from-review.sh`.
6. **Last-Resort Internal Fallback (`exit 2`).** Unlocked **ONLY** when all 3 external pools (`Codex`, `Claude`, `DeepSeek`) return `RATE_LIMITED` or `UNAVAILABLE`:
   - Spawn an internal subagent on **Gemini 4 Carbon** (`High` thinking level), explicitly announcing the model and thinking level in Greek to the user.
   - Have it review `git diff --cached` against `.agents/scripts/codex-review-schema.json`, save to `.agent-reports/codex/fallback-review.json`, and run `bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json`.
7. **Credentials Setup.**
   - Pool B (Codex): `codex login` (ChatGPT subscription).
   - Pool C (Claude): `claude login` (Claude Pro subscription).
   - Pool D (DeepSeek): `DEEPSEEK_API_KEY` in `~/.config/llm-council/secrets.env` (`0600`).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (συμπεριλαμβανομένου του `Gemini 3.8 Flash`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` (ακόμη και με `Model: "flash"` / `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` $ightarrow$ **Pool D (`deepseek/deepseek-v4-pro` / `deepseek-flash`)** $ightarrow$ **Pool C (`Claude Sonnet 4.6 low`)** $ightarrow$ **Pool B (`Codex gpt-5.6-terra`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Carbon Medium` & `3.8 Flash` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` $ightarrow$ **Pool C (`Claude Sonnet 4.6`)** $ightarrow$ **Pool B (`Codex gpt-5.6-terra medium`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` $ightarrow$ **Pool B (`Codex gpt-6-astra high`)** $ightarrow$ **Pool C (`Claude Sonnet 4.6`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` Deep/Concurrency/Security)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` $ightarrow$ **Pool B (`Codex gpt-6-astra xhigh`)** $ightarrow$ **Pool C (`Claude Opus 4.6 high`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

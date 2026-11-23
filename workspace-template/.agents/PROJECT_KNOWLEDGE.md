# Project Architecture & Knowledge Index

## 1. Overview & Architecture Index
This repository is protected by the Antigravity Multi-Model Orchestrator and Gatekeeper enforcement layer.

### Core Architecture Components
- **Source Code**: Project core implementation files.
- **Enforcement Layer**: `.agents/hooks.json`, `.agents/scripts/`, `.agents/rules/`, and `.agent-state/`.
- **Knowledge Vault**: `.agents/PROJECT_KNOWLEDGE.md` (architecture facts & changelog).
- **Skills Vault**: `.agents/skills/*/SKILL.md` (reusable operational playbooks & procedures).

---

## 2. Pure Zero-Hands-On Orchestrator & 4-Pool Model Routing
1. **Universal Parent Orchestrator (Default: `Orchestrator (Carbon -> Hydrogen)` / `Orchestrator (Neon -> Hydrogen)` / `Gemini 4 Carbon Medium`)**: Planning turns stay ultra-thin (`<35K` tokens, `~1s` latency on `Carbon`/`Neon`), while `exit_plan_mode` hands execution directly to **`Gemini 4 Hydrogen`** (`2.5x` faster, `57%` vs `18.2%` Terminal-Bench 4.1, `>5x` fewer hallucinations, `19%` faster workflows & `~24%` less quota). In `Orchestrator` mode, never spawn `invoke_subagent(Model="flash")` (`3.8 Flash`) for pre-flight checks — pass directly via `exit_plan_mode` into **`Gemini 4 Hydrogen`** **Step 0: Read-Only Pre-Flight Check** with a `Re-plan if:` guard. **`Gemini 3.8 Flash` is permitted EXCLUSIVELY for the `browser` subagent.**
2. **External-First Frontier Offload (`frontier-orchestrate.sh`, `schema_version: 2026.11.6`)**:
   - `T1` Fast Explorer & Live-Ops Pre-Flight (`Gemini 4 Hydrogen Low` via `swarm` `gemini-4-hydrogen-low` / `inherit`, or `Gemini 4 Hydrogen Medium` for critical live production checks; Pool D `DeepSeek-Flash` via `frontier-orchestrate.sh --tier flash` for massive non-critical `100K+` log dumps — NEVER `3.8 Flash`): Codebase exploration, live-ops pre-flight, log slicing, read-only queries.
   - `T2` UI / Frontend / Tests (`Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + `frontier-orchestrate.sh --tier ui`: Claude Sonnet 5.5 -> Codex gpt-6.1-terra med -> DeepSeek-V4-Pro).
   - `T3` Multi-Service / Backend (`Gemini 4 Neon High` `65.2%` Terminal-Bench 4.1 & `-25%` cost vs Carbon / `Gemini 4 Hydrogen High` + `frontier-orchestrate.sh --tier backend`: Codex gpt-6.1-sol high -> Claude Sonnet 5.5 high -> DeepSeek-V4-Pro).
   - `T4` Critical Architecture & Security (`codex-rca.sh` / `frontier-orchestrate.sh --tier deep`: Codex gpt-6-astra xhigh -> bounded Claude Sonnet 5.5 high [`--opus` opt-in] -> DeepSeek-V4-Pro, fallback `Carbon High` / `Neon XHigh` (`0.0%` shortcut rate) / `Hydrogen XHigh` / `Argon High`; `R3` review: Pool C Claude Opus 5.5 high primary -> Pool B Codex gpt-6-astra high -> Pool D).
   - Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`): Executes QA, Regression, Docs, Vault, Skills, and Review gates (with shared `~/.gemini/cache/pool-cooldowns.json` and fixed top-level read-only `codex -s read-only -C ... exec resume`).
3. **Root Gatekeeper (`agy-gatekeeper.service` on `127.0.0.1:18099`)**: Cryptographic HMAC signing and verification of `.agent-state/*.json`.

---

## 3. Operating Rules & Invariants
1. **Single Writer**: Antigravity is the only agent with write access; external CLIs (Codex, Claude Code, OpenCode) execute strictly read-only.
2. **Execution Evidence**: Never declare a task complete or a check passed without concrete execution output.
3. **Autonomous Skills Distillation**: Update or synthesize `.agents/skills/<name>/SKILL.md` whenever new operational procedures or debugging playbooks are discovered.

---

## 📝 Recent Outcomes
<!-- Chronological record of completed architectural changes, features, and fixes -->
- Initialized workspace with Antigravity 4-Pool Multi-Model Orchestrator & agy-gatekeeper enforcement (`schema_version: 2026.11.6`).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (`Gemini 4 Carbon`, `Gemini 4 Neon`, `Gemini 4 Hydrogen`, `Gemini 4 Argon` ΚΑΙ `Gemini 3.8 Flash`, συμπεριλαμβανομένων `Orchestrator (Carbon/Neon/Argon)`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` ή Gemini `swarm` workers (συμπεριλαμβανομένων `Gemini 4 Neon`, `Gemini 4 Hydrogen` & `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 4 Hydrogen Low` & `3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` -> **Pool D (`deepseek/deepseek-v4-pro` / `deepseek-flash`)** -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Hydrogen Medium`, `Neon Low/Medium` & `Carbon Medium` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra medium`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Hydrogen High`, `Neon High` & `Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` -> **Pool B (`Codex gpt-6.1-sol high`)** -> **Pool C (`Claude Sonnet 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` / `Neon XHigh` / `Argon High` / `Hydrogen XHigh`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` -> **Pool B (`Codex gpt-6-astra xhigh`)** -> **Pool C (`Claude Opus 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

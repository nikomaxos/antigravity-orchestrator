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
1. **Universal Parent Orchestrator (Default: `Orchestrator (Carbon -> Hydrogen)` / `Gemini 4 Carbon Medium`)**: Planning turns stay ultra-thin (`<35K` tokens, `~1s` latency on `Carbon`), while `exit_plan_mode` hands execution directly to **`Gemini 4 Hydrogen`** (`2.5x` faster, `57%` vs `18.2%` Terminal-Bench 4.1, `>5x` fewer hallucinations, `19%` faster workflows & `~24%` less quota). Never downgrade `Hydrogen` turns to `Model: "flash"` (`3.8 Flash`).
2. **External-First Frontier Offload (`frontier-orchestrate.sh`, `schema_version: 2026.11.2`)**:
   - `T1` Fast Explorer (`Gemini 4 Hydrogen Low` via `swarm`/`inherit`; keep `Model: "flash"` `3.8 Flash` strictly for `browser` subagent & bulk raw log scans from non-Orchestrator `Carbon` turns): Codebase exploration, log slicing, read-only queries.
   - `T2` UI / Frontend / Tests (`Gemini 4 Hydrogen Medium` + `frontier-orchestrate.sh --tier ui`: Claude Sonnet 5.5 -> Codex gpt-6.1-terra med -> DeepSeek-V4-Pro).
   - `T3` Multi-Service / Backend (`Gemini 4 Hydrogen High` + `frontier-orchestrate.sh --tier backend`: Codex gpt-6.1-sol high -> Claude Sonnet 5.5 high -> DeepSeek-V4-Pro).
   - `T4` Critical Architecture & Security (`codex-rca.sh` / `frontier-orchestrate.sh --tier deep`: Codex gpt-6-astra xhigh -> Claude Opus 5.5 high -> DeepSeek-V4-Pro, fallback `Carbon High` / `Hydrogen XHigh` / `Argon High`).
   - Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`): Executes QA, Regression, Docs, Vault, Skills, and Review gates.
3. **Root Gatekeeper (`agy-gatekeeper.service` on `127.0.0.1:18099`)**: Cryptographic HMAC signing and verification of `.agent-state/*.json`.

---

## 3. Operating Rules & Invariants
1. **Single Writer**: Antigravity is the only agent with write access; external CLIs (Codex, Claude Code, OpenCode) execute strictly read-only.
2. **Execution Evidence**: Never declare a task complete or a check passed without concrete execution output.
3. **Autonomous Skills Distillation**: Update or synthesize `.agents/skills/<name>/SKILL.md` whenever new operational procedures or debugging playbooks are discovered.

---

## 📝 Recent Outcomes
<!-- Chronological record of completed architectural changes, features, and fixes -->
- Initialized workspace with Antigravity 4-Pool Multi-Model Orchestrator & agy-gatekeeper enforcement (`schema_version: 2026.11.2`).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (`Gemini 4 Carbon`, `Gemini 4 Hydrogen`, `Gemini 4 Argon` ΚΑΙ `Gemini 3.8 Flash`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` ή Gemini `swarm` workers (συμπεριλαμβανομένων `Gemini 4 Hydrogen` & `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 4 Hydrogen Low` & `3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` -> **Pool D (`deepseek/deepseek-v4-pro` / `deepseek-flash`)** -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Hydrogen Medium` & `Carbon Medium` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra medium`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Hydrogen High` & `Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` -> **Pool B (`Codex gpt-6.1-sol high`)** -> **Pool C (`Claude Sonnet 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` / `Argon High` / `Hydrogen XHigh`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` -> **Pool B (`Codex gpt-6-astra xhigh`)** -> **Pool C (`Claude Opus 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

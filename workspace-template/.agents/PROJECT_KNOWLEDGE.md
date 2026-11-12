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
1. **Universal Parent Orchestrator (Default: `Gemini 4 Carbon Medium`)**: Operates strictly as a **Pure Dispatcher / Orchestrator** (0 hands-on file reads/edits/builds in parent context, maintaining parent turns at `<35K` tokens with `~1s` latency).
2. **External-First Frontier Offload (`frontier-orchestrate.sh`)**:
   - `T1` Fast Explorer (`Model: "flash"` — `Gemini 3.8 Flash`, `Flash I/O` thinking): Codebase exploration, log slicing, read-only queries.
   - `T2` UI / Frontend / Tests (`frontier-orchestrate.sh --tier ui`: Claude Sonnet 4.6 -> Codex gpt-5.6-terra med -> DeepSeek-V4-Pro).
   - `T3` Multi-Service / Backend (`frontier-orchestrate.sh --tier backend`: Codex gpt-6-astra high -> Claude Sonnet 4.6 -> DeepSeek-V4-Pro).
   - `T4` Critical Architecture & Security (`codex-rca.sh` / `frontier-orchestrate.sh --tier deep`: Codex gpt-6-astra xhigh -> Claude Opus 4.6 high -> DeepSeek-V4-Pro).
   - Release & Gatekeeper Worker: Executes QA, Regression, Docs, Vault, Skills, and Review gates.
3. **Root Gatekeeper (`agy-gatekeeper.service` on `127.0.0.1:18099`)**: Cryptographic HMAC signing and verification of `.agent-state/*.json`.

---

## 3. Operating Rules & Invariants
1. **Single Writer**: Antigravity is the only agent with write access; external CLIs (Codex, Claude Code, OpenCode) execute strictly read-only.
2. **Execution Evidence**: Never declare a task complete or a check passed without concrete execution output.
3. **Autonomous Skills Distillation**: Update or synthesize `.agents/skills/<name>/SKILL.md` whenever new operational procedures or debugging playbooks are discovered.

---

## 📝 Recent Outcomes
<!-- Chronological record of completed architectural changes, features, and fixes -->
- Initialized workspace with Antigravity 4-Pool Multi-Model Orchestrator & agy-gatekeeper enforcement.

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

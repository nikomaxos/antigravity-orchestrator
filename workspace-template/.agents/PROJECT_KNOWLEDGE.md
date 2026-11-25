# Project Architecture & Knowledge Index

## 1. Overview & Architecture Index
This repository is protected by the Antigravity Multi-Model Orchestrator (`schema_version: 2026.11.7`, aligned with Antigravity Desktop `v2.35.1`) and Gatekeeper enforcement layer.

### Core Architecture Components
- **Source Code**: Project core implementation files.
- **Enforcement Layer**: `.agents/hooks.json`, `.agents/scripts/`, `.agents/rules/`, and `.agent-state/`.
- **Knowledge Vault**: `.agents/PROJECT_KNOWLEDGE.md` (architecture facts & changelog).
- **Skills Vault**: `.agents/skills/*/SKILL.md` (reusable operational playbooks & procedures).

---

## 2. Pure Zero-Hands-On Orchestrator & Multi-Pool Routing (DeepSeek Manual-Only)
1. **Universal Parent Orchestrator (`Orchestrator (Carbon -> Hydrogen)` / `Orchestrator (Neon -> Hydrogen)` — v2.35+ default `High` effort)**: Planning turns stay pure & `<35K` tokens, while `exit_plan_mode` hands execution directly to **`Gemini 4 Hydrogen`** (`2.5x` faster, `57%` vs `18.2%` Terminal-Bench 4.1, `>5x` fewer hallucinations). Never spawn `invoke_subagent(Model="flash")` (`3.8 Flash`) for pre-flight — pass directly via `exit_plan_mode` into `Gemini 4 Hydrogen` **Step 0: Read-Only Pre-Flight Check** with a `Re-plan if:` guard. **`Gemini 3.8 Flash` is permitted EXCLUSIVELY for the `browser` subagent.**
2. **External-First Frontier Offload (`frontier-orchestrate.sh`, active automated Pools B/C; Pool D DeepSeek is STRICTLY MANUAL-ONLY via `/opencode`)**:
   - `T1` Fast Explorer & Live-Ops Pre-Flight (`Gemini 4 Hydrogen Low` via `swarm` / `inherit`, or `Medium` for critical live checks; Reserve `--tier flash`: Pool C `Claude Sonnet 5.5 low` -> Pool B `Codex gpt-6-luna low`).
   - `T2` UI / Frontend / Tests (`Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + `--tier ui`: Claude Sonnet 5.5 med -> Codex gpt-6.1-terra med / sol).
   - `T3` Multi-Service / Backend (`Gemini 4 Neon High` / `Gemini 4 Hydrogen High` + `--tier backend`: Codex gpt-6.1-sol high / astra -> Claude Sonnet 5.5 high).
   - `T4` Critical Architecture & Security (`codex-rca.sh` / `--tier deep`: Codex gpt-6-astra xhigh / sol -> bounded Claude Sonnet 5.5 high [`--opus` opt-in], fallback `Carbon High` / `Neon XHigh` / `Hydrogen XHigh` / `Argon High`; `R3` review: Pool C Claude Opus 5.5 high primary -> Pool B Codex gpt-6-astra high).
   - Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`): Executes QA, Regression, Docs, Vault, Skills, and Review gates (backed by `~/.gemini/cache/pool-cooldowns.json` and fixed top-level read-only `codex -s read-only -C ... exec resume`).
3. **Root Gatekeeper (`agy-gatekeeper.service` on `127.0.0.1:18099`)**: Cryptographic HMAC signing and verification of `.agent-state/*.json`.

---

## 3. Operating Rules & Invariants
1. **Single Writer**: Antigravity is the only agent with write access; external CLIs (Codex, Claude Code, and manual OpenCode) execute strictly read-only.
2. **Execution Evidence**: Never declare a task complete or a check passed without concrete execution output.
3. **Autonomous Skills Distillation**: Update or synthesize `.agents/skills/<name>/SKILL.md` whenever new operational procedures or debugging playbooks are discovered.

---

## 📝 Recent Outcomes
<!-- Chronological record of completed architectural changes, features, and fixes -->
- Initialized workspace with Antigravity Multi-Model Orchestrator (`schema_version: 2026.11.7`, Antigravity Desktop `v2.35.1`, DeepSeek manual-only) & `agy-gatekeeper` enforcement.

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Limit — Zero-Gemini Pass-Through Mode)
- Όταν το metered 5h/7d υπόλοιπο Gemini πέσει κάτω από `10%` (`~/.gemini/config/gemini-quota.json`), **ΑΠΑΓΟΡΕΥΕΤΑΙ** κάθε `invoke_subagent` ή Gemini `swarm` worker (`Carbon`/`Neon`/`Hydrogen`/`Argon`/`3.8 Flash`).
- Ο Parent δρομολογεί 1-step Pass-Through αποκλειστικά σε **Pools B/C** (ΠΟΤΕ αυτόματο DeepSeek):
  - **`T1`**: `--tier flash` -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
  - **`T2`**: `--tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)**.
  - **`T3`**: `--tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)**.
  - **`T4`**: `--tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / Sonnet 5.5 high`)**.
- Επαναφορά: αυτόματα στο `>= 25%` (`auto-meter`) ή `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

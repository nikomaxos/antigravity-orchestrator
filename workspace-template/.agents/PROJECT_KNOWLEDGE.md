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

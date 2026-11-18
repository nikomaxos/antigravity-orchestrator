# Agent Completion Contract

A task is **NOT COMPLETE** unless ALL of the following are satisfied:

1. **Preflight completed** — relevant knowledge loaded, environment verified
2. **Implementation completed** — code changes written and reviewed
3. **Regression analysis completed** — affected components, APIs, and UI routes identified
4. **Automated tests executed** — existing test suites run against changes
5. **Affected existing functionality tested** — regression verification on surrounding features
6. **Documentation evaluated/updated** — README / documentation checked
7. **Knowledge vault & Skills evaluated/updated** — `.agents/PROJECT_KNOWLEDGE.md` and `.agents/skills/`
8. **Final QA artifact produced** — `.agent-state/qa.json` with status PASS
9. **Regression report produced** — `.agent-state/regression.json` with evidence

## ⛔ ABSOLUTE RULE

**1. DO NOT CLAIM A CHECK WAS PERFORMED WITHOUT EXECUTION EVIDENCE.**
- "build successful" is NOT evidence without actual command output.
- "tests pass" is NOT evidence without actual test runner output.
- "I checked and it looks good" → **NOT ACCEPTABLE**. Show the exact command and output.

**2. PURE ZERO-HANDS-ON ORCHESTRATOR & 5-TIER / 4-POOL MODEL ROUTING**
- **Pure Zero-Hands-On Orchestrator Mode**: The recommended UI defaults are **`Orchestrator (Carbon -> Hydrogen)`** (flagship planning) and **`Orchestrator (Neon -> Hydrogen)`** (`-25%` planning burn, `#2` Agent Arena & Steerability) — planning turns stay pure & `<35K` tokens; `exit_plan_mode` hands execution directly to **`Gemini 4 Hydrogen`**. **Never** downgrade `Hydrogen` turns to `invoke_subagent(Model="flash")` (`3.8 Flash`).
- **5-Tier Model Delegation (`schema_version: 2026.11.4`)**:
  - **`T1` Fast Explorer (`Gemini 4 Hydrogen Low` via `swarm`/`inherit`; reserve `Model: "flash"` `3.8 Flash` strictly for `browser` subagent & raw bulk log dumps from non-Orchestrator `Carbon`/`Neon`/`Argon` turns)**: Codebase exploration, grep/file scans, log slicing, DB/API read-only queries, and docs/skill synthesis (`2.5x` faster, `>5x` fewer hallucinations).
  - **`T2` UI, Frontend, Unit Tests & Standard CRUD Worker (`Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + Pool C `Claude Sonnet 5.5` read-only patch design / Codex `gpt-6.1-terra med`)**: Frontend UI pages, unit/DOM tests, simple CRUD endpoints, preserving project design systems.
  - **`T3` Multi-Service / Backend / Migrations & Integration Worker (`Gemini 4 Hydrogen High` / `Gemini 4 Neon High` (`65.2%` Terminal-Bench 4.1, `-25%` vs Carbon) + Pool D `DeepSeek-V4-Pro` precheck + Pool B `Codex gpt-6.1-sol high` review)**: Cross-service integration, database migrations, and live API validation.
  - **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA Worker (`Gemini 4 Carbon High` `Model: "pro"` / `Gemini 4 Neon XHigh` / `Gemini 4 Hydrogen XHigh` / `Gemini 4 Argon High` / `Claude Opus 5.5 High` / `Codex gpt-6-astra xhigh`)**: Concurrency races, low-level protocols, crypto/auth, deep multi-file SWE & RCAs (`codex-rca.sh`), and `R3` Security Reviews.
  - **Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`)**: Executes QA/Regression/Docs/Vault/Skills/Review gates (backed by `agy-gatekeeper.service` on `127.0.0.1:18099`), commits explicit files, and runs post-commit security sync.
- **Transparency**: Any time an agent delegates work to a subagent, `swarm` worker, or external CLI, they MUST explicitly declare this to the user in Greek, stating the role, EXACT AI model name (e.g., `Gemini 4 Hydrogen`, `Gemini 4 Neon`, `Gemini 4 Carbon`, `Gemini 3.8 Flash` for `browser`/bulk I/O, `Claude Sonnet 5.5`, `gpt-6.1-sol`, `gpt-6-astra`, `deepseek-v4-pro`), AND the reasoning/effort level (`Low`, `Flash I/O`, `Medium`, `High`, `xhigh` / `XHigh`).

**3. AUTONOMOUS SKILLS DISTILLATION LOOP**
- Do NOT wait for human prompting to create or update skills.
- Whenever a task involves deep debugging / RCA, complex architectural patterns, or edge-case troubleshooting playbooks, the agent MUST autonomously synthesize or update the corresponding skill in `.agents/skills/<name>/SKILL.md`.

## Machine-Checkable State

All gates are tracked in `.agent-state/` JSON files. The lifecycle hooks in `.agents/hooks.json` enforce these gates programmatically — the agent **cannot** `git commit` or stop without passing them.

| Gate | State File | Required Value |
|------|-----------|----------------|
| QA | `.agent-state/qa.json` | `status: "PASS"` |
| Regression | `.agent-state/regression.json` | `status: "PASS"` or `"NOT_APPLICABLE"` |
| Vault | `.agent-state/vault.json` | `updated: true` |
| Docs | `.agent-state/docs.json` | `evaluated: true` |
| Skills | `.agent-state/skills.json` | `evaluated: true`, `status: "UPDATED"` or `"NO_UPDATE_NEEDED"` |
| Security | `.agent-state/security.json` | `reviewed: true`, `status: "PASS"` |
| Cross-Model Review (commit only, code changes) | `.agent-state/codex-review.json` | `status: "PASS"` or `"PASS_FALLBACK"`, `owasp_checklist` >= 3 |

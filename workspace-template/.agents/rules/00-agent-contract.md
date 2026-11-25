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

**2. PURE ZERO-HANDS-ON ORCHESTRATOR & 5-TIER MODEL ROUTING (`Pool 0` + `Pools A/A+, B, C` | `Pool D` Manual-Only)**
- **Pure Zero-Hands-On Orchestrator Mode (`Antigravity Desktop v2.35.1`)**: Recommended UI defaults are **`Orchestrator (Carbon -> Hydrogen)`** and **`Orchestrator (Neon -> Hydrogen)`** (v2.35+ defaults Orchestrator & Executor to `High` effort; auto-resumes conversations on restart — verify stopped background subagents/tasks on wakeup). Planning turns stay pure & `<35K` tokens; `exit_plan_mode` hands execution directly to **`Gemini 4 Hydrogen`**. **Never** spawn `invoke_subagent(Model="flash")` (`3.8 Flash`) for pre-flight verification or downgrade `Hydrogen` turns to `3.8 Flash`; instead transition via `exit_plan_mode` into `Gemini 4 Hydrogen` with a **Step 0: Read-Only Pre-Flight Check** and **`Re-plan if:`** guard. **`Gemini 3.8 Flash` (`Model="flash"`) is permitted EXCLUSIVELY for the `browser` subagent.**
- **5-Tier Model Delegation (`schema_version: 2026.11.7`, DeepSeek Manual-Only)**:
  - **`T1` Fast Explorer & Live-Ops Pre-Flight (`Gemini 4 Hydrogen Low` via `swarm` `gemini-4-hydrogen-low` / `inherit`, or `Gemini 4 Hydrogen Medium` for critical live checks; Reserve `--tier flash`: Pool C `Claude Sonnet 5.5 low` -> Pool B `Codex gpt-6-luna low`)**: Codebase exploration, live-ops pre-flight checks, grep/file scans, log slicing, DB/API read-only queries, and docs/skill synthesis (`2.5x` faster, `57%` vs `18.2%` Terminal-Bench, `>5x` fewer hallucinations). **NEVER use `Gemini 3.8 Flash` outside the `browser` subagent.**
  - **`T2` UI, Frontend, Unit Tests & Standard CRUD Worker (`Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + Pool C `Claude Sonnet 5.5` read-only patch design / Codex `gpt-6.1-terra med`)**: Frontend UI pages, unit/DOM tests, simple CRUD endpoints, preserving project design systems.
  - **`T3` Multi-Service / Backend / Migrations & Integration Worker (`Gemini 4 Hydrogen High` / `Gemini 4 Neon High` (`65.2%` Terminal-Bench 4.1, `-25%` vs Carbon) + Pool B `Codex gpt-6.1-sol high` -> Pool C `Claude Sonnet 5.5 high` + `R2` review)**: Cross-service integration, database migrations, and live API validation.
  - **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA Worker (`Gemini 4 Carbon High` `Model: "pro"` / `Gemini 4 Neon XHigh` / `Gemini 4 Hydrogen XHigh` / `Gemini 4 Argon High` / `Claude Sonnet 5.5 High` [`--opus` opt-in for bounded tasks] / `Codex gpt-6-astra xhigh`)**: Concurrency races, low-level protocols, crypto/auth, deep multi-file SWE & bounded RCAs (`codex-rca.sh`), and `R3` Security Reviews (Pool C `Claude Opus 5.5 High` primary → Pool B `Codex gpt-6-astra High` failover).
  - **Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`)**: Executes QA/Regression/Docs/Vault/Skills/Review gates (backed by `agy-gatekeeper.service` on `127.0.0.1:18099`), commits explicit files, and runs post-commit security sync.
  - **Manual-Only Pool D (`OpenCode / DeepSeek`)**: Excluded from ALL automatic cascades; invoked ONLY when explicitly requested by the user (`/opencode` or `stage0-precheck.sh --manual`).
- **Transparency**: Any time an agent delegates work to a subagent, `swarm` worker, or external CLI, they MUST explicitly declare this to the user in Greek, stating the role, EXACT AI model name (e.g., `Gemini 4 Hydrogen`, `Gemini 4 Neon`, `Gemini 4 Carbon`, `Gemini 3.8 Flash` ONLY for `browser`, `Claude Sonnet 5.5`, `Claude Opus 5.5`, `gpt-6.1-sol`, `gpt-6-astra`), AND the reasoning/effort level (`Low`, `Medium`, `High`, `xhigh` / `XHigh`, or `Flash` for `browser`).

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

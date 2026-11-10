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
- **Pure Zero-Hands-On Orchestrator Mode**: The Parent Agent runs permanently on **`Gemini 4 Carbon (Medium)`** as a **Pure Dispatcher / Orchestrator**. Apart from pure zero-tool conversational replies (or reading `.agents/PROJECT_KNOWLEDGE.md` index once for triage), the Parent is **FORBIDDEN** from directly grepping/reading codebase files, slicing logs, editing project source files, or running builds/tests/CLIs in its own turn. Keeping all raw tool outputs inside disposable subagents keeps parent context ultra-thin (`<35K–60K` tokens) automatically with `~1s` latency.
- **5-Tier Model Delegation**:
  - **`T1` Fast Explorer (`Model: "flash"` — `Gemini 3.8 Flash`, `Flash I/O` thinking)**: MANDATORY for codebase exploration, grep/file scans, log slicing, DB/API read-only queries, and docs/skill synthesis. Structured output `<1,000` tokens.
  - **`T2` UI, Frontend, Unit Tests & Standard CRUD Worker (`Gemini 4 Carbon Medium` / Pool C `Claude Sonnet` read-only patch design)**: Frontend UI pages, unit/DOM tests, simple CRUD endpoints, preserving project design systems.
  - **`T3` Multi-Service / Backend / Migrations & Integration Worker (`Gemini 4 Carbon Medium` + Pool D `DeepSeek-V4-Pro` precheck + Pool B `Codex gpt-6-astra high` review)**: Cross-service integration, database migrations, and live API validation.
  - **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA Worker (`Gemini 4 Carbon High` `Model: "pro"` with `DEEP ANALYTICAL HIGH` reasoning / `Claude Opus 4.6 High` / `Codex gpt-6-astra xhigh`)**: Concurrency races, low-level protocols, crypto/auth, deep multi-file RCAs (`codex-rca.sh`), and `R3` Security Reviews.
  - **Release & Gatekeeper Worker (`Model: "flash"` docs-only or `Model: "inherit"` `Carbon Medium`)**: Executes QA/Regression/Docs/Vault/Skills/Review gates (backed by `agy-gatekeeper.service` on `127.0.0.1:18099`), commits explicit files, and runs post-commit security sync.
- **Transparency**: Any time an agent delegates work to a subagent or external CLI, they MUST explicitly declare this to the user in Greek, stating the role, EXACT AI model name (e.g., `Gemini 3.8 Flash`, `Gemini 4 Carbon`, `Claude Sonnet`, `gpt-6-astra`, `deepseek-v4-pro`), AND the reasoning/effort level (`Flash I/O`, `Medium`, `High`, `xhigh`).

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

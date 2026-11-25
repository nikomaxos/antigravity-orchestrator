# Project Workspace Rules (Antigravity `v2.35.1` · `schema_version: 2026.11.7`)

- **KNOWLEDGE VAULT**: Before executing any task, read `.agents/PROJECT_KNOWLEDGE.md` as the architecture index, then load task-relevant domain files from `.agents/knowledge/`.
- **ENFORCEMENT LAYER & ROOT GATEKEEPER (`agy-gatekeeper.service`)**: Programmatic enforcement runs via `.agents/hooks.json`, `127.0.0.1:18099` Gatekeeper daemon, `.agent-state/*.json`, and native `.git/hooks/{pre-commit,post-commit}`. The agent **cannot** `git commit` or stop without passing all gates. See `.agents/rules/00-agent-contract.md`.
- **ANTIGRAVITY DESKTOP `v2.35.1` ALIGNMENT & RULES BUDGET**:
  - Keep rules concise (`24 KB`/file, `20,000`-token `defaultRulesBudget`); `~/.gemini/config/AGENTS.md` is canonical and `GEMINI.md` is a compact pointer.
  - Orchestrator & Executor default to `High` thinking effort in `v2.35+`; interrupted sessions auto-resume after restart (verify stopped background subagents/tasks on wakeup). Local history is unlimited by default (`gemini-budget.js` pre-filters by directory + 8d mtime).
- **PURE ZERO-HANDS-ON ORCHESTRATOR & EXTERNAL-FIRST ROUTING (`Pool 0` + `Pools A/A+, B, C` | `Pool D` Manual-Only)**:
  - **Orchestrator Defaults**: `Orchestrator (Carbon -> Hydrogen)` / `Orchestrator (Neon -> Hydrogen)` (`Carbon`/`Neon` plans -> `exit_plan_mode` executes on `Gemini 4 Hydrogen`). Inside any `Hydrogen` turn, execute directly (or via `Model: "inherit"` / `swarm` `gemini-4-hydrogen-*` | `gemini-4-neon-*`) — **NEVER** downgrade to `invoke_subagent(Model="flash")` (`3.8 Flash`). Transition planning turns via `exit_plan_mode` into `Gemini 4 Hydrogen` **Step 0: Read-Only Pre-Flight Check** (`Re-plan if:` guard). **`Gemini 3.8 Flash` (`Model="flash"`) is permitted STRICTLY for the `browser` subagent only.**
  - **External-First Offload (`bash .agents/scripts/frontier-orchestrate.sh --tier <ui|backend|deep|flash>`)**: Routes heavy design to **Pool B (`Codex`)** and **Pool C (`Claude`)** first, falling back to Pool A (`Hydrogen`/`Neon`/`Carbon`) on exit `2`:
    - **`T1` Explorer / Live-Ops Pre-Flight**: `Gemini 4 Hydrogen Low` (`swarm` / `inherit`) or `Medium` for critical live checks. Reserve (`--tier flash`): Pool C `Claude Sonnet 5.5 low` -> Pool B `Codex gpt-6-luna low`.
    - **`T2` UI, Tests & CRUD**: `Gemini 4 Hydrogen Medium` / `Neon Low|Medium` + `--tier ui` (`Claude Sonnet 5.5 med` -> `Codex gpt-6.1-terra med / sol`).
    - **`T3` Multi-Service & Migrations**: `Gemini 4 Hydrogen High` / `Neon High` (`65.2%` Terminal-Bench 4.1, `-25%` vs Carbon) + `--tier backend` (`Codex gpt-6.1-sol high / astra` -> `Claude Sonnet 5.5 high`).
    - **`T4` Critical Architecture, Concurrency, Hardware & Security**: `codex-rca.sh` / `--tier deep` (`Codex gpt-6-astra xhigh / sol` -> bounded `Claude Sonnet 5.5 high` [`--opus` opt-in]), fallback `Carbon High` / `Neon XHigh` / `Hydrogen XHigh` / `Argon High`.
    - **Release & Gatekeeper Worker**: `Gemini 4 Hydrogen Low/Medium` executes gates, commits explicit paths, and runs `sync-security-from-review.sh`.
- **CROSS-MODEL COUNCIL (SINGLE-WRITER = ANTIGRAVITY; DEEPSEEK STRICTLY MANUAL-ONLY)**:
  - External CLIs — **Pool B OpenAI Codex** (`codex -s read-only -C ... exec [resume]`) and **Pool C Anthropic Claude Code** (`claude -p --permission-mode plan`) — are **strictly read-only analysts**.
  - **⛔ DeepSeek / OpenCode (`Pool D`) is STRICTLY MANUAL-ONLY**: NEVER invoke `opencode`, `opencode-orchestrate.sh`, `stage0-precheck.sh`, or `--cli opencode` automatically. Run DeepSeek **ONLY** when the user explicitly requests `/opencode` or DeepSeek manually (read-only `--agent readonly-auditor`).
  - Pre-commit review gate (`run-codex-review-gate.sh`): `R1`/`R2` Pool B Codex -> Pool C Claude; **`R3` Pool C `claude-opus-5-5 high` primary -> Pool B `gpt-6-astra high`**, backed by `~/.gemini/cache/pool-cooldowns.json` and Pool A `--fallback`.
- **DYNAMIC ROUTING**: Driven by `.agents/config/model-routing.json` (`schema_version: "2026.11.7"`, synced via `agy-arch-sync` + SSE `agy-sync-daemon`).
- **SUBAGENT TRANSPARENCY & LANGUAGE**: Communicate with the USER exclusively in **Greek (Ελληνικά)**. Whenever delegating via `invoke_subagent`, `swarm`, or external CLI, ALWAYS state in Greek the role, exact model name, and thinking/effort level.
- **AUTONOMOUS SKILLS DISTILLATION**: Autonomously update `.agents/skills/*/SKILL.md` whenever deep RCAs or operational traps are discovered.

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Limit — Zero-Gemini Pass-Through Mode)
- **Αυτόματη Ενεργοποίηση (`gemini-budget.js`)**: Μετρά 5h/7d Gemini tokens έναντι `model-routing.json -> gemini_quota_guard` (`200K` fleet hard limit, προαιρετικό local override στο `~/.gemini/config/model-routing.local.json`). Κάτω από `10%` ενεργοποιεί `~/.gemini/config/gemini-quota.json` (`auto-meter`, auto-restore `>=25%`). Context > `ctx_hard_limit_tokens` -> ζήτα `/compact`.
- **Zero-Gemini Pass-Through (Αποκλειστικά Pools B/C — ΠΟΤΕ αυτόματο DeepSeek)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** κάθε `invoke_subagent` ή Gemini `swarm` worker (`Carbon`/`Neon`/`Hydrogen`/`Argon`/`3.8 Flash`).
  - Ο Parent δρομολογεί 1-step Pass-Through μέσω `frontier-orchestrate.sh`:
    - **`T1`**: `--tier flash` -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
    - **`T2`**: `--tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)**.
    - **`T3`**: `--tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)**.
    - **`T4`**: `--tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / Sonnet 5.5 high`)**.
  - Χειροκίνητη επαναφορά: `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

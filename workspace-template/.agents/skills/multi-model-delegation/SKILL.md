---
name: multi-model-delegation
description: >-
  Use this skill on every non-trivial task to route exploration, coding, RCA,
  review, and security checks across the 5 Task Tiers (T0-T4) and 4 Quota Pools
  (Antigravity, OpenAI Codex CLI, Anthropic Claude Code CLI, OpenCode DeepSeek CLI)
  while preserving Thin-Orchestrator context hygiene (<120K-160K tokens).
---
# Multi-Model & Multi-CLI Delegation Skill (5-Tier / 4-Pool Playbook)

## 1. Why This Architecture Exists (Pure Zero-Hands-On Orchestrator Invariants)
1. **Parent is 100% Zero-Hands-On Dispatcher (`Gemini 4 Carbon Medium`)**: The Parent Agent never reads/edits codebase files, slices logs, or runs builds/tests/CLIs directly. Keeping all raw outputs inside disposable subagents keeps parent context ultra-thin (`<35K–60K` tokens) automatically with ~`1s` response latency.
2. **Never use `Carbon High` for I/O exploration**: `Carbon High` has ~`59s` median step latency and rapidly drains weekly Antigravity quota. Always spawn `Model: "flash"` (`Gemini 3.8 Flash`, `Flash I/O` thinking) for codebase search, log slicing, and read-only checks.
3. **Never let a parent chat exceed `120K–160K` input tokens**: With Pure Orchestrator mode, parent context stays tiny (~`2K` tokens/task). If a chat ever approaches `120K`, use `/compact` or rotate to a fresh session via `.agent-reports/handoff-latest.md`.
4. **Antigravity is the SINGLE WRITER**: External CLIs (`codex`, `claude`, `opencode`) are strictly **read-only** analysts/patch-producers in this workspace (`protect-enforcement.sh` blocks write flags).

## 2. The 4 Orthogonal Quota Pools

| Pool | Provider & Billing | Binaries / Wrappers | Primary Strengths |
|------|-------------------|---------------------|-------------------|
| **Pool A** | **Antigravity Native** (Subscription) | Pure Parent Orchestrator + `invoke_subagent` (`Model: "flash"`, `"inherit"`, `"pro"`) | **Single Writer**, `Gemini 3.8 Flash` (`T1` Explorer), `Gemini 4 Carbon Med` (`T2`/`T3` Worker), `Carbon High` `Model: "pro"` (`T4` Critical) |
| **Pool B** | **OpenAI Codex CLI** (ChatGPT Plus) | `.agents/scripts/codex-rca.sh`, `run-codex-review-gate.sh`, `~/.gemini/config/skills/codex/scripts/codex-orchestrate.sh` | Deep architecture/concurrency RCA (`gpt-6-astra xhigh`), Primary Review Gate (`R1`: `terra med`, `R2`: `astra med`, `R3`: `astra high`), Stateful `codex exec resume` |
| **Pool C** | **Anthropic Claude Code CLI** (Claude Pro/Max) | `~/.gemini/config/skills/claude/scripts/claude-orchestrate.sh` + auto-failover in `codex-lib.sh` | Surgical UI/Frontend planning (`sonnet`), Architecture & Security Review (`opus` / `sonnet high`), #1 Failover when Codex is rate-limited |
| **Pool D** | **OpenCode CLI + DeepSeek API** (Pay-As-You-Go pennies/Mtok) | `.agents/scripts/stage0-precheck.sh`, `~/.gemini/config/skills/opencode/scripts/opencode-orchestrate.sh` | Stage-0 Pre-Gate bug check (`deepseek/deepseek-v4-pro`), bulk log/diff pre-screening (`deepseek/deepseek-flash`), zero-burn safety net |

### 2.1 Pool A+ (Antigravity Plus Native Claude Credits Mode)
- **Proactive Notification on External Rate Limit**:
  - Whenever external Pool C (`Claude Code CLI`) hits its 5h rate limit (`RATE_LIMITED` in `.agent-reports/codex/usage.log`) or before a large UI redesign task, proactively notify the user in Greek:
    > *"💡 Το εξωτερικό Claude CLI είναι σε rate-limit. Αν θέλεις να αξιοποιήσουμε το Antigravity Plus Claude bundle σου, γύρνα το Dropdown σε Claude Sonnet/Opus"*.
- **Routing Rules when UI Model is Switched to Claude**:
  - When the user switches the Antigravity UI Dropdown to Claude (detected via `<USER_SETTINGS_CHANGE>`):
    1. **`T1` Explorers**: Automatically keep all `T1` Explorers strictly on `Model: "flash"` (`Gemini 3.8 Flash`, `Flash I/O` thinking), so file-reading and log triage NEVER burn Plus Claude credits.
    2. **`T2` / `T3` / `T4` Coding Subagents**: Use `Model: "inherit"`, executing natively on Antigravity Claude with full write tools, completely skipping redundant external `claude -p --tier ui` calls.

## 3. Pure Zero-Hands-On 5-Tier Task Routing Matrix (`T0` – `T4`) & External-First Frontier Offload

- **Universal Frontier Parent Orchestrator (`Gemini 4 Carbon Medium` default, or `Claude Sonnet 4.6` / `Claude Opus 4.6` / `Gemini 3.8 Flash` in UI Dropdown)**: Pure conversational triage and dispatching (0 direct codebase reads/edits/builds in parent). Any frontier model selected in the Antigravity UI Dropdown can act as the Pure Zero-Hands-On Parent Orchestrator (`Pool A+` when Claude is selected, while keeping `T1` Explorers strictly on `Model: "flash"`).
- **External-First Frontier Offload (`frontier-orchestrate.sh`)**: To prevent `Pool A` (`Gemini 4 Carbon`) from running out of quota while `Pool B` (`Codex`), `Pool C` (`Claude`), and `Pool D` (`DeepSeek`) still have credits, prefer spawning a lightweight Executor subagent (`Model: "flash"` — `Gemini 3.8 Flash`, which draws from the abundant Flash pool) for `T2`, `T3`, and `T4` tasks that calls `bash .agents/scripts/frontier-orchestrate.sh --tier <ui|backend|deep>` so **Pools B/C/D perform the heavy frontier reasoning & patch design FIRST**, and the `Flash` subagent applies the edits, runs tests, and executes the gates. Reserve multi-step `Model: "inherit"` (`Carbon Medium`) and `Model: "pro"` (`Carbon High`) subagent loops for when interactive multi-step assistance is required or when `frontier-orchestrate.sh` exits `2` (all external pools rate-limited/exhausted).
- **`T1` Exploration, Log Slicing & Docs (`invoke_subagent` with `Model: "flash"`)**: Multi-file grep/read, log extraction, read-only DB/API telemetry checks, `frontier-orchestrate.sh --tier flash`, `SKILL.md` / documentation drafting. Flash subagent returns `<1,000` tokens of structured findings (`file:line` + snippets).
- **`T2` UI, Frontend, Unit Tests & Standard CRUD Worker (`Model: "flash"` Executor + `frontier-orchestrate.sh --tier ui`, or `Model: "inherit"` `Gemini 4 Carbon Medium`)**:
  - Calls `bash .agents/scripts/frontier-orchestrate.sh --tier ui --prompt "<task>"` (cascading **Pool C `Claude Sonnet 4.6` -> Pool B `Codex gpt-5.6-terra medium` -> Pool D `DeepSeek-V4-Pro`**) to obtain a read-only unified diff, then applies and verifies it in the subagent while strictly preserving project design systems. Falls back to `Model: "inherit"` (`Gemini 4 Carbon Medium`) if `frontier-orchestrate.sh` exits `2`.
- **`T3` Multi-Service / Backend / Migrations & Integration Worker (`Model: "flash"` Executor + `frontier-orchestrate.sh --tier backend`, or `Model: "inherit"` `Gemini 4 Carbon Medium`)**:
  - Calls `bash .agents/scripts/frontier-orchestrate.sh --tier backend --prompt "<task>"` (cascading **Pool B `Codex gpt-6-astra high` -> Pool C `Claude Sonnet 4.6` -> Pool D `DeepSeek-V4-Pro`**) + Stage-0 DeepSeek precheck + `R2` Cross-Model Review Gate + live API verification. Falls back to `Model: "inherit"` (`Gemini 4 Carbon Medium`) if `frontier-orchestrate.sh` exits `2`.
- **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA Worker (`Model: "flash"`/`"pro"` Worker + `codex-rca.sh` / `frontier-orchestrate.sh --tier deep`)**:
  - Deep RCA & surgical patch design via **`codex-rca.sh`** or **`frontier-orchestrate.sh --tier deep`** (cascading **Pool B `Codex gpt-6-astra xhigh` -> Pool C `Claude Opus 4.6 high` -> Pool D `DeepSeek-V4-Pro`**), falling back to `Model: "pro"` (`Gemini 4 Carbon High` with `DEEP ANALYTICAL HIGH` reasoning) if external pools exit `2`, followed by `R3` Cross-Model Review Gate + dedicated Post-Commit Security Reviewer.
- **Release & Gatekeeper Worker (`Model: "flash"` docs-only or `Model: "flash"`/`"inherit"` for code commits)**: Runs all automated gates (`run-qa-gate.sh`, `run-regression-gate.sh`, `run-docs-gate.sh`, `run-vault-gate.sh`, `run-skills-gate.sh`, `run-codex-review-gate.sh` backed by root `agy-gatekeeper.service`), stages explicit files, commits, and synchronizes security review.

## 4. Mandatory Transparency Rule (Greek)
Whenever delegating to ANY subagent or external CLI, ALWAYS inform the user in Greek with:
1. Role / purpose,
2. Exact model name (`Gemini 3.8 Flash`, `Gemini 4 Carbon`, `Claude Sonnet`, `Claude Opus`, `gpt-6-astra`, `gpt-5.6-terra`, `deepseek-v4-pro`),
3. Exact thinking / effort level (`Flash I/O`, `Medium`, `High`, `xhigh`).

## 5. One-Time CLI Credential Setup
- **Claude Pro/Max**: `claude login`
- **DeepSeek API**: Configure `DEEPSEEK_API_KEY="sk-..."` in `~/.config/llm-council/secrets.env` (`chmod 600`)
- **Codex CLI**: `codex login`

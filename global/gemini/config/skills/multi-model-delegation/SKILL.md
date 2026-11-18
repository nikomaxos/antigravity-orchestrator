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
1. **Default Orchestrators are `Orchestrator (Carbon -> Hydrogen)` & `Orchestrator (Neon -> Hydrogen)`**: Flagship planning turns run on `Carbon` (or `-25%`-cost `#2` Steerability planning on `Gemini 4 Neon`), staying pure & ultra-thin (`<35K–60K` tokens), while `exit_plan_mode` hands execution automatically to **`Gemini 4 Hydrogen`** (`19%` faster, `~24%` less quota overall than Carbon alone).
2. **`Gemini 4 Neon` bridges `Hydrogen` speed and `Carbon` depth**: **`Gemini 4 Neon`** scores **65.2%** on Terminal-Bench 4.1 (`#2` Agent Arena Index & `#2` Steerability, `0.0%` shortcut rate, `39.0%` SWE-sweep, AA Intelligence `61` at `xhigh`) at **`$3/$15` (-25% vs Carbon `$4/$20`)**, making it the primary Pool A escalation target for **`T3` multi-file backend/refactoring (`High`)**, **`T2` high-steerability UI (`Low/Medium`)**, and **`T4` complex multi-file SWE (`XHigh`)**.
3. **`Gemini 4 Hydrogen` replaces `Gemini 3.8 Flash` across execution, coding, triage & gates**: `Gemini 4 Hydrogen` is up to **2.5x faster**, scores **~57.0% vs 18.2%** on Terminal-Bench 4.1 (**>3x leap**), cuts hallucinations by **>5x**, uses **~23% fewer tokens**, and supports native parallel tool batching (`2x` per-token rate -> `~1.5x` net cost for `3x` quality). Reserve `3.8 Flash` (`invoke_subagent Model: "flash"`, `0.5x` token rate) **strictly** for (a) the `browser` subagent and (b) disposable `100K+`-token bulk raw file/log scans spawned from non-Orchestrator `Carbon`/`Neon`/`Argon` turns (since `invoke_subagent` enum only accepts `"inherit"|"flash_lite"|"flash"|"pro"`).
4. **Never downgrade `Hydrogen` turns to `Model: "flash"`**: Inside an `Orchestrator (Carbon/Neon/Argon)` execution turn or `Hydrogen` UI mode, the active agent **IS ALREADY `Gemini 4 Hydrogen`** — execute edits, `frontier-orchestrate.sh`, tests, and gates directly (or with `Model: "inherit"` / `swarm(action="add", model="gemini-4-hydrogen-..." | "gemini-4-neon-...")`), never calling `invoke_subagent(Model="flash")`.
5. **Never use `Carbon High` for I/O exploration & never exceed `120K–160K` parent tokens**: Rotate via `/compact` or `.agent-reports/handoff-latest.md`.
6. **Antigravity is the SINGLE WRITER**: External CLIs (`codex`, `claude`, `opencode`) are strictly **read-only** analysts/patch-producers in gated workspaces (`protect-enforcement.sh` blocks write flags).

## 2. The 4 Orthogonal Quota Pools + Pool A+ Bundle

| Pool | Provider & Billing | Binaries / Wrappers | November 2026 Model Matrix & Strengths |
|------|-------------------|---------------------|----------------------------------------|
| **Pool A** | **Antigravity Native** (Subscription — shared Gemini bucket) | `Orchestrator (Carbon/Neon/Argon)` + `swarm` (`gemini-4-hydrogen-*`, `gemini-4-neon-*`) + `invoke_subagent` (`"inherit"`, `"pro"`, `"flash"` for `browser`/bulk-I/O) | **Single Writer**: `Orchestrator (Carbon -> Hydrogen)` & `Orchestrator (Neon -> Hydrogen)` (`T0`), `Gemini 4 Hydrogen Low` (`T1` Explorer/Gatekeeper), `Gemini 4 Hydrogen Med` / `Neon Low|Med` (`T2`), **`Gemini 4 Neon High` / `Hydrogen High`** (`T3`), `Gemini 4 Carbon High` (`T4` Concurrency/Protocols), **`Gemini 4 Neon XHigh`** (`T4` deep SWE/refactoring), `Gemini 4 Hydrogen xhigh` (`T4` iterative debugging), `Gemini 4 Argon High` (`T4` compliance), `Gemini 3.8 Flash` (`browser` & bulk raw I/O from non-Orchestrator turns) |
| **Pool A+** | **Antigravity Plus Credit Bundle** | Antigravity UI Dropdown Model Switch | `Claude Sonnet 5.5` (`low`/`medium`/`high`), `Claude Opus 5.5` (`high`), `gpt-oss-120b-medium` |
| **Pool B** | **OpenAI Codex CLI** (ChatGPT Plus) | `codex-orchestrate.sh`, `codex-rca.sh`, `run-codex-review-gate.sh` | Primary Review Gate (`R1`: `gpt-6.1-terra med`, `R2`: `gpt-6.1-sol high`, `R3`: `gpt-6-astra high`), `t1_reserve`: `gpt-6-luna low`, Deep RCA: `gpt-6-astra xhigh`, Stateful `codex exec resume` |
| **Pool C** | **Anthropic Claude Code CLI** (Claude Pro/Max) | `claude-orchestrate.sh` + auto-failover in `codex-lib.sh` | Surgical UI planning (`claude-sonnet-5-5 med`), Architecture & Security Review (`claude-opus-5-5 high`, fallback `opus` -> `sonnet`), #1 Failover when Codex is rate-limited |
| **Pool D** | **OpenCode CLI + DeepSeek API** (Pay-As-You-Go pennies/Mtok) | `stage0-precheck.sh`, `opencode-orchestrate.sh` | Stage-0 Pre-Gate bug check (`deepseek/deepseek-v4-pro`), bulk log/diff pre-screening (`deepseek/deepseek-flash`), zero-burn safety net (`opencode/deepseek-v4.1-flash-free`) |

### 2.1 Pool A+ (Antigravity Plus Native Claude Credits Mode)
- **Proactive Notification on External Rate Limit**:
  - Whenever external Pool C (`Claude Code CLI`) hits its 5h rate limit (`RATE_LIMITED` in `.agent-reports/codex/usage.log`) or before a large UI redesign task, proactively notify the user in Greek:
    > *"💡 Το εξωτερικό Claude CLI είναι σε rate-limit. Αν θέλεις να αξιοποιήσουμε το Antigravity Plus Claude bundle σου, γύρνα το Dropdown σε Claude Sonnet 5.5 / Opus 5.5"*.
- **Routing Rules when UI Model is Switched to Claude**:
  - When the user switches the Antigravity UI Dropdown to Claude (detected via `<USER_SETTINGS_CHANGE>`):
    1. **`T1` Explorers**: Use `swarm` `gemini-4-hydrogen-low` for high-accuracy triage, or `invoke_subagent(Model="flash")` (`3.8 Flash`) for raw bulk log dumps, so exploration NEVER burns Plus Claude credits.
    2. **`T2` / `T3` / `T4` Coding Subagents**: Use `Model: "inherit"`, executing natively on Antigravity Claude with full write tools, completely skipping redundant external `claude -p --tier ui` calls.

## 3. Pure Zero-Hands-On 5-Tier Task Routing Matrix (`T0` – `T4`) & External-First Frontier Offload

- **Universal Frontier Parent Orchestrator (`Orchestrator (Carbon -> Hydrogen)` / `Orchestrator (Neon -> Hydrogen)` / `Gemini 4 Carbon Medium` default, or `Gemini 4 Neon` / `Gemini 4 Hydrogen` / `Claude 5.5` in UI Dropdown)**: Pure conversational triage and planning (0 direct codebase reads/edits/builds during `Carbon`/`Neon`/`Argon`/`Claude` planning turns). When `exit_plan_mode` hands execution to **`Gemini 4 Hydrogen`**, execute directly without downgrading to `Model: "flash"`.
- **External-First Frontier Offload (`frontier-orchestrate.sh`)**: To prevent `Pool A` (`Gemini 4`) from running out of quota while `Pool B` (`Codex`), `Pool C` (`Claude`), and `Pool D` (`DeepSeek`) still have credits, run `bash .agents/scripts/frontier-orchestrate.sh --tier <ui|backend|deep>` inside the **`Gemini 4 Hydrogen`** execution turn (or via `swarm` `gemini-4-hydrogen-low|medium`, or `Model: "flash"` only when spawning from non-Orchestrator `Carbon`/`Neon`/`Argon` turns) so **Pools B/C/D perform the heavy frontier reasoning & patch design FIRST**, and **`Gemini 4 Hydrogen`** applies edits, runs tests, and executes gates. Fall back to native **`Gemini 4 Hydrogen` (`Medium`/`High`)**, **`Gemini 4 Neon` (`High`/`XHigh`)**, or `Model: "pro"` (`Carbon High`) loops when `frontier-orchestrate.sh` exits `2`.
- **`T1` Exploration, Log Slicing & Docs (`Gemini 4 Hydrogen Low` / `swarm`, or `Model: "flash"` only for `browser`/bulk raw dumps from `Carbon`/`Neon`)**: Multi-file grep/read, log extraction, read-only DB/API telemetry checks, `frontier-orchestrate.sh --tier flash`, `SKILL.md` / docs drafting (`<1,000` tokens structured findings).
- **`T2` UI, Frontend, Unit Tests & Standard CRUD (`Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + `frontier-orchestrate.sh --tier ui`)**:
  - Calls `bash .agents/scripts/frontier-orchestrate.sh --tier ui --prompt "<task>"` (cascading **Pool C `Claude Sonnet 5.5 med` -> Pool B `Codex gpt-6.1-terra med / sol` -> Pool D `DeepSeek-V4-Pro`**), then applies and verifies via **`Gemini 4 Hydrogen Medium`** (or **`Gemini 4 Neon Low/Medium`** for high-steerability UI state) while strictly preserving project design systems. Falls back to native **`Gemini 4 Hydrogen Medium`** / **`Gemini 4 Neon Low|Medium`** / `Carbon Medium` if `frontier-orchestrate.sh` exits `2`.
- **`T3` Multi-Service / Backend / Migrations & Integration (`Gemini 4 Hydrogen High` / `Gemini 4 Neon High` + `frontier-orchestrate.sh --tier backend`)**:
  - Calls `bash .agents/scripts/frontier-orchestrate.sh --tier backend --prompt "<task>"` (cascading **Pool B `Codex gpt-6.1-sol high / astra` -> Pool C `Claude Sonnet 5.5 high` -> Pool D `DeepSeek-V4-Pro`**) + Stage-0 DeepSeek precheck + `R2` Cross-Model Review Gate + live API verification. Primary native Pool A fallback: **`Gemini 4 Neon High`** (`65.2%` Terminal-Bench 4.1, `-25%` cost vs Carbon) or **`Gemini 4 Hydrogen High`** / `Carbon Medium` if `frontier-orchestrate.sh` exits `2`.
- **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA (`Carbon High` / `Neon XHigh` / `Hydrogen XHigh` / `Argon High` + `codex-rca.sh` / `frontier-orchestrate.sh --tier deep`)**:
  - Deep RCA & surgical patch design via **`codex-rca.sh`** or **`frontier-orchestrate.sh --tier deep`** (cascading **Pool B `Codex gpt-6-astra xhigh / sol` -> Pool C `Claude Opus 5.5 high / sonnet` -> Pool D `DeepSeek-V4-Pro`**), falling back to `Model: "pro"` (`Gemini 4 Carbon High` with `DEEP ANALYTICAL HIGH` reasoning mandate, **`Gemini 4 Neon xhigh`** with `0.0%` shortcut rate for complex multi-file SWE & refactoring, `Gemini 4 Hydrogen xhigh` for rapid iterative debugging, or `Gemini 4 Argon High`), followed by `R3` Cross-Model Review Gate + dedicated Post-Commit Security Reviewer.
- **Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`)**: Executes QA/Regression/Docs/Vault/Skills/Review gates (`agy-gatekeeper.service`), stages explicit files, commits, and synchronizes security review.

## 4. Mandatory Transparency Rule (Greek)
Whenever delegating to ANY subagent, `swarm` worker, or external CLI, ALWAYS inform the user in Greek with:
1. Role / purpose,
2. Exact model name (`Gemini 4 Hydrogen`, `Gemini 4 Neon`, `Gemini 4 Carbon`, `Gemini 4 Argon`, `Gemini 3.8 Flash` when used for `browser`/bulk I/O, `Claude Sonnet 5.5`, `Claude Opus 5.5`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6.1-terra`, `deepseek-v4-pro`),
3. Exact thinking / effort level (`Low`, `Flash I/O`, `Medium`, `High`, `XHigh` / `xhigh`).

## 5. One-Time CLI Credential Setup
- **Claude Pro/Max**: `claude login`
- **DeepSeek API**: Configure `DEEPSEEK_API_KEY="sk-..."` in `~/.config/llm-council/secrets.env` (`chmod 600`)
- **Codex CLI**: `codex login`

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (`Gemini 4 Carbon`, `Gemini 4 Neon`, `Gemini 4 Hydrogen`, `Gemini 4 Argon` ΚΑΙ `Gemini 3.8 Flash`, συμπεριλαμβανομένων `Orchestrator (Carbon/Neon/Argon)` — όλα μοιράζονται το ίδιο quota pool)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` ή Gemini `swarm` workers (συμπεριλαμβανομένων `Gemini 4 Neon`, `Gemini 4 Hydrogen` & `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 4 Hydrogen Low` & `3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` -> **Pool D (`deepseek/deepseek-flash` / `deepseek-v4-pro`)** -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Hydrogen Medium`, `Neon Low/Medium` & `Carbon Medium` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Hydrogen High`, `Neon High` & `Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` / `Neon XHigh` / `Argon High` / `Hydrogen XHigh`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / sonnet`)** -> **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

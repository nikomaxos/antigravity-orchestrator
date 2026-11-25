---
name: multi-model-delegation
description: >-
  Use this skill on every non-trivial task to route exploration, coding, RCA,
  review, and security checks across Pool 0 Linux Offload Bots, the 5 Task Tiers
  (T0-T4), and the 3 Active Automated Pools (Antigravity + Plus, OpenAI Codex CLI,
  Anthropic Claude Code CLI) while keeping Pool D (DeepSeek) strictly manual-only
  and preserving Thin-Orchestrator context hygiene (<120K-160K tokens).
---
# Multi-Model & Multi-CLI Delegation Skill (5-Tier / Pool 0 + 3 Automated Pools)

## 1. Core Invariants (`schema_version: 2026.11.7` · Antigravity Desktop `v2.35.1`)
1. **Default Orchestrators (`Orchestrator (Carbon -> Hydrogen)` & `Orchestrator (Neon -> Hydrogen)`)**: Antigravity Desktop `v2.35+` starts Orchestrator & Executor models at **`High`** thinking effort by default (instead of XHigh). Planning turns stay pure & thin (`<35K–60K` tokens), while `exit_plan_mode` hands execution to **`Gemini 4 Hydrogen`** (`19%` faster, `~24%` less quota). Active conversations auto-resume after app restart (`v2.35.1`), but stopped background subagents/tasks must be re-checked on wakeup.
2. **`Gemini 4 Neon` bridges `Hydrogen` speed and `Carbon` depth**: **`Gemini 4 Neon`** scores **65.2%** on Terminal-Bench 4.1 (`#2` Agent Arena & Steerability, `0.0%` shortcut rate, `39.0%` SWE-sweep) at `-25%` cost vs Carbon — primary Pool A escalation target for **`T3` backend/refactoring (`High`)**, **`T2` UI state (`Low/Medium`)**, and **`T4` multi-file SWE (`XHigh`)**.
3. **`Gemini 4 Hydrogen` replaces `Gemini 3.8 Flash` across ALL execution, coding, triage, live-ops/pre-flight & gates**: Up to `2.5x` faster, `57.0%` vs `18.2%` Terminal-Bench 4.1, `>5x` fewer hallucinations. **`Gemini 3.8 Flash` (`Model="flash"`) is restricted STRICTLY to the `browser` subagent only** (FORBIDDEN for `T1`, live-ops/production pre-flight, API/DB/GSM/SMPP/modem/bitmask queries, worker checks, scripts, or log scans).
4. **Orchestrator Step-0 Pre-Flight & No `Model: "flash"` Downgrade**: During `Orchestrator` planning turns, NEVER spawn `invoke_subagent(Model="flash")` for pre-flight — transition directly via `exit_plan_mode` into **`Gemini 4 Hydrogen`** with **Step 0: Read-Only Pre-Flight Check** and a strict **`Re-plan if:`** guard.
5. **Rules Budget & Unlimited History (`v2.35.0`)**: Global/workspace rules share a `20,000`-token `defaultRulesBudget` (`24 KB`/file cap) — keep `~/.gemini/config/AGENTS.md` canonical and `GEMINI.md` as a compact pointer. Local history is unlimited by default (`gemini-budget.js` pre-filters by directory + 8d mtime). Use `conversations` skill only for out-of-band conversation automation; use `invoke_subagent`/`swarm` inside active turns.
6. **Single Writer & Manual-Only DeepSeek**: Antigravity (Pool A) is the SINGLE WRITER; `codex` & `claude` run strictly read-only. **Pool D (`OpenCode / DeepSeek`) is STRICTLY MANUAL-ONLY (`/opencode`)** and must NEVER be invoked automatically.

## 2. Pool 0 + 3 Active Automated Pools (+ Pool A+ Bundle & Manual-Only Pool D)

| Pool | Provider & Mode | Binaries / Wrappers | Model Matrix & Strengths |
|------|-----------------|---------------------|--------------------------|
| **Pool 0** | **Local Linux Automation** (`0` LLM tokens, DevBox Staging only) | `.agents/scripts/bots/{ops-preflight,staging-deploy-verify,release-pack-sync}.mjs` & `/antigravity-fleet` **Offload Bots & Config** tab | **Invoke FIRST before `T1`/`T2`**: `ops-preflight.mjs` (`~18K` saved), `staging-deploy-verify.mjs` (`~25K` saved), `release-pack-sync.mjs` (`~15K` saved). Never bypasses `ma-gatekeeper`. |
| **Pool A** | **Antigravity Native** (Subscription — shared Gemini bucket) | `Orchestrator (Carbon/Neon/Argon)` + `swarm` (`gemini-4-hydrogen-*`, `gemini-4-neon-*`, channels/`fork`/quota-aware `model` switch) + `invoke_subagent` (`"inherit"`, `"pro"`, `"flash"` STRICTLY `browser`-only) | **Single Writer**: `Orchestrator (Carbon/Neon -> Hydrogen)` (`T0`), `Gemini 4 Hydrogen Low/Med` (`T1` Explorer/Live-Ops/Gatekeeper), `Hydrogen Med` / `Neon Low|Med` (`T2`), **`Neon High` / `Hydrogen High`** (`T3`), `Carbon High` / **`Neon XHigh`** / `Hydrogen XHigh` / `Argon High` (`T4`), `Gemini 3.8 Flash` (**STRICTLY `browser` only**) |
| **Pool A+** | **Antigravity Plus Credit Bundle** | Antigravity UI Dropdown Model Switch | `Claude Sonnet 5.5` (`low`/`medium`/`high`), `Claude Opus 5.5` (`high`), `gpt-oss-120b-medium` |
| **Pool B** | **OpenAI Codex CLI** (Automated — ChatGPT Plus) | `codex-orchestrate.sh`, `codex-rca.sh`, `run-codex-review-gate.sh` | Primary `R1`/`R2` Review (`gpt-6.1-terra med`, `gpt-6.1-sol high`) & `R3` Failover (`gpt-6-astra high`), `t1_reserve`: `gpt-6-luna low`, Deep RCA: `gpt-6-astra xhigh`, Fixed Read-Only `codex -s read-only -C ... exec resume` |
| **Pool C** | **Anthropic Claude Code CLI** (Automated — Claude Pro/Max) | `claude-orchestrate.sh`, `run-codex-review-gate.sh`, `codex-lib.sh` | **Primary `R3` Security/Architecture Review (`claude-opus-5-5 high`, bounded `16` turns)**, Surgical UI (`claude-sonnet-5-5 med`), Bounded RCA/T4 (`claude-sonnet-5-5 high`, `16` turns; `--opus` opt-in), `R1`/`R2` Failover, `t1_reserve` (`claude-sonnet-5-5 low`) |
| **Pool D** | **OpenCode + DeepSeek API** (**MANUAL-ONLY — Disabled in Auto Cascades**) | `/opencode`, `opencode-orchestrate.sh`, `stage0-precheck.sh --manual` | **Never auto-invoked.** Runs read-only (`--agent readonly-auditor`) strictly when the user explicitly requests `/opencode` or DeepSeek. |

### 2.1 Pool A+ (Antigravity Plus Native Claude Credits Mode)
- If Pool C (`Claude Code CLI`) hits its 5h rate limit, proactively inform the user in Greek:
  > *"💡 Το εξωτερικό Claude CLI είναι σε rate-limit. Αν θέλεις να αξιοποιήσουμε το Antigravity Plus Claude bundle σου, γύρνα το Dropdown σε Claude Sonnet 5.5 / Opus 5.5"*.
- When the UI Dropdown is on Claude: use `swarm` `gemini-4-hydrogen-low` (`Low`/`Medium`) for `T1` exploration (never `3.8 Flash`, never auto-DeepSeek) and `Model: "inherit"` for `T2`–`T4` edits.

## 3. Pure Zero-Hands-On 5-Tier Task Routing Matrix (`T0` – `T4`)

- **`T0` Orchestrator**: `Orchestrator (Carbon -> Hydrogen)` / `Orchestrator (Neon -> Hydrogen)` (`High` default effort in v2.35+). Pure planning -> `exit_plan_mode` into `Gemini 4 Hydrogen`.
- **`T1` Explorer, Live-Ops Pre-Flight & Docs**: Run **Pool 0 Bots** first when applicable; otherwise **`Gemini 4 Hydrogen Low`** (`swarm` / `inherit`) or **`Medium`** for critical live production GSM/SMPP/bitmask checks. Reserve Mode (`--tier flash`): **Pool C `Claude Sonnet 5.5 low` -> Pool B `Codex gpt-6-luna low`**.
- **`T2` UI, Unit Tests & Standard CRUD**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` (**Pool C `Claude Sonnet 5.5 med` -> Pool B `Codex gpt-6.1-terra med / sol`**), apply & verify via **`Gemini 4 Hydrogen Medium`** / **`Gemini 4 Neon Low|Medium`**.
- **`T3` Multi-Service / Backend / Migrations**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` (**Pool B `Codex gpt-6.1-sol high / astra` -> Pool C `Claude Sonnet 5.5 high`**), fallback **`Gemini 4 Neon High`** / `Hydrogen High`, followed by `R2` Review Gate.
- **`T4` Critical Architecture, Concurrency, Hardware, Security & Deep RCA**: `codex-rca.sh` / `frontier-orchestrate.sh --tier deep` (**Pool B `Codex gpt-6-astra xhigh / sol` -> bounded Pool C `Claude Sonnet 5.5 high` [`--opus` opt-in]**), fallback `Gemini 4 Carbon High` / `Neon XHigh` / `Hydrogen XHigh` / `Argon High`, followed by **`R3` Review Gate (Pool C `Claude Opus 5.5 high` primary -> Pool B `Codex gpt-6-astra high`)**. Shared cooldown cache: `~/.gemini/cache/pool-cooldowns.json`.
- **Release & Gatekeeper Worker (`Gemini 4 Hydrogen Low/Medium`)**: Executes gates, commits explicit files, runs `sync-security-from-review.sh`.

## 4. Mandatory Transparency Rule (Greek)
Whenever delegating to ANY subagent, `swarm` worker, or external CLI, ALWAYS inform the user in Greek with: (1) Role/purpose, (2) Exact model name, (3) Exact thinking/effort level.

## 5. One-Time CLI Credential Setup
- **Codex CLI (Pool B)**: `codex login`
- **Claude CLI (Pool C)**: `claude login`
- **DeepSeek API (Pool D — Optional Manual-Only)**: `DEEPSEEK_API_KEY="sk-..."` in `~/.config/llm-council/secrets.env` (`chmod 600`).

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Limit — Zero-Gemini Pass-Through Mode)
- Κάτω από `10%` (`~/.gemini/config/gemini-quota.json`, αυτόματα από `gemini-budget.js` ή `--set-reserve`): **ΑΠΑΓΟΡΕΥΕΤΑΙ** κάθε `invoke_subagent` ή Gemini `swarm` worker.
- Ο Parent λειτουργεί ως 1-step Pass-Through Router αποκλειστικά σε **Pools B/C** (ΠΟΤΕ αυτόματο DeepSeek):
  - **`T1`**: `--tier flash` -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
  - **`T2`**: `--tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)**.
  - **`T3`**: `--tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)**.
  - **`T4`**: `--tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / Sonnet 5.5 high`)**.
- Επαναφορά: αυτόματα στο `>= 25%` (`auto-meter`) ή `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

# User Preferences

- **Language & Voice**: The user primarily speaks Greek (Ελληνικά) with English (Αγγλικά) as a secondary language. Always respond in Greek when addressed in Greek.
- **Text-to-Speech (TTS) & Notifications**: Always use HD Voice via the local `tts` CLI (`tts "<μήνυμα>"`, default `el-GR-NestorasNeural`, persisted in `~/.config/omarchy/tts.json`).
- **Default Location & Weather**: Προεπιλεγμένη τοποθεσία είναι ο **Κοπανός Ημαθίας** («εδώ βρίσκεσαι»). Όταν ο χρήστης ρωτάει για τον καιρό χωρίς τοποθεσία, απαντάς πάντα για τον Κοπανό Ημαθίας.

# Global Machine-Local Rules (Antigravity `v2.35.1` · `schema_version: 2026.11.7`)

- **ANTIGRAVITY DESKTOP `v2.35.1` ALIGNMENT & RULES BUDGET**:
  - **Rules Budget Hygiene (`24 KB`/file, `20,000` tokens aggregate `defaultRulesBudget`)**: This file (`~/.gemini/config/AGENTS.md`) is the single canonical global rule file; `GEMINI.md` stays a compact pointer so zero global rules are duplicated or evicted.
  - **Default `High` Orchestrator/Executor Effort & Auto-Resume**: Antigravity `v2.35+` starts Orchestrator & Executor models at `High` effort by default and auto-resumes interrupted conversations on restart (stopped background subagents/tasks must still be verified on wakeup).
  - **Unlimited Local History, `conversations` API & Swarm**: History is unlimited by default (`gemini-budget.js` pre-filters by directory & 8d mtime). Use `conversations` skill only for out-of-band conversation management (not subagent turns). Use `swarm` channels/`fork`/`plan.json` Overview/quota-aware `model` switching; `sidecar://` plugin links auto-open in the side panel (`ui-plugin-navigation`).
- **PRECISION QUALITY & QUOTA DISCIPLINE (`Pool 0` + `Pools A/A+, B, C` | `Pool D` DeepSeek Manual-Only)**:
  - **Pool 0 Deterministic Linux Bots (`0` LLM tokens)**: Run workspace `.agents/scripts/bots/*.mjs` first for deterministic health, deploy verification, and bundle/sync checks.
  - **Universal Frontier Orchestrator Defaults**: **`Orchestrator (Carbon -> Hydrogen)`** and **`Orchestrator (Neon -> Hydrogen)`** (`Carbon`/`Neon` plans in thin context -> `exit_plan_mode` executes on **`Gemini 4 Hydrogen`**). Inside an `Orchestrator` execution turn or `Hydrogen` UI mode, execute directly (or with `Model: "inherit"` / `swarm` `gemini-4-hydrogen-*` | `gemini-4-neon-*`) — **NEVER** downgrade to `invoke_subagent(Model="flash")` (`3.8 Flash`). During planning turns, transition via `exit_plan_mode` into `Gemini 4 Hydrogen` with **Step 0: Read-Only Pre-Flight Check** and a strict **`Re-plan if:`** guard. **`Gemini 3.8 Flash` (`Model="flash"`) is permitted STRICTLY for the `browser` subagent only** (FORBIDDEN for `T1` exploration, live-ops/production pre-flight, API/DB/hardware/modem checks, scripts, or log scans).
  - **⛔ DeepSeek / OpenCode (`Pool D`) is STRICTLY MANUAL-ONLY**: NEVER invoke `opencode`, `opencode-orchestrate.sh`, `stage0-precheck.sh`, or `--cli opencode` automatically in any workflow, fallback cascade, review gate, RCA auto-mode, or `<10%` reserve mode. Run DeepSeek **ONLY** when explicitly requested by the user (`/opencode` or manual command, strictly `--agent readonly-auditor`).
  - **External-First Offload (`bash .agents/scripts/frontier-orchestrate.sh --tier <ui|backend|deep|flash>`)**: Protects `Pool A` by routing heavy reasoning & patch design to **Pool B (`Codex`)** and **Pool C (`Claude`)** first, falling back to `Pool A` (`Hydrogen` / `Neon` / `Carbon`) on exit `2`:
    1. **`T1` Explorer / Live-Ops Pre-Flight / Docs**: `Gemini 4 Hydrogen Low` (`swarm` `gemini-4-hydrogen-low` / `inherit`) or `Medium` for critical live production checks (`57%` vs `18.2%` Terminal-Bench, `>5x` fewer hallucinations). Reserve replacement (`--tier flash`): Pool C `Claude Sonnet 5.5 low` -> Pool B `Codex gpt-6-luna low`.
    2. **`T2` UI, Frontend, Tests & CRUD**: `Gemini 4 Hydrogen Medium` / `Gemini 4 Neon Low|Medium` + `--tier ui` (`Claude Sonnet 5.5 med` -> `Codex gpt-6.1-terra med / sol`).
    3. **`T3` Multi-Service, Backend & Migrations**: `Gemini 4 Hydrogen High` / `Gemini 4 Neon High` (`65.2%` Terminal-Bench 4.1, `-25%` vs Carbon) + `--tier backend` (`Codex gpt-6.1-sol high / astra` -> `Claude Sonnet 5.5 high`).
    4. **`T4` Critical Architecture, Concurrency, Protocols, Security & Deep RCA**: `codex-rca.sh` / `--tier deep` (`Codex gpt-6-astra xhigh / sol` -> bounded `Claude Sonnet 5.5 high` [`--opus` opt-in]), fallback `Gemini 4 Carbon High` (`Model: "pro"`), `Gemini 4 Neon XHigh` (`0.0%` shortcut rate), `Hydrogen XHigh`, or `Argon High`. **`R3` Reviews**: Pool C (`Claude Opus 5.5 high`) primary -> Pool B (`Codex gpt-6-astra high`), backed by `~/.gemini/cache/pool-cooldowns.json`.
    5. **Release & Gatekeeper Worker**: `Gemini 4 Hydrogen Low/Medium` executes gates (`agy-gatekeeper.service` on `127.0.0.1:18099`), commits explicit paths, and runs `sync-security-from-review.sh` (spawning independent `Model: "pro"` `Gemini 4 Carbon High` Security Auditor on exit `2`).
- **DYNAMIC ROUTING, SSE FLEET SYNC & CitC/TCB ZERO-BYPASS**:
  - Routing lives in `~/.gemini/config/model-routing.json` (`schema_version: "2026.11.7"`), synced in real time via `agy-sync-daemon` (SSE Push from DevBox `agy-fleet-hub` + `agy-fleet` MCP + `1x Daily` fallback).
  - Turbo CitC (`config.json`: `AGENT_PERMISSION_PRESET_TURBO`, `CASCADE_COMMANDS_AUTO_EXECUTION_EAGER`, `AGENT_SETTING_POLICY_ALLOW`, `allowCascadeAccessGitignoreFiles: true`) + 4-Layer Windows/Linux TCB (`SYSTEM`/`root` `gate.key`, self-healing `hooks.json`, NTFS `(RX)` ACLs + `git` `--no-verify` shim, TAP presubmit CI).
- **SUBAGENT TRANSPARENCY & COMMUNICATION LANGUAGE**: Always communicate with the USER exclusively in **Greek (Ελληνικά)**. Whenever delegating via `invoke_subagent`, `swarm`, or external CLI (`codex`/`claude`/manual `opencode`), ALWAYS state clearly in Greek the role, exact model name, and thinking/effort level.

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Limit — Zero-Gemini Pass-Through Mode)
- **Αυτόματη Ενεργοποίηση (`gemini-budget.js`)**: Το preflight μετρά Gemini tokens σε 5h/7d παράθυρα έναντι `model-routing.json -> gemini_quota_guard` (`200K` fleet hard limit, με προαιρετικό machine-local override στο `~/.gemini/config/model-routing.local.json`). Κάτω από `10%` γράφει `~/.gemini/config/gemini-quota.json` (`source:"auto-meter"`, warn `<30%`, auto-restore `>=25%`). Context > `ctx_hard_limit_tokens` -> ζήτα αμέσως `/compact`.
- **Zero-Gemini Pass-Through (Αποκλειστικά Pools B/C — ΠΟΤΕ αυτόματο DeepSeek)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** κάθε `invoke_subagent` ή Gemini `swarm` worker (`Carbon`/`Neon`/`Hydrogen`/`Argon`/`3.8 Flash`).
  - Ο Parent λειτουργεί ως 1-step Pass-Through Router μέσω `frontier-orchestrate.sh`:
    - **`T1`**: `--tier flash` -> **Pool C (`Claude Sonnet 5.5 low`)** -> **Pool B (`Codex gpt-6-luna / reserve low`)**.
    - **`T2`**: `--tier ui` -> **Pool C (`Claude Sonnet 5.5 med`)** -> **Pool B (`Codex gpt-6.1-terra med / sol`)**.
    - **`T3`**: `--tier backend` -> **Pool B (`Codex gpt-6.1-sol high / astra`)** -> **Pool C (`Claude Sonnet 5.5 high`)**.
    - **`T4`**: `--tier deep` -> **Pool B (`Codex gpt-6-astra xhigh / sol`)** -> **Pool C (`Claude Opus 5.5 high / Sonnet 5.5 high`)**.
  - Χειροκίνητη επαναφορά: `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

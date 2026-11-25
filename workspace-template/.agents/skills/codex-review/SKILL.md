---
name: codex-review
description: >-
  Use this skill for deep debugging / root-cause analysis (delegate to the
  Cross-Model RCA cascade: Codex -> Claude) and before EVERY git commit that
  contains code changes (tiered R1/R2/R3 Multi-CLI Review Gate with stateful
  Codex delta resume, Claude Opus R3 primary, and Carbon/Neon fallback;
  DeepSeek is strictly manual-only).
---
# Cross-Model Review & RCA Skill (Codex + Claude | DeepSeek Manual-Only)

Full rules: `.agents/rules/40-codex-integration.md`. Antigravity is the **SINGLE WRITER**; external CLIs (`Codex`, `Claude Code`) run strictly **READ-ONLY**.
**DeepSeek (`Pool D` / `opencode` / `stage0-precheck.sh`) is MANUAL-ONLY** — NEVER invoke it automatically.

## A. Deep Debugging / Root-Cause Analysis (`codex-rca.sh`)
1. Collect concrete evidence first (logs, failing request, stack trace) into `/tmp/rca-logs.txt` (use Pool 0 bots or a `T1` Explorer on `Gemini 4 Hydrogen Low`; NEVER `Gemini 3.8 Flash` outside `browser`).
2. Run the evidence-first automated Multi-CLI RCA cascade (`Codex gpt-6-astra xhigh` → `Claude claude-sonnet-5-5 high` [bounded `16` turns; `--opus` opt-in] → exit `2`):
   ```bash
   bash .agents/scripts/codex-rca.sh -a /tmp/rca-logs.txt "Περιγραφή συμπτώματος, πότε ξεκίνησε, τι αλλάξαμε"
   ```
3. Announce clearly to the user in Greek which model & effort level is running (e.g. `"Ανάθεση RCA στο Codex (gpt-6-astra, effort xhigh)"` or `"Claude Sonnet 5.5 (effort high)"`).
4. Read `.agent-reports/codex/rca-latest.md` and **verify** every cited `path:line` before coding.
5. Exit `2` (Codex + Claude both rate-limited/unavailable) → spawn **Gemini 4 Carbon** (`High` thinking level) or **Gemini 4 Neon** (`XHigh` thinking level) subagent with the saved `rca-*.prompt.md`.

## B. Mandatory Pre-Commit Gate (`run-codex-review-gate.sh`)
```bash
git add <explicit code paths>                       # NEVER git add -A / . / commit -a!
bash .agents/scripts/run-codex-review-gate.sh       # Auto-tiers R1/R2/R3; R3=Claude Opus 5.5 -> Codex; R1/R2=Codex -> Claude
cat .agent-reports/codex/review-latest.md
```
- **Automatic Tiering & Per-Tier Cascades (`schema_version: 2026.11.7`, zero auto-DeepSeek)**:
  - `R1` (`<60` LOC UI/test/config): `Codex gpt-6.1-terra (med)` → `Claude claude-sonnet-5-5 (med)` → Pool A fallback: `Gemini 4 Hydrogen (Medium)`.
  - `R2` (`<350` LOC standard CRUD/backend): `Codex gpt-6.1-sol (high)` → `Claude claude-sonnet-5-5 (high)` → Pool A fallback: `Gemini 4 Neon (High)`.
  - `R3` (`>=350` LOC or critical concurrency, auth, crypto, security, or enforcement paths): **`Claude claude-opus-5-5 (high)` primary** (`claude-sonnet-5-5 high` fallback, bounded `16` turns) → **`Codex gpt-6-astra (high)`** → Pool A fallback: `Gemini 4 Carbon (High)` / `Gemini 4 Neon (XHigh)` / `Gemini 4 Argon (High)`.
- **Rate-Limit Cooldown Cache**: Shared persistent cache in `~/.gemini/cache/pool-cooldowns.json` (`60s–21600s` clamp) skips cooled-down pools across `run-codex-review-gate.sh`, `codex-rca.sh`, `frontier-orchestrate.sh`, and `preflight.sh` (`⏳`). Override with `AGY_IGNORE_COOLDOWN=1`.
- **Exit 1 (`FAIL`)**: Fix every `CRITICAL`/`HIGH` (and any `OWASP FAIL`), re-stage explicit paths, and re-run `run-codex-review-gate.sh`. On Round 2+, if Round 1 ran on Codex (`R1`/`R2` or `R3` failover), it **automatically resumes** the prior Codex thread (`codex -s read-only -C ... exec resume`) sending only the interdiff; if Round 1 ran on Claude, Round 2 embeds previous blocking findings & interdiff in the prompt!
- **Exit 2 (`SKIPPED_RATE_LIMIT` — ONLY after Codex + Claude are both unavailable/rate-limited)**:
  1. Spawn an internal subagent on **Gemini 4 Carbon** (`High` thinking level) — or **Gemini 4 Neon** (`High`/`XHigh`) / **Gemini 4 Argon** (`High`) matching the tier — announcing exact model + thinking level in Greek.
  2. Have it review `git diff --cached -- . ':(exclude)*.md' ':(exclude).agent-state'` and return JSON conforming to `.agents/scripts/codex-review-schema.json` (including `owasp_checklist` >= 5 items).
  3. Save `.agent-reports/codex/fallback-review.json` with `"reviewer_agent_id": "<subagent_id>"`, `"staged_fingerprint": "<FP printed by gate>"`, `"model": "Gemini 4 Carbon High"`.
  4. Run `bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json`.
- **Exit 3 (`ERROR` / `TIMEOUT` / `INTEGRITY_VIOLATION`)**: Inspect stderr/events logs, fix, and re-run (fallback is NOT unlocked).
- Finally: stage tracked `.agent-state/*.json` files (`git add -u .agent-state/...`), `git commit`, and run `bash .agents/scripts/sync-security-from-review.sh`.

## C. Optional Manual-Only DeepSeek Check (User-Triggered ONLY)
Only when explicitly asked by the user: `bash .agents/scripts/stage0-precheck.sh --manual` or `/opencode`.

## Status & Telemetry
`bash .agents/scripts/run-codex-review-gate.sh --status` · usage log: `.agent-reports/codex/usage.log`

---
name: codex-review
description: >-
  Use this skill for deep debugging / root-cause analysis (delegate to the 4-Pool
  Cross-Model RCA cascade) and before EVERY git commit that contains code changes
  (Stage-0 DeepSeek precheck + tiered R1/R2/R3 Multi-CLI Review Gate with stateful
  Codex delta resume and Claude/DeepSeek/Argon failover).
---
# 4-Pool Cross-Model Review & RCA Skill

Full rules: `.agents/rules/40-codex-integration.md`. Antigravity is the **SINGLE WRITER**; all external CLIs (`Codex`, `Claude Code`, `OpenCode DeepSeek`) run strictly **READ-ONLY**.

## A. Deep Debugging / Root-Cause Analysis (`codex-rca.sh`)
1. Collect concrete evidence first (logs, failing request, stack trace) into `/tmp/rca-logs.txt` (use a `Model: "flash"` Explorer subagent if log slicing >5 files).
2. Run the Multi-CLI RCA cascade (`Codex gpt-6-astra xhigh` → `Claude opus/sonnet high` → `OpenCode deepseek-v4-pro` → exit `2`):
   ```bash
   bash .agents/scripts/codex-rca.sh -a /tmp/rca-logs.txt "Περιγραφή συμπτώματος, πότε ξεκίνησε, τι αλλάξαμε"
   ```
3. Announce clearly to the user in Greek which model & effort level is running (e.g. `"Ανάθεση RCA στο Codex (gpt-6-astra, effort xhigh)"`).
4. Read `.agent-reports/codex/rca-latest.md` and **verify** every cited `path:line` before coding.
5. Exit `2` (all external pools rate-limited/unavailable) → spawn **Gemini 4 Argon** (`High` thinking level) subagent with the saved `rca-*.prompt.md`.

## B. Stage-0 Cheap Pre-Gate Self-Check (Recommended before Staging / Commit Gate)
Before burning Codex/Claude subscription quota on multi-file diffs, run Pool D (`opencode` + `deepseek-v4-pro` / free fallback) on the working tree:
```bash
bash .agents/scripts/stage0-precheck.sh
```
Fix any `CRITICAL`/`HIGH` defects it catches before staging.

## C. Mandatory Pre-Commit Gate (`run-codex-review-gate.sh`)
```bash
git add <explicit code paths>                       # NEVER git add -A / . / commit -a!
bash .agents/scripts/run-codex-review-gate.sh       # Auto-tiers R1 / R2 / R3; cascades Codex -> Claude -> DeepSeek
cat .agent-reports/codex/review-latest.md
```
- **Automatic Tiering**:
  - `R1` (`<60` LOC UI/test/config): `Codex gpt-5.6-terra (med)` → `Claude sonnet (low)` (compact context).
  - `R2` (`<350` LOC standard CRUD/backend): `Codex gpt-6-astra (med)` → `Claude sonnet (high)`.
  - `R3` (`>=350` LOC or critical concurrency, auth, crypto, security, or enforcement paths): `Codex gpt-6-astra (high)` → `Claude opus/sonnet (high)`.
- **Exit 1 (`FAIL`)**: Fix every `CRITICAL`/`HIGH` (and any `OWASP FAIL`), re-stage explicit paths, and re-run `run-codex-review-gate.sh`. On Round 2+, if Round 1 ran on Codex, it **automatically resumes** the prior Codex thread (`codex exec resume`) sending only the interdiff!
- **Exit 2 (`SKIPPED_RATE_LIMIT` — ONLY after Codex + Claude + DeepSeek all unavailable/rate-limited)**:
  1. Spawn an internal subagent on **Gemini 4 Argon** (`High` thinking level), announcing exact model + thinking level in Greek to the user.
  2. Have it review `git diff --cached -- . ':(exclude)*.md' ':(exclude).agent-state'` and return JSON conforming to `.agents/scripts/codex-review-schema.json` (including `owasp_checklist` >= 5 items).
  3. Save `.agent-reports/codex/fallback-review.json` with `"reviewer_agent_id": "<subagent_id>"`, `"staged_fingerprint": "<FP printed by gate>"`, `"model": "Gemini 4 Argon High"`.
  4. Run `bash .agents/scripts/run-codex-review-gate.sh --fallback .agent-reports/codex/fallback-review.json`.
- **Exit 3 (`ERROR` / `TIMEOUT` / `INTEGRITY_VIOLATION`)**: Inspect stderr/events logs, fix, and re-run (fallback is NOT unlocked).
- Finally: `git add .agent-state/codex-review.json` along with the other signed `.agent-state/*.json` files, `git commit`, and run `bash .agents/scripts/sync-security-from-review.sh`.

## Status & Telemetry
`bash .agents/scripts/run-codex-review-gate.sh --status` · usage log: `.agent-reports/codex/usage.log`

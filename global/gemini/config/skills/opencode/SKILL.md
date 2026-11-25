---
name: opencode
description: >-
  MANUAL-ONLY headless Pay-As-You-Go CLI delegation via OpenCode (`opencode run`)
  connected to DeepSeek API (`deepseek/deepseek-v4-pro`, `deepseek/deepseek-flash`,
  plus built-in free fallback). Trigger ONLY when the user explicitly invokes
  `/opencode` or asks for DeepSeek manually — NEVER use automatically in cascades,
  review gates, RCA auto-mode, or reserve pass-through.
---

# OpenCode + DeepSeek CLI Skill (`/opencode` — STRICTLY MANUAL-ONLY)

> [!IMPORTANT]
> **Manual-Only Policy (`schema_version: 2026.11.7`)**: Pool D (OpenCode + DeepSeek) is completely excluded from all automatic orchestration cascades, review gates, RCA auto-mode, and `<10%` reserve mode. Run this skill **ONLY** when the user explicitly triggers `/opencode` or asks for DeepSeek manually.

Loads `DEEPSEEK_API_KEY` from `~/.config/llm-council/secrets.env` (never printed) and runs `opencode` in strict read-only auditor mode (`--agent readonly-auditor`) inside protected workspaces.

## Tiers (`--tier`)
- **`--tier flash`**: `deepseek/deepseek-flash` (fallback: `opencode/deepseek-v4.1-flash-free`)
- **`--tier pro`** *(Default)*: `deepseek/deepseek-v4-pro` (fallback: `opencode/deepseek-v4.1-flash-free`)

## Manual Execution
```bash
bash ~/.gemini/config/skills/opencode/scripts/opencode-orchestrate.sh \
  --tier <flash|pro> \
  -C "<workspace_dir>" <<'EOF'
<Task or prompt>
EOF
```
For an optional manual diff pre-check (never run automatically):
```bash
bash .agents/scripts/stage0-precheck.sh --manual
```
Always announce to the user in Greek the exact OpenCode/DeepSeek model selected.

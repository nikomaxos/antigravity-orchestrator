---
name: opencode
description: >-
  Headless Pay-As-You-Go CLI delegation via OpenCode (`opencode run`) connected to DeepSeek API
  (`deepseek/deepseek-v4-pro`, `deepseek/deepseek-flash`, plus built-in free fallback).
  Use for `/opencode`, Stage-0 cheap pre-checks (~$0.01-$0.02), massive log/repo scans without
  weekly subscription caps, and emergency overflow when Codex & Claude hit rate limits.
---

# OpenCode + DeepSeek CLI Skill (`/opencode`)

Loads `DEEPSEEK_API_KEY` from `~/.config/llm-council/secrets.env` (never printed) and runs `opencode` in strict read-only auditor mode inside protected workspaces.

## Tiers (`--tier`)
- **`--tier flash`** (`T1` bulk log/repo scans): `deepseek/deepseek-flash` (fallback: `opencode/deepseek-v4.1-flash-free`)
- **`--tier pro`** *(Default — Stage-0 code review, deep analysis)*: `deepseek/deepseek-v4-pro` (fallback: `opencode/deepseek-v4.1-flash-free`)

## Execution
```bash
bash ~/.gemini/config/skills/opencode/scripts/opencode-orchestrate.sh \
  --tier <flash|pro> \
  -C "<workspace_dir>" <<'EOF'
<Task or prompt>
EOF
```
Always announce to the user in Greek the exact OpenCode/DeepSeek model selected.

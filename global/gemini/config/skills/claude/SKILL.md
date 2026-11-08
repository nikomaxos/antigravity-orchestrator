---
name: claude
description: >-
  Tier-aware headless delegation to Anthropic Claude Code CLI (`claude -p`).
  Activate when the user types `/claude` or when delegating UI/React surgical planning (`sonnet`),
  second-opinion T4 architecture/RCA (`opus`), or cross-model review. Automatically enforces
  read-only plan mode inside Single-Writer gated workspaces.
---

# Claude Code CLI Delegation Skill (`/claude`)

Invokes Anthropic's official `claude` CLI (`~/.local/bin/claude`, powered by the user's Claude Pro/Max subscription via `claude login`).

## Tier Selection (`--tier`)
- **`--tier fast`** (`T1` lookups): `--model haiku --effort low`
- **`--tier ui` / `--tier backend`** *(Default — `T2`/`T3` Frontend/Backend)*: `--model sonnet --effort medium` (or `high` for `backend`)
- **`--tier deep`** (`T4` critical RCA / concurrency / security): `--model opus --effort high` *(use sparingly on Claude Pro 5h windows!)*

## Execution
```bash
bash ~/.gemini/config/skills/claude/scripts/claude-orchestrate.sh run \
  --tier <fast|ui|backend|deep> \
  -C "<workspace_dir>" <<'EOF'
<Task or prompt>
EOF
```
Always announce to the user in Greek the exact Claude model and effort level used.

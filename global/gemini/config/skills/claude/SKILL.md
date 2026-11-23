---
name: claude
description: >-
  Tier-aware headless delegation to Anthropic Claude Code CLI (`claude -p`).
  Activate when the user types `/claude` or when delegating UI/React surgical planning (`claude-sonnet-5-5`),
  second-opinion T4 architecture/RCA (`claude-opus-5-5`), or cross-model review. Automatically enforces
  read-only plan mode inside Single-Writer gated workspaces.
---

# Claude Code CLI Delegation Skill (`/claude`)

Invokes Anthropic's official `claude` CLI (`~/.local/bin/claude`, powered by the user's Claude Pro/Max subscription via `claude login`).

## Tier Selection (`--tier`)
- **`--tier fast`** (`T1` reserve lookups): `--model claude-sonnet-5-5 --effort low` (`--max-turns 12`, fallback: `sonnet` / `haiku`)
- **`--tier ui`** (`T2` Frontend / UI / Tests): `--model claude-sonnet-5-5 --effort medium` (`--max-turns 12`, fallback: `sonnet`)
- **`--tier backend`** *(Default — `T3` Backend / CRUD / Migrations)*: `--model claude-sonnet-5-5 --effort high` (`--max-turns 20`, fallback: `sonnet`)
- **`--tier deep`** (`T4` critical RCA / concurrency / security): `--model claude-sonnet-5-5 --effort high` (`--max-turns 16`, prevents 3.4M cache_read Opus errors on open-ended sweeps; pass `--opus` opt-in for bounded `claude-opus-5-5` escalation, and bounded `R3` code+security reviews use `claude-opus-5-5 high` primary with `16` turns)

## Execution
```bash
bash ~/.gemini/config/skills/claude/scripts/claude-orchestrate.sh run \
  --tier <fast|ui|backend|deep> [--opus] \
  -C "<workspace_dir>" <<'EOF'
<Task or prompt>
EOF
```
Always announce to the user in Greek the exact Claude model and effort level used.

---
name: codex
description: >-
  Tier-aware pass-through mode using OpenAI Codex CLI (`codex exec` / `codex exec resume`).
  Activate this skill whenever the user types `/codex` or asks to use Codex CLI. Routes UI/simple
  tasks to `--tier ui` (`gpt-6.1-terra medium`, single-agent), standard backend tasks to `--tier backend`
  (`gpt-6.1-sol high`, single-agent), and deep T4 architecture/concurrency tasks to `--tier deep`
  (`gpt-6-astra xhigh`), while enforcing read-only patch/plan mode inside Single-Writer workspaces.
---

# Codex CLI Tier-Aware Delegation Skill (`/codex`)

When this skill is activated (e.g. via `/codex`), Antigravity acts as a **thin tier-aware dispatcher**:

## 1. Select the Right `--tier` (Prevents Quota Burn!)
- **`--tier flash`** (`T1` — reserve exploration, light log scans):
  Runs `gpt-6-luna` (`effort=low`, fallback `gpt-reserve`).
- **`--tier ui`** (`T1`/`T2` — CSS, frontend components, unit tests, small tweaks):
  Runs `gpt-6.1-terra` (`effort=medium`, fallback `gpt-6.1-sol`) with `features.multi_agent=false`.
- **`--tier backend`** *(Default — `T3` standard REST/DTO/Service/CRUD/script tasks)*:
  Runs `gpt-6.1-sol` (`effort=high`, fallback `gpt-6-astra`) with `features.multi_agent=false`.
- **`--tier deep`** (`T4` — concurrency races, distributed systems, protocols, security architecture):
  Runs `gpt-6-astra` (`effort=xhigh`, fallback `gpt-6.1-sol`) with bounded sub-agents allowed (`max 2`).

> **Single-Writer Workspace Protection:** If the target workspace contains `.agents/hooks.json`, `codex-orchestrate.sh` automatically runs in **kernel-enforced `-s read-only` Architect/Patch-Producer mode** so it never violates `protect-enforcement.sh`. Antigravity then applies the proposed patch cleanly and runs the workspace gates!

## 2. How to Execute

### Starting a Task
```bash
bash ~/.gemini/config/skills/codex/scripts/codex-orchestrate.sh run \
  --tier <ui|backend|deep|flash> \
  -C "<workspace_dir>" <<'EOF'
<User's exact request>
EOF
```

### Follow-Up Turns (`resume`)
```bash
bash ~/.gemini/config/skills/codex/scripts/codex-orchestrate.sh resume \
  --tier <ui|backend|deep> \
  -C "<workspace_dir>" <<'EOF'
<User's follow-up instructions>
EOF
```

Always announce to the user in Greek the exact Codex model and effort tier selected (e.g., `Codex (gpt-6.1-terra, effort medium)` or `Codex (gpt-6.1-sol / gpt-6-astra, effort high/xhigh)`).

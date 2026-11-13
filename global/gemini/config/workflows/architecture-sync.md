# Architecture Sync Workflow (`/architecture-sync`)

Manual GitHub pull & multi-model architecture synchronizer.
Detects OS (Linux/macOS vs Windows), pulls latest `antigravity-orchestrator`, syncs `model-routing.json` and scripts, and verifies Gatekeeper health.

## Steps
1. Detect Operating System (`uname -s` or `$env:OS`).
2. Run `agy-arch-sync` with current workspace:
   - Linux: `~/.local/bin/agy-arch-sync --workspace "$PWD"`
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Development\antigravity-orchestrator\bin\agy-arch-sync.ps1" -WorkspacePath "$PWD"`
3. Verify `http://127.0.0.1:18099/api/gatekeeper/health`.
4. Report status to user in Greek.

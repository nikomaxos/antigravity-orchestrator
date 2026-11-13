---
name: architecture-sync
description: >-
  Cross-platform manual GitHub pull and multi-model architecture synchronizer.
  Triggered when the user types /architecture-sync or asks to sync architecture/models.
  Detects whether the operating system is Windows or Linux/macOS, pulls latest
  antigravity-orchestrator changes from GitHub, updates model-routing.json,
  syncs global and workspace scripts/skills, registers workspaces, and verifies
  the root/SYSTEM Gatekeeper daemon health on port 18099.
---

# Architecture Sync Skill (`/architecture-sync`)

Use this skill whenever the user types `/architecture-sync` or asks to synchronize the orchestrator, model routing, global rules, skills, or workspace scripts.

This workflow is **zero-waste** and runs entirely in lightweight **T0 / T1** execution mode.

--------------------------------------------------------------------------------

## Instructions for the Agent

When `/architecture-sync` is triggered, follow these exact steps:

### Step 1: Detect Operating System & Environment
Detect the OS using `<user_information>` or by running a fast detection check:
- **POSIX (Linux / macOS)**: `uname -s` (returns `Linux` or `Darwin`).
- **Windows**: `$env:OS` or `[System.Environment]::OSVersion` (returns `Windows_NT`).

### Step 2: Execute Architecture Synchronization

#### Option A: Linux / macOS
1. Locate the local `antigravity-orchestrator` repository:
   - Primary: `$HOME/Development/antigravity-orchestrator`
   - Fallback: `$HOME/.local/share/antigravity-orchestrator`
   - If not found, clone it:
     ```bash
     git clone https://github.com/nikomaxos/antigravity-orchestrator.git "$HOME/Development/antigravity-orchestrator"
     ```
2. Record current commit:
   ```bash
   OLD_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
   ```
3. Fetch and pull latest `origin/main`:
   ```bash
   git -C "$REPO" pull --ff-only 2>/dev/null || (git -C "$REPO" fetch origin main && git -C "$REPO" merge --ff-only origin/main) || true
   NEW_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "$OLD_SHA")
   ```
4. Run the architecture synchronizer, passing current workspace to register and sync:
   ```bash
   bash "$REPO/bin/agy-arch-sync" --workspace "$PWD"
   ```
5. Check Gatekeeper daemon health:
   ```bash
   curl -s -m 2 http://127.0.0.1:18099/api/gatekeeper/health || true
   ```
6. Check current model routing version:
   ```bash
   jq -r '{schema_version, updated_at}' ~/.gemini/config/model-routing.json 2>/dev/null || cat ~/.gemini/config/model-routing.json
   ```

#### Option B: Windows (PowerShell)
1. Locate the local repository:
   - Primary: `$env:USERPROFILE\Development\antigravity-orchestrator`
   - Fallback: `$env:LOCALAPPDATA\antigravity-orchestrator`
   - If missing, clone via HTTPS:
     ```powershell
     git clone https://github.com/nikomaxos/antigravity-orchestrator.git "$env:USERPROFILE\Development\antigravity-orchestrator"
     ```
2. Record current commit and pull latest `origin/main`.
3. Run PowerShell architecture sync (user-level, no UAC elevation required for normal sync):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$repoDir\bin\agy-arch-sync.ps1" -WorkspacePath "$PWD"
   ```
4. Check Gatekeeper health:
   ```powershell
   Invoke-RestMethod -Uri "http://127.0.0.1:18099/api/gatekeeper/health" -TimeoutSec 2 -ErrorAction SilentlyContinue
   ```
5. Check `$env:USERPROFILE\.gemini\config\model-routing.json`.

---

### Step 3: Return Structured Summary in Greek (Ελληνικά)

Always respond to the user in Greek with a structured status table:

```markdown
### 🔄 Συγχρονισμός Αρχιτεκτονικής Antigravity Ολοκληρώθηκε

| Παράμετρος | Κατάσταση |
|---|---|
| 🖥️ **Λειτουργικό Σύστημα** | `Linux` / `Windows` |
| 🔄 **Έκδοση Orchestrator (Git)** | `<old_sha> -> <new_sha>` (ή `Ήδη ενημερωμένο στο <sha>`) |
| 🎛️ **Μητρώο Μοντέλων** | `schema_version: 2026.11.1` (`updated_at: ...`) |
| 📁 **Συγχρονισμένο Workspace** | `<τρέχον μονοπάτι workspace>` |
| 🛡️ **Gatekeeper Daemon** | `127.0.0.1:18099` (Κατάσταση: `Healthy / Active`) |
| ⏱️ **Χρονική Σήμανση Sync** | `<τρέχουσα ημερομηνία/ώρα>` |
```

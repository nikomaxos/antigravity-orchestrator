# Antigravity Multi-Model Orchestrator & Universal Gatekeeper (`agy-gatekeeper`)

Ένα πλήρες, αυτόνομο και **100% project-agnostic** framework για το **Google Antigravity Desktop**, σχεδιασμένο να αναπαράγεται εύκολα σε οποιοδήποτε Linux ή Windows περιβάλλον και να προστατεύει **οποιοδήποτε Git αποθετήριο** ανεξαρτήτως τεχνολογικού stack (Node/TypeScript, Java/Spring, Python, Go, Rust, Home Assistant κ.α.).

---

## 🏛️ Αρχιτεκτονική: 4 Orthogonal Pools & 5-Tier Task Routing (Νοέμβριος 2026)

Το σύστημα εξασφαλίζει **μηδενικό συμβιβασμό στην ποιότητα (Zero Quality Compromise)** και **αυστηρή προστασία των υπολοίπων (Quota Discipline)**, συνδυάζοντας 4 ανεξάρτητα υπολογιστικά pools με κεντρικό δυναμικό routing μέσω του `~/.gemini/config/model-routing.json`:

| Pool | Πάροχος & Billing | Ρόλος & Μοντέλα | Πλεονεκτήματα & Thinking Level |
|------|-------------------|-----------------|-------------------------------|
| **Pool A** | **Antigravity Native** (Subscription) | **Single Writer**: Pure Parent Dispatcher (`Gemini 4 Carbon Medium`), Parallel Workhorse (`Gemini 4 Hydrogen Med/High/xHigh`), Compliance (`Gemini 4 Argon High`), Fast Explorer (`Gemini 3.8 Flash Low`) | 0 direct tool clutter στον γονέα (<35K tokens context, ~1s latency), native subagents με scalable reasoning |
| **Pool A+** | **Antigravity Plus Credit Bundle** | `claude-sonnet-5-5-{low,med,high}`, `claude-opus-5-5-{low,med,high}`, `gpt-oss-120b-medium` | Ενεργοποιούνται απρόσκοπτα από το UI Dropdown χωρίς να επιβαρύνουν τα standard Gemini limits |
| **Pool B** | **OpenAI Codex CLI** (ChatGPT Plus) | Read-only Patch & RCA Architect (`gpt-6-astra high/xhigh`, `gpt-6.1-sol high/xhigh`, `gpt-6.1-terra med`, `gpt-6-luna low`) | Stateful delta review (`codex exec resume`), deep RCA (`codex-rca.sh`), fast UI (`gpt-6.1-terra`) |
| **Pool C** | **Anthropic Claude Code CLI** (Claude Pro/Max) | Read-only Patch Architect (`claude -p --permission-mode plan`, `claude-sonnet-5-5`, `claude-opus-5-5` με fallback σε `sonnet`/`opus`) | Surgical UI/Frontend design, deep architecture audits, αυτόματο failover όταν το Codex εξαντληθεί |
| **Pool D** | **OpenCode CLI + DeepSeek Official API** (Pennies/Mtok) | Read-only Code Auditor (`deepseek/deepseek-flash`, `deepseek/deepseek-v4-pro`, `opencode/deepseek-v4.1-flash-free`) | Stage-0 pre-checks (<$0.02) πριν από commit gate / staging deploy, απεριόριστο overflow |

### 5-Tier Task Matrix
- **`T0` Triage**: Direct conversational reply (<1s latency).
- **`T1` Fast Explorer (`Model: "flash"` — `Gemini 3.8 Flash Low`)**: Έρευνα αρχείων, ανάγνωση logs, read-only SQL/API ερωτήματα, docs synthesis.
- **`T2` UI / Frontend / Tests (`frontier-orchestrate.sh --tier ui`)**: `Claude Sonnet 5.5` → `Codex gpt-6.1-terra med` → `DeepSeek-V4-Pro`.
- **`T3` Backend / Migrations (`frontier-orchestrate.sh --tier backend`)**: `Codex gpt-6.1-sol high` → `Claude Sonnet 5.5 high` → `DeepSeek-V4-Pro`.
- **`T4` Critical Concurrency / Security / RCA (`frontier-orchestrate.sh --tier deep` / `codex-rca.sh`)**: `Codex gpt-6-astra xhigh` → `Claude Opus 5.5 high` → `DeepSeek-V4-Pro` → Exit `2` (Pool A `Carbon High`).
- **Release & Gatekeeper**: Αυτόματη εκτέλεση και υπογραφή όλων των gates (QA, Regression, Vault, Docs, Skills, Codex Review, Security).

---

## 🎛️ Κεντρικό Μητρώο Μοντέλων (`model-routing.json`)

Όλα τα CLI wrappers (`frontier-orchestrate.sh`, `codex-orchestrate.sh`, `claude-orchestrate.sh`, `opencode-orchestrate.sh`, `codex-rca.sh`, `codex-lib.sh`) διαβάζουν πλέον δυναμικά τα μοντέλα και τα reasoning effort levels από:
1. Περιβαλλοντική μεταβλητή `${MODEL_ROUTING_FILE}`
2. Παγκόσμιο αρχείο: `~/.gemini/config/model-routing.json` (ή `%USERPROFILE%\.gemini\config\model-routing.json` στα Windows)
3. Τοπικό workspace αρχείο: `.agents/config/model-routing.json`
4. Ενσωματωμένες ασφαλείς bash εφεδρείες

Δεν απαιτείται ποτέ hardcoding ονομάτων μοντέλων στα shell scripts: οποιαδήποτε αναβάθμιση έκδοσης μοντέλου διαχέεται άμεσα σε όλα τα workspaces μέσω του `agy-arch-sync`.

---

## 🏢 Google CitC/TAP/TCB Zero-Popup & 4-Layer Zero-Bypass Architecture

Σχεδιασμένο σύμφωνα με τα εσωτερικά πρότυπα της Google (CitC - Clients in the Cloud, TAP - Test Automation Platform, TCB - Trusted Computing Base), το σύστημα εξαλείφει 100% τα ενοχλητικά παράθυρα επιβεβαίωσης πρόσβασης αρχείων (Zero-Popup Velocity) ενώ ταυτόχρονα καθιστά μαθηματικά αδύνατη οποιαδήποτε παράκαμψη κανόνων (`< 1 in 10^9` bypass probability):

### 1. Zero Manual File-Access Prompts (`Turbo CitC Velocity`)
- **Αυτόματη ρύθμιση `config.json`**:
  ```json
  "userSettings": {
    "nonWorkspaceFileAccessPolicy": "AGENT_SETTING_POLICY_ALLOW",
    "allowCascadeAccessGitignoreFiles": true,
    "autoExecutionPolicy": "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER",
    "permissionPreset": "AGENT_PERMISSION_PRESET_TURBO",
    "enableTerminalSandbox": false
  }
  ```
- **Windows Workspace Trust & OneDrive Reparse Support**:
  Αυτόματη ρύθμιση `%APPDATA%\Antigravity\User\settings.json` με `"security.workspace.trust.enabled": false` και ανάλυση OneDrive reparse point symlinks (`(Get-Item $Path).Target`), επιτρέποντας απρόσκοπτη λειτουργία σε φακέλους όπως `C:\Users\parda\OneDrive\Dev\ha` χωρίς διακοπές.

### 2. 4-Layer Zero-Bypass Enforcement
- **Layer 1: Privileged `NT AUTHORITY\SYSTEM` (Windows) / `root` (Linux) TCB Daemon**:
  - Στα Windows, το daemon εγκαθίσταται στο `C:\ProgramData\agy-gatekeeper\` και εκτελείται ως Scheduled Task με Highest Privileges υπό το `NT AUTHORITY\SYSTEM`.
  - Το μυστικό κλειδί υπογραφής HMAC (`gate.key`) κλειδώνεται με `icacls` αποκλειστικά για `SYSTEM:(F)` και `BUILTIN\Administrators:(F)`. Ο τρέχων standard user και το Antigravity agent λαμβάνουν `ACCESS_DENIED`.
  - Στο Linux, το κλειδί φυλάσσεται στο `/etc/ma-gatekeeper/gate.key` με δικαιώματα `0600 root:root`.
- **Layer 2: TCB Self-Healing Integrity Check**:
  - Πριν από κάθε υπογραφή ή επαλήθευση gate, το `gatekeeper/server.js` ελέγχει την ακεραιότητα του `.agents/hooks.json` και του `.git/hooks/pre-commit`.
  - Εάν εντοπιστεί τροποποίηση ή διαγραφή, απορρίπτει το αίτημα με `403 TAMPER_DETECTED` και επαναφέρει αυτόματα τα αυθεντικά αρχεία από το προστατευμένο template repository (`/etc/agy-gatekeeper/template` ή `C:\ProgramData\agy-gatekeeper\template`).
- **Layer 3: Filesystem ACL Lock & Git Command Shim**:
  - Στα Windows, το `agy-init-workspace.ps1` εφαρμόζει `icacls` Read+Execute (`(RX)`) στον standard χρήστη για όλα τα critical hooks και scripts, εμποδίζοντας οποιαδήποτε διαγραφή ή εγγραφή από το agent.
  - Ειδικό shim (`gatekeeper/shim/git.cmd` και `shim/git`) τοποθετείται στην αρχή του `PATH` και απορρίπτει άμεσα εντολές που περιέχουν `--no-verify`, `-n` σε commit, ή παράκαμψη μέσω `core.hooksPath`.
- **Layer 4: Google TAP Remote Presubmit CI**:
  - Το GitHub Actions workflow `.github/workflows/agy-gatekeeper-presubmit.yml` επαληθεύει την αυθεντικότητα όλων των υπογεγραμμένων gates σε κάθε push και Pull Request.

---

## 🚀 Εγκατάσταση σε Windows (Lenovo Laptop / PowerShell)

Για το laptop με Windows (π.χ. Lenovo με Home Assistant workspace στο `C:\Users\parda\OneDrive\Dev\ha`):

### 1. Κλωνοποίηση ή Αποσυμπίεση του Bundle
Ανοίξτε **PowerShell** (ή Windows Terminal):
```powershell
# Αν χρησιμοποιείτε git (Δημόσιο repo - δεν απαιτείται SSH key ή login):
git clone https://github.com/nikomaxos/antigravity-orchestrator.git $HOME\Development\antigravity-orchestrator
cd $HOME\Development\antigravity-orchestrator

# Ή αν μεταφέρατε το antigravity-orchestrator-bundle.tar.gz:
# tar -xzf antigravity-orchestrator-bundle.tar.gz -C $HOME\Development\antigravity-orchestrator
# cd $HOME\Development\antigravity-orchestrator
```

### 2. Εκτέλεση του PowerShell Installer (`install.ps1`)
Εκτελέστε σε **Elevated PowerShell** (Run as Administrator):
```powershell
.\install.ps1
```
> [!NOTE]
> Το `install.ps1` εκτελεί αυτόματα:
> 1. Έλεγχο και αναβάθμιση των `codex`, `claude`, `opencode` CLIs.
> 2. Εγκατάσταση του παγκόσμιου `model-routing.json`, `AGENTS.md`, `GEMINI.md` και skills στο `%USERPROFILE%\.gemini\config\`.
> 3. Ρύθμιση Turbo CitC (`scripts/configure-antigravity-turbo.ps1`).
> 4. Εγκατάσταση του `AgyGatekeeper` στο `C:\ProgramData\agy-gatekeeper\` ως SYSTEM Scheduled Task.
> 5. Εγκατάσταση του Windows `git.cmd` shim για αποτροπή του `--no-verify`.
> 6. Ρύθμιση προγραμματισμένης εργασίας Auto-Sync κάθε 30 λεπτά (`AgyOrchestratorAutoSync`).
> 7. Αρχικοποίηση του workspace του Home Assistant (`C:\Users\parda\OneDrive\Dev\ha`) διατηρώντας ακέραια τα credentials.

---

## 🚀 Εγκατάσταση σε Linux / Git Bash

### Βήμα 1: Κλωνοποίηση ή Αποσυμπίεση του Bundle
```bash
# Αν έχετε το bundle tar.gz:
mkdir -p ~/Development/antigravity-orchestrator
tar -xzf antigravity-orchestrator-bundle.tar.gz -C ~/Development/antigravity-orchestrator
cd ~/Development/antigravity-orchestrator

# Ή μέσω git:
git clone git@github.com:nikomaxos/antigravity-orchestrator.git ~/Development/antigravity-orchestrator
cd ~/Development/antigravity-orchestrator
```

### Βήμα 2: Εκτέλεση του Installer
```bash
./install.sh --with-gatekeeper
```
Ο installer:
1. Εγκαθιστά το κεντρικό `model-routing.json` και τους παγκόσμιους κανόνες στο `~/.gemini/config/`.
2. Εγκαθιστά τα παγκόσμια skills (`claude`, `codex`, `opencode`, `multi-model-delegation`, `codex-review`) στο `~/.gemini/config/skills/`.
3. Ρυθμίζει το Turbo CitC profile στο `~/.gemini/config/config.json`.
4. Εγκαθιστά τα βοηθητικά εργαλεία στο `~/.local/bin/` (`agy-init-workspace`, `agy-arch-sync`, `frontier-orchestrate`, `agy-setup-clis`).
5. Εγκαθιστά και ενεργοποιεί το `systemd --user` timer `agy-orchestrator-sync.timer` για αυτόματο συγχρονισμό κάθε 30 λεπτά.
6. Εγκαθιστά και εκκινεί την root υπηρεσία `ma-gatekeeper` στο port `18099`.

---

## 🔐 Ρύθμιση Πιστοποιητικών Εξωτερικών CLIs

Εκτελέστε τον οδηγό πιστοποίησης:
```bash
agy-setup-clis --auth
```
- **Pool B (Codex)**: Εκτελεί `codex login` για σύνδεση με ChatGPT Plus.
- **Pool C (Claude)**: Εκτελεί `claude login` για σύνδεση με Claude Pro/Max.
- **Pool D (DeepSeek)**: Αποθηκεύει το `DEEPSEEK_API_KEY` στο `~/.config/llm-council/secrets.env` (δικαιώματα `0600`).

### Έλεγχος Λειτουργίας (Smoke Test)
```bash
agy-setup-clis --test
```

---

## 🛠️ Αρχικοποίηση Οποιουδήποτε Project (`agy-init-workspace`)

Για να προστατεύσετε οποιοδήποτε project με τα hard gates του Antigravity Gatekeeper:
```bash
cd /path/to/my-project
agy-init-workspace
```
Ή στα Windows:
```powershell
agy-init-workspace.ps1 -WorkspacePath "C:\path\to\my-project"
```

Αυτό θα δημιουργήσει:
- `.agents/hooks.json`: Lifecycle PreToolUse hooks (`commit-gate`, `protect-enforcement`, `qa-stop-gate`, `preflight-context`).
- `.agents/config/model-routing.json`: Τοπικό αντίγραφο του κεντρικού μητρώου μοντέλων.
- `.agents/scripts/`: Όλα τα εργαλεία ελέγχου και signing gates (`frontier-orchestrate.sh`, `stage0-precheck.sh`, `run-*-gate.sh`).
- `.agents/rules/`: Κανόνες `00-agent-contract.md` και `40-codex-integration.md`.
- `.git/hooks/pre-commit` & `.git/hooks/post-commit`: Εγγενή Git hooks που αποτρέπουν commits χωρίς ψηφιακή υπογραφή HMAC.
- `.agent-state/`: Κατάσταση όλων των gates (`qa.json`, `regression.json`, `vault.json`, `docs.json`, `skills.json`, `codex-review.json`).

---

## 🔄 Αυτόματος Συγχρονισμός Ενημερώσεων (`agy-arch-sync`)

Όποτε γίνονται βελτιώσεις στον orchestrator, στα μοντέλα ή στους κανόνες:
```bash
agy-arch-sync
```
Ή στα Windows:
```powershell
.\bin\agy-arch-sync.ps1
```

Εκτελείται αυτόματα κάθε 30 λεπτά μέσω του OS Scheduler (`systemd` timer στο Linux, Scheduled Task στα Windows) και πριν από κάθε build/commit μέσω του preflight check, διασφαλίζοντας ότι όλα τα καταχωρημένα workspaces στο `orchestrator-workspaces.json` διατηρούν τα πιο πρόσφατα scripts και configurations.

---

## ⚡ Χειροκίνητος Συγχρονισμός μέσω Slash Command (`/architecture-sync`)

Όποτε επιθυμείτε άμεσο χειροκίνητο συγχρονισμό χωρίς αναμονή του 30-λεπτου scheduler:
1. **Μέσω Antigravity UI**: Πληκτρολογήστε απλά **`/architecture-sync`** στο chat box.
2. **Μέσω Terminal (Linux / Git Bash)**:
   ```bash
   architecture-sync
   ```
3. **Μέσω Terminal (Windows PowerShell / CMD)**:
   ```powershell
   architecture-sync.ps1
   # ή από CMD: architecture-sync.cmd
   ```

Το `/architecture-sync`:
- Εντοπίζει **αυτόματα** το λειτουργικό σύστημα (`Linux` vs `Windows`).
- Εκτελεί ασφαλές `git pull --ff-only origin main` στο τοπικό αποθετήριο `antigravity-orchestrator`.
- Ενημερώνει άμεσα το παγκόσμιο `model-routing.json`, κανόνες και skills στο `%USERPROFILE%/.gemini/config` ή `~/.gemini/config`.
- Καταχωρεί και συγχρονίζει το ενεργό workspace στο `orchestrator-workspaces.json`.
- Ελέγχει την κατάσταση του Gatekeeper Daemon (`127.0.0.1:18099`).
- Επιστρέφει πλήρη αναφορά στα Ελληνικά με τη μετάβαση εκδόσεων Git και την έκδοση του μητρώου μοντέλων.

---

## 📁 Δομή Αποθετηρίου

```text
antigravity-orchestrator/
├── README.md                          # Αυτό το αρχείο τεκμηρίωσης
├── install.sh                         # Κεντρικός εγκαταστάτης (Linux / Git Bash)
├── install.ps1                        # Κεντρικός εγκαταστάτης (Windows PowerShell)
├── bin/
│   ├── architecture-sync              # Χειροκίνητο CLI sync (Bash)
│   ├── architecture-sync.ps1          # Χειροκίνητο CLI sync (PowerShell)
│   ├── architecture-sync.cmd          # Χειροκίνητο CLI sync (CMD wrapper)
│   ├── agy-init-workspace             # Αρχικοποίηση νέου project με hard gates (Bash)
│   ├── agy-init-workspace.ps1         # Αρχικοποίηση νέου project με hard gates (PowerShell)
│   ├── agy-arch-sync                  # Συγχρονισμός και διανομή σε workspaces (Bash)
│   ├── agy-arch-sync.ps1              # Συγχρονισμός και διανομή σε workspaces (PowerShell)
│   ├── frontier-orchestrate           # Παγκόσμιο CLI frontier routing (Bash)
│   ├── frontier-orchestrate.ps1       # Παγκόσμιο CLI frontier routing (PowerShell)
│   └── agy-setup-clis                 # Εγκατάσταση, auth & smoke-test των CLIs
├── gatekeeper/
│   ├── server.js                      # Root Gatekeeper HTTP Daemon με Self-Healing (Node.js)
│   ├── agy-gatekeeper.service         # Systemd service unit (Linux)
│   ├── install-gatekeeper.sh          # Εγκατάσταση του daemon στο Linux
│   ├── template/
│   │   └── hooks.json                 # Χρυσό template για self-healing
│   └── shim/
│       ├── git                        # Linux/Git-Bash shim αποτροπής --no-verify
│       └── git.cmd                    # Windows CMD/Batch shim αποτροπής --no-verify
├── scripts/
│   ├── configure-antigravity-turbo.sh # Ρύθμιση Turbo CitC για Linux
│   └── configure-antigravity-turbo.ps1# Ρύθμιση Turbo CitC για Windows
├── global/
│   ├── gemini/config/
│   │   ├── model-routing.json         # Κεντρικό μητρώο μοντέλων Νοεμβρίου 2026
│   │   ├── AGENTS.md                  # Παγκόσμιοι κανόνες μηχανήματος
│   │   ├── GEMINI.md                  # Global Gemini κανόνες
│   │   ├── skills/                    # Global skills (architecture-sync, claude, codex, opencode, review)
│   │   └── workflows/                 # Global workflows (architecture-sync fallback)
│   └── opencode/
│       └── opencode.json              # Generic OpenCode readonly configuration
└── workspace-template/
    ├── AGENTS.md                      # Template κανόνων για κάθε project
    ├── .github/workflows/
    │   └── agy-gatekeeper-presubmit.yml # Layer 4 Presubmit CI check
    └── .agents/
        ├── PROJECT_KNOWLEDGE.md       # Knowledge vault template
        ├── config/
        │   └── model-routing.json     # Dynamic model routing copy
        ├── hooks.json                 # Antigravity tool hooks
        ├── rules/                     # Completion contract & 4-pool council rules
        ├── scripts/                   # Όλα τα gate scripts & frontier wrappers
        ├── skills/                    # Multi-model delegation, codex review & architecture-sync skills
        └── workflows/                 # Architecture sync workflow template
```

---

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (συμπεριλαμβανομένου του `Gemini 3.8 Flash`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` (ακόμη και με `Model: "flash"` / `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` → **Pool D (`deepseek/deepseek-v4-pro` / `deepseek-flash`)** → **Pool C (`Claude Sonnet 5.5 low`)** → **Pool B (`Codex gpt-6-luna`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Carbon Medium` & `3.8 Flash` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` → **Pool C (`Claude Sonnet 5.5 med`)** → **Pool B (`Codex gpt-6.1-terra medium`)** → **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` → **Pool B (`Codex gpt-6.1-sol high`)** → **Pool C (`Claude Sonnet 5.5 high`)** → **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` Deep/Concurrency/Security)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` → **Pool B (`Codex gpt-6-astra xhigh`)** → **Pool C (`Claude Opus 5.5 high`)** → **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

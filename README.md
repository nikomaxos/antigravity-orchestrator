# Antigravity Multi-Model Orchestrator & Universal Gatekeeper (`agy-gatekeeper`)

Ένα πλήρες, αυτόνομο και **100% project-agnostic** framework για το **Google Antigravity Desktop**, σχεδιασμένο να αναπαράγεται εύκολα σε οποιοδήποτε Linux μηχάνημα και να προστατεύει **οποιοδήποτε Git αποθετήριο** ανεξαρτήτως τεχνολογικού stack (Node/TypeScript, Java/Spring, Python, Go, Rust κ.α.).

---

## 🏛️ Αρχιτεκτονική: 4 Orthogonal Pools & 5-Tier Task Routing

Το σύστημα εξασφαλίζει **μηδενικό συμβιβασμό στην ποιότητα (Zero Quality Compromise)** και **αυστηρή προστασία των υπολοίπων (Quota Discipline)**, συνδυάζοντας 4 ανεξάρτητα υπολογιστικά pools:

| Pool | Πάροχος & Billing | Ρόλος & Μοντέλα | Πλεονεκτήματα |
|------|-------------------|-----------------|---------------|
| **Pool A** | **Antigravity Native** (Subscription) | **Single Writer**: Pure Parent Dispatcher (`Gemini 4 Carbon Medium`), `T1` Explorer (`Gemini 3.8 Flash`), `T4` Subagent (`Carbon High`) | 0 direct tool clutter στον γονέα (<35K tokens context, ~1s latency) |
| **Pool A+** | **Antigravity Plus Claude Credits** | Claude Sonnet / Opus ενεργοποιημένα στο UI Dropdown | Αυτόματη μεταγωγή coding subagents σε native Claude |
| **Pool B** | **OpenAI Codex CLI** (ChatGPT Plus) | Read-only Patch & RCA Architect (`gpt-6-astra high/xhigh`, `gpt-5.6-terra med`) | Stateful delta review (`codex exec resume`), deep RCA (`codex-rca.sh`) |
| **Pool C** | **Anthropic Claude Code CLI** (Claude Pro) | Read-only Patch Architect (`claude -p --permission-mode plan`, `sonnet`, `opus`) | Surgical UI/Frontend design, auto-failover όταν το Codex εξαντληθεί |
| **Pool D** | **OpenCode CLI + DeepSeek API** (Pennies/Mtok) | Read-only Code Auditor (`deepseek/deepseek-v4-pro`, `deepseek-flash`) | Stage-0 pre-checks (<$0.02) πριν από commit gate / staging deploy |

### 5-Tier Task Matrix
- **`T0` Triage**: Direct conversational reply (<1s latency).
- **`T1` Fast Explorer (`Model: "flash"` — `Gemini 3.8 Flash`)**: Έρευνα αρχείων, ανάγνωση logs, read-only SQL/API ερωτήματα, docs synthesis.
- **`T2` UI / Frontend / Tests (`frontier-orchestrate.sh --tier ui`)**: `Claude Sonnet 4.6` → `Codex gpt-5.6-terra med` → `DeepSeek-V4-Pro`.
- **`T3` Backend / Migrations (`frontier-orchestrate.sh --tier backend`)**: `Codex gpt-6-astra high` → `Claude Sonnet 4.6` → `DeepSeek-V4-Pro`.
- **`T4` Critical Concurrency / Security / RCA (`frontier-orchestrate.sh --tier deep` / `codex-rca.sh`)**: `Codex gpt-6-astra xhigh` → `Claude Opus 4.6 high` → `DeepSeek-V4-Pro` → Exit `2` (Pool A `Carbon High`).
- **Release & Gatekeeper**: Αυτόματη εκτέλεση και υπογραφή όλων των gates.

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
```powershell
.\install.ps1
```
> [!NOTE]
> Το `install.ps1` εντοπίζει **αυτόματα** το workspace του Home Assistant στο `C:\Users\parda\OneDrive\Dev\ha` (ή μπορείτε να περάσετε `-WorkspacePath "C:\Users\parda\OneDrive\Dev\ha"`).
> - **ΔΕΝ αντικαθιστά ούτε διαγράφει** υπάρχοντες κανόνες στο `.agents/rules/` — διατηρεί ακέραιο το `ha_credentials.md`!
> - Προσθέτει αυτόματα `.agents/rules/*credentials*.md` στο `.gitignore` ώστε να μην διαρρεύσουν ποτέ κωδικοί.
> - Δημιουργεί εξειδικευμένο `PROJECT_KNOWLEDGE.md` με αναφορές στο Home Assistant (Oraiokastro), `repo/antigravity_brain`, `antigravity_addon`, `antigravity_component` και `ha_credentials.md`.
> - Εγκαθιστά και εκκινεί το `AgyGatekeeper` background daemon στο `127.0.0.1:18099` (με αυτόματη εκκίνηση στο logon).

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
1. Εγκαθιστά τους παγκόσμιους κανόνες στο `~/.gemini/config/AGENTS.md` και `~/.gemini/config/GEMINI.md`.
2. Εγκαθιστά τα παγκόσμια skills (`claude`, `codex`, `opencode`, `multi-model-delegation`, `codex-review`) στο `~/.gemini/config/skills/`.
3. Ρυθμίζει το προφίλ `readonly-auditor` στο `~/.config/opencode/opencode.json` (και `%APPDATA%\opencode\opencode.json` στα Windows).
4. Εγκαθιστά τα βοηθητικά εργαλεία στο `~/.local/bin/` (`agy-init-workspace`, `agy-init-workspace.ps1`, `agy-arch-sync`, `frontier-orchestrate`, `frontier-orchestrate.ps1`, `agy-setup-clis`).
5. Εγκαθιστά τα external CLIs (`codex`, `claude`, `opencode`).
6. Εγκαθιστά και ενεργοποιεί την υπηρεσία `agy-gatekeeper` στο port `18099`.

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
Τυπώνει έναν πίνακα κατάστασης για όλα τα pools:
```text
==========================================================
  Pool B (OpenAI Codex CLI):       ✓ OK (Authenticated & Ready)
  Pool C (Anthropic Claude Code):  ✓ OK (Authenticated & Ready)
  Pool D (OpenCode DeepSeek API):  ✓ OK (DEEPSEEK_API_KEY configured)
==========================================================
```

---

## 🛠️ Αρχικοποίηση Οποιουδήποτε Project (`agy-init-workspace`)

Για να προστατεύσετε οποιοδήποτε project με τα hard gates του Antigravity Gatekeeper:
```bash
cd /path/to/my-project
agy-init-workspace
```
Ή καθορίζοντας το μονοπάτι:
```bash
agy-init-workspace /path/to/my-project
```

Αυτό θα δημιουργήσει:
- `.agents/hooks.json`: Lifecycle PreToolUse hooks (`commit-gate`, `protect-enforcement`, `qa-stop-gate`, `preflight-context`).
- `.agents/scripts/`: Όλα τα εργαλεία ελέγχου και signing gates (`frontier-orchestrate.sh`, `stage0-precheck.sh`, `run-*-gate.sh`).
- `.agents/rules/`: Κανόνες `00-agent-contract.md` και `40-codex-integration.md`.
- `.git/hooks/pre-commit` & `.git/hooks/post-commit`: Εγγενή Git hooks που αποτρέπουν commits χωρίς ψηφιακή υπογραφή HMAC.
- `.agent-state/`: Κατάσταση όλων των gates (`qa.json`, `regression.json`, `vault.json`, `docs.json`, `skills.json`, `codex-review.json`).

---

## 🛡️ Ο Root Gatekeeper Daemon (`agy-gatekeeper.service`)

Ο gatekeeper τρέχει ως daemon συστήματος υπό το `root` στο `127.0.0.1:18099`:
- Κρατάει το μυστικό HMAC (`/etc/agy-gatekeeper/gate.key`, mode `0600 root:root`) ανέγγιχτο από τον agent.
- Υποστηρίζει **οποιοδήποτε workspace** δυναμικά (`?workspace=/path/to/repo` ή `payload.workspace`).
- Επαληθεύει την ταυτότητα της διαδικασίας μέσω `/proc/net/tcp` και της ιεραρχίας PPid, αποτρέποντας πλαστογράφηση κλήσεων `curl`.
- Χειροκίνητη εγκατάσταση/επανεκκίνηση:
  ```bash
  sudo ~/Development/antigravity-orchestrator/gatekeeper/install-gatekeeper.sh
  ```

---

## 🔄 Συγχρονισμός Ενημερώσεων (`agy-arch-sync`)

Όποτε γίνονται βελτιώσεις στον orchestrator ή στους κανόνες:
```bash
agy-arch-sync
```
Εκτελεί αυτόματα `git pull --ff-only` και επανεκτελεί το `./install.sh`.

---

## 📁 Δομή Αποθετηρίου

```text
antigravity-orchestrator/
├── README.md                          # Αυτό το αρχείο τεκμηρίωσης
├── install.sh                         # Κεντρικός εγκαταστάτης (Linux / Git Bash)
├── install.ps1                        # Κεντρικός εγκαταστάτης (Windows PowerShell)
├── bin/
│   ├── agy-init-workspace             # Αρχικοποίηση νέου project με hard gates (Bash)
│   ├── agy-init-workspace.ps1         # Αρχικοποίηση νέου project με hard gates (PowerShell)
│   ├── agy-arch-sync                  # Συγχρονισμός και επανεγκατάσταση
│   ├── frontier-orchestrate           # Παγκόσμιο CLI frontier routing (Bash)
│   ├── frontier-orchestrate.ps1       # Παγκόσμιο CLI frontier routing (PowerShell)
│   └── agy-setup-clis                 # Εγκατάσταση, auth & smoke-test των CLIs
├── gatekeeper/
│   ├── server.js                      # Root Gatekeeper HTTP Daemon (Node.js)
│   ├── agy-gatekeeper.service         # Systemd service unit
│   └── install-gatekeeper.sh          # Εγκατάσταση του daemon στο λειτουργικό
├── global/
│   ├── gemini/config/
│   │   ├── AGENTS.md                  # Παγκόσμιοι κανόνες μηχανήματος
│   │   ├── GEMINI.md                  # Global Gemini κανόνες
│   │   └── skills/                    # Global skills (claude, codex, opencode, review)
│   └── opencode/
│       └── opencode.json              # Generic OpenCode readonly configuration
└── workspace-template/
    ├── AGENTS.md                      # Template κανόνων για κάθε project
    └── .agents/
        ├── PROJECT_KNOWLEDGE.md       # Knowledge vault template
        ├── hooks.json                 # Antigravity tool hooks
        ├── rules/                     # Completion contract & 4-pool council rules
        ├── scripts/                   # Όλα τα gate scripts & frontier wrappers
        └── skills/                    # Multi-model delegation & codex review skills
```

### 🚨 ΚΑΝΟΝΑΣ ΕΚΤΑΚΤΗΣ ΕΦΕΔΡΕΙΑΣ QUOTA (`< 10%` Gemini Weekly/Monthly Limit — Zero-Gemini Pass-Through Mode)
- **Συνθήκη Ενεργοποίησης (`gemini-quota-mode.sh --set-reserve <pct>`)**: Όταν το weekly/monthly limit πέφτει **κάτω από `10%` σε όλα τα μοντέλα Gemini** (ελέγχεται μέσω `~/.gemini/config/gemini-quota.json` και εμφανίζεται στο preflight ως `🚨 GEMINI_QUOTA=<10%`), ενεργοποιείται αυτόματα το **Zero-Gemini Pass-Through Reserve Mode**.
- **Καθολική Αντικατάσταση ΟΛΩΝ των Gemini Μοντέλων (συμπεριλαμβανομένου του `Gemini 3.8 Flash`)**:
  - **ΑΠΑΓΟΡΕΥΕΤΑΙ** η κλήση `invoke_subagent` (ακόμη και με `Model: "flash"` / `Gemini 3.8 Flash`), ώστε να μην καταναλώνεται καθόλου Gemini quota σε subagent loops.
  - Ο Parent Agent λειτουργεί **αποκλειστικά ως 1-step Pass-Through Router** (κρατώντας τα τελευταία `< 10%` Gemini credits αποκλειστικά και μόνο για να παραλαμβάνει τις εντολές του χρήστη στο UI και να τις προωθεί ακαριαία χωρίς κανένα processing από Gemini):
    - **`T1` (Αντικατάσταση `Gemini 3.8 Flash`)**: `bash .agents/scripts/frontier-orchestrate.sh --tier flash` $ightarrow$ **Pool D (`deepseek/deepseek-v4-pro` / `deepseek-flash`)** $ightarrow$ **Pool C (`Claude Sonnet 4.6 low`)** $ightarrow$ **Pool B (`Codex gpt-5.6-terra`)**.
    - **`T2` (Αντικατάσταση `Gemini 4 Carbon Medium` & `3.8 Flash` UI/CRUD)**: `bash .agents/scripts/frontier-orchestrate.sh --tier ui` $ightarrow$ **Pool C (`Claude Sonnet 4.6`)** $ightarrow$ **Pool B (`Codex gpt-5.6-terra medium`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T3` (Αντικατάσταση `Gemini 4 Carbon Medium` Backend/Integration)**: `bash .agents/scripts/frontier-orchestrate.sh --tier backend` $ightarrow$ **Pool B (`Codex gpt-6-astra high`)** $ightarrow$ **Pool C (`Claude Sonnet 4.6`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
    - **`T4` (Αντικατάσταση `Gemini 4 Carbon High` Deep/Concurrency/Security)**: `bash .agents/scripts/frontier-orchestrate.sh --tier deep` $ightarrow$ **Pool B (`Codex gpt-6-astra xhigh`)** $ightarrow$ **Pool C (`Claude Opus 4.6 high`)** $ightarrow$ **Pool D (`DeepSeek-V4-Pro`)**.
  - Επαναφορά σε κανονική λειτουργία όταν ανανεωθούν τα limits (`>= 10%`): `bash .agents/scripts/gemini-quota-mode.sh --set-normal 100`.

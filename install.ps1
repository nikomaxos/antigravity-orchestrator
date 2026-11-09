# =============================================================================
# Antigravity Multi-Model Orchestrator & Gatekeeper Installer (Windows PowerShell: `install.ps1`)
# =============================================================================
# Installs global Antigravity configurations, skills, frontier CLIs,
# helper PowerShell/Bash scripts, and background AgyGatekeeper service.
#
# Supports: Windows PowerShell 5.1 & PowerShell Core 7+
# Usage:
#   .\install.ps1 [-WorkspacePath <path>] [-SkipClis]
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspacePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipClis = $false
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

Write-Host "🚀 Installing Antigravity Multi-Model Orchestrator (Windows / PowerShell)" -ForegroundColor Cyan
Write-Host "   User: $env:USERNAME | HOME: $userHome" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# 1. Global Antigravity Config & Rules
# -----------------------------------------------------------------------------
Write-Host "`n📝 1. Installing global rules into $userHome\.gemini\config\..." -ForegroundColor Cyan
$geminiConfigDir = Join-Path $userHome ".gemini\config"
New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null

Copy-Item -Path (Join-Path $scriptDir "global\gemini\config\AGENTS.md") -Destination (Join-Path $geminiConfigDir "AGENTS.md") -Force
Copy-Item -Path (Join-Path $scriptDir "global\gemini\config\GEMINI.md") -Destination (Join-Path $geminiConfigDir "GEMINI.md") -Force
Copy-Item -Path (Join-Path $scriptDir "global\gemini\config\GEMINI.md") -Destination (Join-Path $userHome ".gemini\GEMINI.md") -Force -ErrorAction SilentlyContinue

Write-Host "   ✓ $userHome\.gemini\config\AGENTS.md" -ForegroundColor Green
Write-Host "   ✓ $userHome\.gemini\config\GEMINI.md" -ForegroundColor Green
Write-Host "   ✓ $userHome\.gemini\GEMINI.md" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Global Skills
# -----------------------------------------------------------------------------
Write-Host "`n🧠 2. Installing global skills into $userHome\.gemini\config\skills\..." -ForegroundColor Cyan
$skillsBaseDir = Join-Path $geminiConfigDir "skills"
New-Item -ItemType Directory -Path $skillsBaseDir -Force | Out-Null

$skills = @("claude", "codex", "opencode", "multi-model-delegation", "codex-review")
foreach ($s in $skills) {
    $srcSkill = Join-Path $scriptDir "global\gemini\config\skills\$s"
    $destSkill = Join-Path $skillsBaseDir $s
    if (Test-Path $srcSkill) {
        New-Item -ItemType Directory -Path $destSkill -Force | Out-Null
        Copy-Item -Path "$srcSkill\*" -Destination $destSkill -Recurse -Force
        Write-Host "   ✓ Installed skill: $s" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# 3. Global OpenCode Configuration
# -----------------------------------------------------------------------------
Write-Host "`n⚙️ 3. Configuring OpenCode..." -ForegroundColor Cyan
$openCodeTargets = @(
    (Join-Path $userHome ".config\opencode"),
    (Join-Path $env:APPDATA "opencode")
)
$srcOpenCodeJson = Join-Path $scriptDir "global\opencode\opencode.json"

foreach ($targetDir in $openCodeTargets) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $destFile = Join-Path $targetDir "opencode.json"
    if (-not (Test-Path $destFile)) {
        Copy-Item -Path $srcOpenCodeJson -Destination $destFile -Force
        Write-Host "   ✓ Created $destFile" -ForegroundColor Green
    } else {
        # Preserve existing API keys if already present; ensure readonly-auditor is merged
        try {
            $existing = Get-Content -Path $destFile -Raw | ConvertFrom-Json
            $template = Get-Content -Path $srcOpenCodeJson -Raw | ConvertFrom-Json
            if (-not $existing.agent) {
                $existing | Add-Member -MemberType NoteProperty -Name "agent" -Value $template.agent
            } elseif (-not $existing.agent."readonly-auditor") {
                $existing.agent | Add-Member -MemberType NoteProperty -Name "readonly-auditor" -Value $template.agent."readonly-auditor"
            }
            $existing | ConvertTo-Json -Depth 10 | Set-Content -Path $destFile -Encoding UTF8
            Write-Host "   ✓ Updated $destFile (preserved existing provider & keys)" -ForegroundColor Green
        } catch {
            Write-Host "   ℹ️ Preserved existing $destFile" -ForegroundColor DarkGray
        }
    }
}

# -----------------------------------------------------------------------------
# 4. External Frontier CLIs via npm (if npm present)
# -----------------------------------------------------------------------------
if (-not $SkipClis) {
    Write-Host "`n🤖 4. Checking / installing external frontier CLIs (npm)..." -ForegroundColor Cyan
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        try {
            Write-Host "   Installing/updating @openai/codex, @anthropic-ai/claude-code, and opencode-ai globally..." -ForegroundColor DarkGray
            npm install -g @openai/codex @anthropic-ai/claude-code opencode-ai --silent
            Write-Host "   ✓ Frontier CLIs installed globally via npm" -ForegroundColor Green
        } catch {
            Write-Host "   ⚠️ npm install encountered an issue: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ℹ️ Node.js/npm not found in PATH; skipping npm global package installation." -ForegroundColor DarkGray
    }
}

# -----------------------------------------------------------------------------
# 5. Install Helper Binaries into ~/.local/bin/ and Cache Template
# -----------------------------------------------------------------------------
Write-Host "`n🔧 5. Installing helper scripts into $userHome\.local\bin\..." -ForegroundColor Cyan
$localBin = Join-Path $userHome ".local\bin"
New-Item -ItemType Directory -Path $localBin -Force | Out-Null

$binSource = Join-Path $scriptDir "bin"
if (Test-Path $binSource) {
    Copy-Item -Path "$binSource\*" -Destination $localBin -Recurse -Force
    Write-Host "   ✓ Copied bin tools into $localBin" -ForegroundColor Green
}

# Cache workspace-template permanently in ~/.local/share
$localShare = Join-Path $userHome ".local\share\antigravity-orchestrator"
New-Item -ItemType Directory -Path $localShare -Force | Out-Null
$srcTemplate = Join-Path $scriptDir "workspace-template"
if (Test-Path $srcTemplate) {
    Copy-Item -Path $srcTemplate -Destination $localShare -Recurse -Force
    Write-Host "   ✓ Cached workspace-template into $localShare" -ForegroundColor Green
}

# Add $userHome\.local\bin to User PATH if missing
$userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
if ($userPath -notlike "*$localBin*") {
    $newUserPath = "$localBin;$userPath"
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, [EnvironmentVariableTarget]::User)
    $env:Path = "$localBin;$env:Path"
    Write-Host "   ✓ Added $localBin to User PATH environment variable" -ForegroundColor Green
} else {
    Write-Host "   ℹ️ $localBin is already in User PATH" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# 6. Gatekeeper Service Setup & Startup
# -----------------------------------------------------------------------------
Write-Host "`n🛡️ 6. Configuring AgyGatekeeper daemon (127.0.0.1:18099)..." -ForegroundColor Cyan
$gatekeeperLib = Join-Path $userHome ".local\lib\agy-gatekeeper"
New-Item -ItemType Directory -Path $gatekeeperLib -Force | Out-Null
Copy-Item -Path (Join-Path $scriptDir "gatekeeper\server.js") -Destination (Join-Path $gatekeeperLib "server.js") -Force
Write-Host "   ✓ Installed Gatekeeper daemon at $gatekeeperLib\server.js" -ForegroundColor Green

# Resolve node executable path
$nodeCmd = "node.exe"
$foundNode = Get-Command node -ErrorAction SilentlyContinue
if ($foundNode) {
    $nodeCmd = $foundNode.Source
}

# Register for user logon via Registry Run (reliable without admin privileges)
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$gatekeeperCmd = "`"$nodeCmd`" `"$gatekeeperLib\server.js`""
try {
    Set-ItemProperty -Path $runKeyPath -Name "AgyGatekeeper" -Value $gatekeeperCmd -Force
    Write-Host "   ✓ Registered AgyGatekeeper in HKCU Run (starts on login)" -ForegroundColor Green
} catch {
    Write-Host "   ⚠️ Could not register HKCU Run key: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Try registering Windows Scheduled Task if possible
try {
    if (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue) {
        $taskAction = New-ScheduledTaskAction -Execute $nodeCmd -Argument "`"$gatekeeperLib\server.js`""
        $taskTrigger = New-ScheduledTaskTrigger -AtLogOn
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 3650)
        Register-ScheduledTask -TaskName "AgyGatekeeper" -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "   ✓ Registered Scheduled Task: AgyGatekeeper" -ForegroundColor Green
    }
} catch {}

# Start Gatekeeper daemon if not currently responding
$gatekeeperRunning = $false
try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:18099/api/gatekeeper/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
    if ($health.status -eq "UP") {
        $gatekeeperRunning = $true
    }
} catch {}

if (-not $gatekeeperRunning) {
    Write-Host "   Starting AgyGatekeeper daemon in background..." -ForegroundColor DarkGray
    if ($foundNode) {
        Start-Process -FilePath $nodeCmd -ArgumentList "`"$gatekeeperLib\server.js`"" -WindowStyle Hidden
        Start-Sleep -Seconds 2
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:18099/api/gatekeeper/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($health.status -eq "UP") {
                Write-Host "   ✅ agy-gatekeeper listening on http://127.0.0.1:18099" -ForegroundColor Green
            }
        } catch {
            Write-Host "   ⚠️ Process started; health check will be ready momentarily." -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ⚠️ 'node' command not found in PATH. Please install Node.js (LTS)." -ForegroundColor Yellow
    }
} else {
    Write-Host "   ✅ agy-gatekeeper is already running and healthy on 127.0.0.1:18099" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 7. Workspace Initialization (Smart Auto-Detection)
# -----------------------------------------------------------------------------
$targetWs = ""
if ($WorkspacePath -and (Test-Path $WorkspacePath)) {
    $targetWs = [System.IO.Path]::GetFullPath($WorkspacePath)
} elseif (Test-Path "C:\Users\parda\OneDrive\Dev\ha") {
    $targetWs = "C:\Users\parda\OneDrive\Dev\ha"
}

if ($targetWs) {
    Write-Host "`n🏠 7. Initializing target workspace: $targetWs..." -ForegroundColor Cyan
    $initScript = Join-Path $scriptDir "bin\agy-init-workspace.ps1"
    & $initScript -WorkspacePath $targetWs
}

Write-Host "`n🎉 Installation complete!" -ForegroundColor Cyan
Write-Host "Next steps on Windows:"
Write-Host "  1. Initialize any project with full hard gates:"
Write-Host "     agy-init-workspace.ps1 C:\path\to\my-project"
Write-Host "  2. Run external frontier orchestrations:"
Write-Host "     frontier-orchestrate.ps1 --tier ui -p `"Check UI layout`""
Write-Host "  3. Gatekeeper status check:"
Write-Host "     Invoke-RestMethod http://127.0.0.1:18099/api/gatekeeper/health"

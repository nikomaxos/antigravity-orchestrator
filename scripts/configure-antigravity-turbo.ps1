<#
.SYNOPSIS
  Configures Antigravity for Turbo Velocity (Zero-Popup CitC Flow) and Workspace Trust on Windows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Continue"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

$configDir = Join-Path $userHome ".gemini\config"
$configFile = Join-Path $configDir "config.json"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

if (-not (Test-Path $configFile)) {
    Write-Utf8NoBom -Path $configFile -Content '{"userSettings":{}}'
} else {
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    Copy-Item -Path $configFile -Destination "$configFile.bak.$stamp" -Force -ErrorAction SilentlyContinue
}

try {
    $raw = ([System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF)
    $json = $raw | ConvertFrom-Json
} catch {
    $json = [PSCustomObject]@{ userSettings = [PSCustomObject]@{} }
}

if (-not $json.userSettings) {
    $json | Add-Member -MemberType NoteProperty -Name "userSettings" -Value ([PSCustomObject]@{})
}

$props = @{
    "nonWorkspaceFileAccessPolicy"     = "AGENT_SETTING_POLICY_ALLOW"
    "allowCascadeAccessGitignoreFiles" = $true
    "autoExecutionPolicy"             = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"
    "permissionPreset"                = "AGENT_PERMISSION_PRESET_TURBO"
    "enableTerminalSandbox"           = $false
}

foreach ($k in $props.Keys) {
    if ($json.userSettings.PSObject.Properties[$k]) {
        $json.userSettings.$k = $props[$k]
    } else {
        $json.userSettings | Add-Member -MemberType NoteProperty -Name $k -Value $props[$k]
    }
}

Write-Utf8NoBom -Path $configFile -Content (($json | ConvertTo-Json -Depth 10) + "`n")
Write-Host "   ✓ Configured Turbo settings in $configFile" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Antigravity / VS Code Workspace Trust in %APPDATA%\Antigravity\User\settings.json
# -----------------------------------------------------------------------------
$appData = $env:APPDATA
if ($appData) {
    $agUserDir = Join-Path $appData "Antigravity\User"
    New-Item -ItemType Directory -Path $agUserDir -Force | Out-Null
    $agSettingsFile = Join-Path $agUserDir "settings.json"

    $agSettings = [PSCustomObject]@{}
    if (Test-Path $agSettingsFile) {
        try {
            $rawAg = ([System.IO.File]::ReadAllText($agSettingsFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF)
            $agSettings = $rawAg | ConvertFrom-Json
        } catch {}
    }

    $trustProps = @{
        "security.workspace.trust.enabled"         = $false
        "security.workspace.trust.untrustedFiles"  = "open"
        "security.workspace.trust.startupPrompt"   = "never"
        "security.workspace.trust.banner"          = "never"
    }

    foreach ($k in $trustProps.Keys) {
        if ($agSettings.PSObject.Properties[$k]) {
            $agSettings.$k = $trustProps[$k]
        } else {
            $agSettings | Add-Member -MemberType NoteProperty -Name $k -Value $trustProps[$k]
        }
    }

    Write-Utf8NoBom -Path $agSettingsFile -Content (($agSettings | ConvertTo-Json -Depth 10) + "`n")
    Write-Host "   ✓ Configured Workspace Trust in $agSettingsFile" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# OneDrive Reparse Point Resolution (Zero-Popup for Cloud Storage Mounts)
# -----------------------------------------------------------------------------
if ($WorkspacePath -and (Test-Path $WorkspacePath)) {
    try {
        $item = Get-Item -Path $WorkspacePath -Force
        $realTarget = $item.Target
        if ($realTarget) {
            Write-Host "   ✓ Resolved OneDrive reparse target: $realTarget" -ForegroundColor DarkGray
        }
    } catch {}
}

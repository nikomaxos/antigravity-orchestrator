@echo off
setlocal enabledelayedexpansion

:: AGY-GATEKEEPER TCB GIT SHIM (Windows Command Prompt / PowerShell)
:: Enforces zero-bypass on --no-verify, -n (commit), and core.hooksPath override

for /f "delims=" %%I in ('git.exe rev-parse --show-toplevel 2^>nul') do set "TOPLEVEL=%%I"

if defined TOPLEVEL (
  if exist "%TOPLEVEL%\.agents\hooks.json" (
    set "IS_COMMIT=0"
    for %%A in (%*) do (
      if /i "%%A"=="commit" set "IS_COMMIT=1"
      if /i "%%A"=="--no-verify" (
        echo ⛔ BLOCKED BY AGY-GATEKEEPER TCB: --no-verify is strictly forbidden in verified workspaces! 1>&2
        exit /b 1
      )
      echo "%%A" | findstr /i "core\.hooksPath" >nul
      if !errorlevel! equ 0 (
        echo ⛔ BLOCKED BY AGY-GATEKEEPER TCB: core.hooksPath override is strictly forbidden in verified workspaces! 1>&2
        exit /b 1
      )
    )
    if "!IS_COMMIT!"=="1" (
      for %%A in (%*) do (
        if "%%A"=="-n" (
          echo ⛔ BLOCKED BY AGY-GATEKEEPER TCB: git commit -n is strictly forbidden in verified workspaces! 1>&2
          exit /b 1
        )
      )
    )
  )
)

git.exe %*
exit /b %errorlevel%

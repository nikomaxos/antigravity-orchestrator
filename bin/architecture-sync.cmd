@echo off
rem =============================================================================
rem Antigravity Architecture Sync Launcher (Windows CMD: architecture-sync.cmd)
rem =============================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0architecture-sync.ps1" %*

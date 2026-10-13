@echo off
rem Auto Cleaner - duplo clique para abrir. Use "AutoCleaner.bat -DryRun" para simular sem apagar nada.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AutoCleaner.ps1" %*

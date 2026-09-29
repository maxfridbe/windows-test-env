@echo off
rem Executed by dockur/windows at the final step of the unattended install.
rem This folder is C:\OEM inside the VM.
echo [install.bat] Setting up OpenSSH server...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-ssh.ps1"
echo [install.bat] done (see C:\OEM\setup-ssh.log)

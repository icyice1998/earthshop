@echo off
REM Sends a small test slip straight to the printer (no browser, no app).
cd /d "%~dp0"
set /p IP=Printer IP (for example 192.168.1.146): 
node bridge.js --selftest %IP% 9100
pause

@echo off
REM Starts the Earthshop print bridge. Change 9101 if you changed the port in the app.
cd /d "%~dp0"
node bridge.js --port 9101
pause

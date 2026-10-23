@echo off
REM Starts the print bridge AND serves the app to phones on the shop Wi-Fi.
REM On the phone open the address printed below (for example http://192.168.1.50:9101/).
cd /d "%~dp0"
node bridge.js --port 9101 --serve
pause

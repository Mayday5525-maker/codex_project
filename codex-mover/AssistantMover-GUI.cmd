@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0AssistantMover-GUI.ps1" %*
set "mover_exit=%errorlevel%"
if "%mover_exit%"=="0" exit /b 0
echo.
echo Dev Mover failed to start or complete. Review the error above.
pause
exit /b %mover_exit%

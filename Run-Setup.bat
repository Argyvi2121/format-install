@echo off
REM Self-elevate to Administrator (the window of the elevated copy starts minimized)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WindowStyle Minimized"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Windows11.ps1"

@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phpvm.ps1" %*
exit /b %errorlevel%

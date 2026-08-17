@echo off
title Qwen AEON Server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Serve-Qwen-AEON.ps1" %*
pause

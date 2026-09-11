@echo off
title Cursor Storage Repair
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-cursor-storage.ps1"
pause

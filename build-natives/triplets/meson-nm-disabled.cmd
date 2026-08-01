@echo off
rem Meson treats a failing nm as an optional ABI-stamp optimization failure.
rem Returning immediately avoids MinGW nm hangs while preserving link output.
exit /b 1

@echo off
REM 一键固化: Vivado → (可选) Vitis Platform → BOOT.bin → 可选 SD
REM 用法:
REM   rebuild_sd_boot.bat
REM   rebuild_sd_boot.bat -SkipVivado
REM   rebuild_sd_boot.bat -SkipVivado E:
setlocal EnableExtensions
REM 先记下 bat 所在目录 (cd 之前; 避免从 PowerShell 调用时路径丢失)
set "TOOLS=%~dp0"
set "PS1=%TOOLS%rebuild_sd_boot.ps1"
cd /d "%TOOLS%.."

if not exist "%PS1%" (
  echo ERROR: 找不到 %PS1%
  pause
  exit /b 1
)

set "EXTRA=-PauseAtEnd"
set "SD="

:parse
if "%~1"=="" goto run
if /I "%~1"=="-SkipVivado" (
  set "EXTRA=%EXTRA% -SkipVivado"
  shift /1
  goto parse
)
if /I "%~1"=="-SkipVitis" (
  set "EXTRA=%EXTRA% -SkipVitis"
  shift /1
  goto parse
)
if /I "%~1"=="-RequireVitis" (
  set "EXTRA=%EXTRA% -RequireVitis"
  shift /1
  goto parse
)
set "SD=-SdDrive %~1"
shift /1
goto parse

:run
echo Running: %PS1% %EXTRA% %SD%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %EXTRA% %SD%
set "ERR=%ERRORLEVEL%"
exit /b %ERR%

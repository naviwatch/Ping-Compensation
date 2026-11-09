@echo off
setlocal

rem Builds Ping Compensation with Vermintide Mod Builder (VMB).
rem The output goes to this window and to build_log.txt, replacing the last log.
rem VMB also copies the bundle into the Workshop folder, so testing needs no upload.
rem Expects this folder to be in the mods folder next to vmb.exe.

cd /d "%~dp0"

if not exist "..\..\vmb.exe" (
	> "build_log.txt" echo vmb.exe not found. This folder must be in the mods folder next to vmb.exe.
	type "build_log.txt"
	pause
	exit /b 1
)

> "build_log.txt" echo Ping Compensation build started %date% %time%

rem Game Lua can't run git, so the commit and branch are written into the build here.
rem /pingcomp version reads them. "-dirty" means the build has uncommitted changes.
set "stamp=scripts\mods\Ping Compensation\BuildInfo.lua"
set "commit=unknown"
set "branch=unknown"
set "dirty="
for /f "delims=" %%A in ('git rev-parse --short HEAD 2^>nul') do set "commit=%%A"
for /f "delims=" %%A in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "branch=%%A"
for /f "delims=" %%A in ('git status --porcelain 2^>nul') do set "dirty=-dirty"
> "%stamp%" echo return { commit = "%commit%%dirty%", branch = "%branch%" }
echo Build stamp: "%commit%%dirty%" on "%branch%"
>> "build_log.txt" echo Build stamp: "%commit%%dirty%" on "%branch%"

powershell -NoProfile -Command "& '..\..\vmb.exe' build 'Ping Compensation' -f .. 2>&1 | ForEach-Object { $line = $_.ToString(); $line; Add-Content -LiteralPath 'build_log.txt' -Value $line -Encoding UTF8 }; exit $LASTEXITCODE"
set "exit_code=%errorlevel%"

rem Remove the stamp so a build made without this script reports "unknown", not an old commit.
del "%stamp%"

>> "build_log.txt" echo VMB exit code: %exit_code%

echo.
if "%exit_code%"=="0" (
	echo Build finished. Press Ctrl+Shift+R in game to reload it. Log: build_log.txt
) else (
	echo BUILD FAILED with exit code %exit_code%. See the errors above or in build_log.txt.
)
pause
exit /b %exit_code%

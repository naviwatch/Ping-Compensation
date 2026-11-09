@echo off
setlocal EnableDelayedExpansion

rem Uploads the last build of Ping Compensation to its existing Steam Workshop item.
rem The output goes to this window and to upload_log.txt, replacing the last log.
rem It does not rebuild, so run build.bat first.
rem Workshop uploads are done by hand: Claude Code sessions must not run this.
rem Expects this folder to be in the mods folder next to vmb.exe.

cd /d "%~dp0"

if not exist "..\..\vmb.exe" (
	> "upload_log.txt" echo vmb.exe not found. This folder must be in the mods folder next to vmb.exe.
	type "upload_log.txt"
	pause
	exit /b 1
)

set "built="
for %%F in ("bundleV2\*.mod_bundle") do set "built=%%~tF"

if not defined built (
	echo No build found in bundleV2. Run build.bat first.
	pause
	exit /b 1
)

echo Ping Compensation: Steam Workshop upload
echo Build to upload: !built!
echo Steam must be running.
echo.

set "note="
set /p "note=Change note (press Enter to skip): "
if defined note set "note=!note:"='!"

echo.
set "confirm="
set /p "confirm=Upload this build to the Workshop now? Type Y and press Enter: "
if /i not "!confirm!"=="Y" (
	echo Upload cancelled. Nothing was sent.
	pause
	exit /b 1
)

> "upload_log.txt" echo Ping Compensation upload started !date! !time!
>> "upload_log.txt" echo Build date: !built!
>> "upload_log.txt" echo Change note: !note!

echo.
powershell -NoProfile -Command "$a = 'upload','Ping Compensation','-f','..'; if ($env:note) { $a += '-n',$env:note }; & '..\..\vmb.exe' $a 2>&1 | ForEach-Object { $line = $_.ToString(); $line; Add-Content -LiteralPath 'upload_log.txt' -Value $line -Encoding UTF8 }; exit $LASTEXITCODE"
set "exit_code=!errorlevel!"

>> "upload_log.txt" echo VMB exit code: !exit_code!

echo.
if "!exit_code!"=="0" (
	echo Upload finished. Log: upload_log.txt
) else (
	echo UPLOAD FAILED with exit code !exit_code!. See the errors above or in upload_log.txt.
)
pause
exit /b !exit_code!

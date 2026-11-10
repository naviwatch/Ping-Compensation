@echo off
setlocal

rem Rebuilds Docs\Briefs\playtest-handout.pdf from Docs\Briefs\playtest-handout.md.
rem Testers get the PDF, not the Markdown, so run this after every change to the handout.
rem Needs Python 3 and Microsoft Edge or Google Chrome. It installs nothing.

cd /d "%~dp0"

set "markdown=Docs\Briefs\playtest-handout.md"
set "pdf=Docs\Briefs\playtest-handout.pdf"
set "work=%TEMP%\pingcomp-handout-pdf"

set "python="
where py >nul 2>nul && set "python=py"
if not defined python where python >nul 2>nul && set "python=python"

set "browser=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%browser%" set "browser=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not exist "%browser%" set "browser=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%browser%" set "browser=%LocalAppData%\Google\Chrome\Application\chrome.exe"

if not defined python (
	echo Python 3 was not found. Install it from python.org or the Microsoft Store, then run this again.
	pause
	exit /b 1
)

if not exist "%browser%" (
	echo Neither Microsoft Edge nor Google Chrome was found.
	pause
	exit /b 1
)

if exist "%work%" rmdir /s /q "%work%"
if not exist "%work%" mkdir "%work%"
if exist "%work%\handout.pdf" del /q "%work%\handout.pdf"

rem This window writes the page, not Python: Microsoft Store Python may redirect files it creates
rem under AppData to a private folder that the browser can't see.
%python% "Docs\handout_to_html.py" "%markdown%" > "%work%\handout.html"

if errorlevel 1 (
	echo Could not turn %markdown% into a page. See the error above.
	pause
	exit /b 1
)

rem --no-pdf-header-footer drops the browser's own header and footer, so the page's footer is the only one.
"%browser%" --headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions --no-pdf-header-footer --user-data-dir="%work%\browser-profile" --print-to-pdf="%work%\handout.pdf" "%work%\handout.html" > "%work%\browser.log" 2>&1

if not exist "%work%\handout.pdf" (
	echo The browser did not write a PDF. Its output:
	type "%work%\browser.log"
	pause
	exit /b 1
)

move /y "%work%\handout.pdf" "%pdf%" >nul

if errorlevel 1 (
	echo Could not replace %pdf%. Close it if it is open in a PDF viewer, then run this again.
	pause
	exit /b 1
)

rmdir /s /q "%work%" 2>nul

echo Built %pdf%
pause
exit /b 0

@echo off
rem Puts the files and directories named as arguments (paths under build\) into the same place under out\,
rem copying only what differs, so a running silverc.exe doesn't fail a build that changed nothing. See ship.sh.
cd /d "%~dp0" || exit /b 1
:next
if "%~1"=="" exit /b 0
if exist "build\%~1\*" (
    robocopy "build\%~1" "out\%~1" /E /NFL /NDL /NJH /NJS /NP >nul
) else if exist "build\%~1" (
    for %%S in ("build\%~1") do for %%D in ("out\%~1") do robocopy "%%~dpS." "%%~dpD." "%%~nxS" /NFL /NDL /NJH /NJS /NP >nul
)
if errorlevel 8 exit /b 1
shift
goto next

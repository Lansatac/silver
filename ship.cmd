@echo off
rem Puts the files and directories named as arguments (paths under build\) into the same place under out\,
rem copying only what differs, so a running silverc.exe doesn't fail a build that changed nothing. See ship.sh.
cd /d "%~dp0" || exit /b 1
:next
if "%~1"=="" exit /b 0
if exist "build\%~1\" (
    robocopy "build\%~1" "out\%~1" /E /NFL /NDL /NJH /NJS /NP >nul
) else if exist "build\%~1" (
    robocopy "build\%~dp1." "out\%~dp1." "%~nx1" /NFL /NDL /NJH /NJS /NP >nul
)
if errorlevel 8 exit /b 1
shift
goto next

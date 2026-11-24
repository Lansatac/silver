@echo off
rem Puts what ships into out/: see ship.sh. Hard links where it can, else copies.
cd /d "%~dp0" || exit /b 1
if not exist out\runtime mkdir out\runtime
for %%F in (silver.exe silverc.exe runtime\silver_rt.lib runtime\phobos64.lib) do if exist build\%%F (
    del /q out\%%F 2>nul
    mklink /H out\%%F build\%%F >nul 2>&1 || copy /y build\%%F out\%%F >nul || exit /b 1
)
if exist build\runtime\mingw xcopy /d /y /q /i /s build\runtime\mingw out\runtime\mingw >nul
exit /b 0

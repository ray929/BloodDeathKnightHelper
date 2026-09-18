@echo off
rem ============================================================
rem  BloodDeathKnightHelper - local package builder (Windows cmd)
rem
rem  Output : BloodDeathKnightHelper.zip   (written next to this script)
rem  Layout : BloodDeathKnightHelper\  containing
rem             BloodDeathKnightHelper.toc
rem             Commands.lua
rem             BoneShield.lua
rem             BoilingPoint.lua
rem             Sounds\*.mp3
rem           Unzip it straight into Interface\AddOns\
rem
rem  Development material never ships - same policy as .gitignore and
rem  pkgmeta.yaml: .git\ .gitignore .gitattributes .workbuddy\ AGENTS.md
rem  README.md pkgmeta.yaml package.cmd tests\ docs\ build\ *.zip
rem  That is done with a whitelist (toc + lua + Sounds), so a loose file
rem  in the repo root cannot leak into the release by accident.
rem
rem  Usage : package.cmd      build, then wait for a key (double-click)
rem          package.cmd -q   build, no pause (scripting / CI)
rem
rem  Needs : Windows 10 1803+ (System32\tar.exe) or PowerShell 5.1
rem ============================================================

setlocal EnableExtensions
cd /d "%~dp0"

set "ADDON=BloodDeathKnightHelper"
set "STAGE=build"
set "ZIP=%ADDON%.zip"
set "TAR=%SystemRoot%\System32\tar.exe"

echo === Packaging %ADDON% ===
echo.

if not exist "%ADDON%.toc" goto :no_toc

rem ---- 1. clean previous output ------------------------------
if exist "%STAGE%" rmdir /s /q "%STAGE%"
if exist "%ZIP%" del /q "%ZIP%"

rem ---- 2. stage the runtime files ----------------------------
mkdir "%STAGE%\%ADDON%" 2>nul
copy /y "*.toc" "%STAGE%\%ADDON%\" >nul || goto :fail
copy /y "*.lua" "%STAGE%\%ADDON%\" >nul || goto :fail
xcopy /y /e /i /q "Sounds" "%STAGE%\%ADDON%\Sounds" >nul
if errorlevel 2 goto :fail

rem ---- 3. create the zip -------------------------------------
if not exist "%TAR%" goto :zip_ps

pushd "%STAGE%"
"%TAR%" -a -c -f "..\%ZIP%" "%ADDON%"
if errorlevel 1 goto :tar_failed
popd
goto :verify

:tar_failed
popd
echo tar.exe failed, retrying with PowerShell Compress-Archive ...
echo.

:zip_ps
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%STAGE%\%ADDON%' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 goto :fail

rem ---- 4. verify ---------------------------------------------
:verify
if not exist "%ZIP%" goto :fail
echo Contents of %ZIP%:
if exist "%TAR%" (
    "%TAR%" -t -f "%ZIP%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[System.IO.Compression.ZipFile]::OpenRead((Resolve-Path '%ZIP%').Path); $z.Entries | Select-Object -ExpandProperty FullName; $z.Dispose()"
)

rmdir /s /q "%STAGE%"
echo.
echo === Done: %CD%\%ZIP% ===
if /i not "%~1"=="-q" pause
exit /b 0

:no_toc
echo *** %ADDON%.toc not found in this folder ***
echo     Run package.cmd from the repository root.
if /i not "%~1"=="-q" pause
exit /b 1

:fail
if exist "%STAGE%" rmdir /s /q "%STAGE%" 2>nul
echo.
echo *** PACKAGING FAILED ***
if /i not "%~1"=="-q" pause
exit /b 1

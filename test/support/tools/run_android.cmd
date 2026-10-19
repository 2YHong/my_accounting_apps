@echo off
setlocal
set "TASK_FLAVOR=basic"
if /i "%~1"=="screenshot" set "TASK_FLAVOR=screenshot"
if not "%~1"=="" if /i not "%~1"=="basic" if /i not "%~1"=="screenshot" (
  echo Usage: tools\run_android.cmd [basic^|screenshot]
  exit /b 2
)
set "GRADLE_USER_HOME=D:\Flutter\work\build-cache\gradle"
if exist "%USERPROFILE%\.gradle\caches\modules-2" set "GRADLE_RO_DEP_CACHE=%USERPROFILE%\.gradle\caches\modules-2"
set "TEMP=D:\Flutter\work\build-cache\temp"
set "TMP=%TEMP%"
if not exist "%TEMP%" mkdir "%TEMP%"
cd /d "%~dp0.."
call "D:\Flutter\flutter\bin\flutter.bat" run --flavor %TASK_FLAVOR%
exit /b %ERRORLEVEL%

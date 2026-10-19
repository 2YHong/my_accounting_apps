@echo off
setlocal
cd /d "%~dp0.."
set "ACCOUNTING_ADB=%LOCALAPPDATA%\Android\sdk\platform-tools\adb.exe"
if not exist "%ACCOUNTING_ADB%" (
  echo Android platform-tools was not found. Please check your Android SDK location.
  exit /b 1
)
"%ACCOUNTING_ADB%" get-state >nul 2>nul
if errorlevel 1 (
  echo Connect one phone by USB and allow USB debugging, then try again.
  exit /b 1
)
if /I "%~1"=="debug" goto debug
for /f "delims=" %%A in ('"%ACCOUNTING_ADB%" shell getprop ro.product.cpu.abi 2^>nul') do set "ACCOUNTING_ABI=%%A"
if "%ACCOUNTING_ABI%"=="arm64-v8a" set "ACCOUNTING_PLATFORM=android-arm64"
if "%ACCOUNTING_ABI%"=="armeabi-v7a" set "ACCOUNTING_PLATFORM=android-arm"
if "%ACCOUNTING_ABI%"=="x86_64" set "ACCOUNTING_PLATFORM=android-x64"
if not defined ACCOUNTING_PLATFORM (
  echo Unsupported phone architecture. No app data was changed.
  exit /b 1
)
echo Building a smaller release APK for %ACCOUNTING_ABI%...
if exist cloud-config.json (
  call flutter build apk --release --split-per-abi --no-tree-shake-icons --target-platform=%ACCOUNTING_PLATFORM% --dart-define-from-file=cloud-config.json
) else (
  call flutter build apk --release --split-per-abi --no-tree-shake-icons --target-platform=%ACCOUNTING_PLATFORM%
)
if errorlevel 1 exit /b 1
set "ACCOUNTING_APK=build\app\outputs\flutter-apk\app-%ACCOUNTING_ABI%-release.apk"
goto install
:debug
echo Building debug APK with development logs...
if exist cloud-config.json (
  call flutter build apk --debug --dart-define-from-file=cloud-config.json
) else (
  call flutter build apk --debug
)
if errorlevel 1 exit /b 1
set "ACCOUNTING_APK=build\app\outputs\flutter-apk\app-debug.apk"
:install
"%ACCOUNTING_ADB%" install -r -t "%ACCOUNTING_APK%"
if errorlevel 1 (
  echo Update failed. Keep the existing app installed and send the error for diagnosis.
  echo No uninstall or data-clear action was performed.
  exit /b 1
)
echo Update completed. Open the app on your phone.
exit /b 0

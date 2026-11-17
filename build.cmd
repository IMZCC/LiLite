@echo off
wsl.exe -d SwiftUI-Noble --cd "%~dp0." --exec bash -lc "bash ./build.sh %~1"
exit /b %ERRORLEVEL%

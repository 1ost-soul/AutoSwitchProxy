@echo off
rem 双击运行自适应代理。改配置请编辑同目录下的 adaptive-proxy.ps1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0adaptive-proxy.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo 脚本退出码：%RC%
echo 已退出。
pause

@echo off
REM stop.bat - 停止 start.bat 拉起的 nginx
REM 用法: stop.bat

setlocal

set SCRIPT_DIR=%~dp0
set PID_FILE=%SCRIPT_DIR%.nginx.pid
set RELOAD_PID_FILE=%SCRIPT_DIR%.reload-server.pid
set RENDERED=%SCRIPT_DIR%.nginx.rendered.conf

REM 先停 reload-server(PowerShell 进程)
if exist "%RELOAD_PID_FILE%" (
    set /p RPID=<"%RELOAD_PID_FILE%"
    if not "%RPID%"=="" (
        tasklist /FI "PID eq %RPID%" 2>nul | findstr /I "%RPID%" >nul
        if not errorlevel 1 (
            taskkill /F /PID %RPID% >nul 2>&1
        )
    )
    del "%RELOAD_PID_FILE%" >nul 2>&1
)

REM 找 nginx 二进制(同 start.bat 的查找逻辑)
set NGINX_BIN=
if exist "%SCRIPT_DIR%bin\nginx-windows-x86_64.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx-windows-x86_64.exe
if "%NGINX_BIN%"=="" if exist "%SCRIPT_DIR%bin\nginx-windows-x86.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx-windows-x86.exe
if "%NGINX_BIN%"=="" if exist "%SCRIPT_DIR%bin\nginx.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx.exe

if not exist "%PID_FILE%" (
    echo 没有 pid 文件,似乎没在跑
    endlocal
    exit /b 0
)

set /p PID=<"%PID_FILE%"
if "%PID%"=="" (
    del "%PID_FILE%" 2>nul
    echo pid 文件为空
    endlocal
    exit /b 0
)

REM 优先用 nginx -s quit(优雅退出),失败再用 taskkill
if not "%NGINX_BIN%"=="" (
    "%NGINX_BIN%" -s quit -c "%RENDERED%" 2>nul
    if errorlevel 1 (
        "%NGINX_BIN%" -s stop -c "%RENDERED%" 2>nul
    )
)

REM 兜底用 taskkill
taskkill /F /PID %PID% 2>nul

del "%PID_FILE%" 2>nul
echo 已停止
endlocal
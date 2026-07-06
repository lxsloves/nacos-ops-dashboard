@echo off
REM start.bat - 启动 nacos-ops-dashboard 的 nginx
REM 用法: start.bat

setlocal

set SCRIPT_DIR=%~dp0
set RENDERED=%SCRIPT_DIR%.nginx.rendered.conf
set PID_FILE=%SCRIPT_DIR%.nginx.pid
set LOG_FILE=%SCRIPT_DIR%.nginx.log
set TEMPLATE=%SCRIPT_DIR%nginx-local.conf

REM 找 nginx 二进制
set NGINX_BIN=
if exist "%SCRIPT_DIR%bin\nginx-windows-x86_64.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx-windows-x86_64.exe
if "%NGINX_BIN%"=="" if exist "%SCRIPT_DIR%bin\nginx-windows-x86.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx-windows-x86.exe
if "%NGINX_BIN%"=="" if exist "%SCRIPT_DIR%bin\nginx.exe" set NGINX_BIN=%SCRIPT_DIR%bin\nginx.exe

if "%NGINX_BIN%"=="" (
    echo 找不到 nginx。请先跑 install-nginx.bat
    endlocal
    exit /b 1
)

REM 已运行则先停
if exist "%PID_FILE%" (
    set /p PID=<"%PID_FILE%"
    if not "%PID%"=="" (
        tasklist /FI "PID eq %PID%" 2>nul | findstr /I "%PID%" >nul
        if not errorlevel 1 (
            echo 已经在跑 (pid %PID%),先停掉再启
            call "%SCRIPT_DIR%stop.bat"
        )
    )
)

REM 启动 reload-server(PowerShell 自带,不依赖 Python)
set RELOAD_PID_FILE=%SCRIPT_DIR%.reload-server.pid
set RELOAD_LOG_FILE=%SCRIPT_DIR%.reload-server.log
set RELOAD_PS1=%SCRIPT_DIR%bin\reload-server.ps1
if exist "%RELOAD_PS1%" (
    if exist "%RELOAD_PID_FILE%" (
        set /p RPID=<"%RELOAD_PID_FILE%"
        if not "%RPID%"=="" (
            tasklist /FI "PID eq %RPID%" 2>nul | findstr /I "%RPID%" >nul
            if not errorlevel 1 goto :reload_running
        )
    )
    echo 启动 reload-server ^(PowerShell^) ...
    start /B powershell -NoProfile -ExecutionPolicy Bypass -File "%RELOAD_PS1%" "%SCRIPT_DIR%" >> "%RELOAD_LOG_FILE%" 2>&1
)
:reload_running

REM 渲染配置:把 nginx-local.conf 里的 ${DASHBOARD_ROOT} 替换掉,包成完整 nginx 主配置
REM Windows nginx 路径用正斜杠(也能识别),把反斜杠转成正斜杠
set DASHBOARD_ROOT=%SCRIPT_DIR%
set DASHBOARD_ROOT=%DASHBOARD_ROOT:\=/%
set PID_FILE_FWD=%PID_FILE:\=/%
set LOG_FILE_FWD=%LOG_FILE:\=/%

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$root = '%DASHBOARD_ROOT%';" ^
    "$template = Get-Content '%TEMPLATE%' -Raw -Encoding UTF8;" ^
    "$rendered = $template -replace '\$\{DASHBOARD_ROOT\}', $root;" ^
    "$header = @('worker_processes 1;', 'pid %PID_FILE_FWD%;', 'error_log %LOG_FILE_FWD% warn;', 'events { worker_connections 256; }', 'http {', '  default_type application/octet-stream;', '  access_log off;', '  sendfile on;');" ^
    "$footer = @('}');" ^
    "$content = $header + $rendered + $footer;" ^
    "$content | Out-File -FilePath '%RENDERED%' -Encoding UTF8"

REM 校验语法
"%NGINX_BIN%" -t -c "%RENDERED%"
if errorlevel 1 (
    echo 配置语法校验失败
    endlocal
    exit /b 1
)

REM 后台启动(Windows nginx 启动后写 pid 到配置的 pid 路径)
"%NGINX_BIN%" -c "%RENDERED%"

REM 等 pid 文件出现
set TRIED=0
:wait_pid
if exist "%PID_FILE%" goto :started
set /a TRIED+=1
if %TRIED% GTR 10 goto :started
ping -n 1 127.0.0.1 >nul
goto :wait_pid

:started
echo.
echo nacos-ops-dashboard 已启动
echo   nginx:   %NGINX_BIN%
echo   入口:    http://localhost:18080/dashboard/
echo   配置:    %RENDERED%
echo   pid:     %PID_FILE%
echo   停止:    %SCRIPT_DIR%stop.bat
echo.
endlocal
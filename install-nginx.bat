@echo off
REM install-nginx.bat - 从 nginx.org 下载官方 nginx/Windows 包,解压到 bin\
REM 用法: install-nginx.bat
REM 依赖: PowerShell 5+ (Win10/11 自带)

setlocal

set NGINX_VERSION=1.27.5
if not "%NGINX_VERSION_OVERRIDE%"=="" set NGINX_VERSION=%NGINX_VERSION_OVERRIDE%

REM 架构检测
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set ARCH=x86_64
) else if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set ARCH=x86_64
) else (
    set ARCH=x86
)

set SCRIPT_DIR=%~dp0
set DEST_DIR=%SCRIPT_DIR%bin
if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"

REM 如果 bin/nginx.exe 已经存在,说明已经装过,跳过(普通用户 clone 后 bin/ 已有 nginx,不需要重装)
if exist "%DEST_DIR%\nginx-windows-%ARCH%.exe" (
    echo bin\nginx-windows-%ARCH%.exe 已存在,跳过下载
    echo   如需升级到新版本,先删除再跑此脚本
    endlocal
    exit /b 0
)

set DOWNLOAD_URL=https://nginx.org/download/nginx-%NGINX_VERSION%.zip
set ZIP_PATH=%DEST_DIR%\nginx.zip

echo === 下载 %DOWNLOAD_URL% ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%ZIP_PATH%' -UseBasicParsing } catch { exit 1 }"
if errorlevel 1 goto :download_error

echo === 解压 ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%ZIP_PATH%' -DestinationPath '%DEST_DIR%' -Force"
if errorlevel 1 goto :extract_error

REM 找解压目录(nginx-<version>)
set EXTRACTED_DIR=
for /d %%D in ("%DEST_DIR%\nginx-*") do (
    if /i not "%%~nxD"=="bin" set EXTRACTED_DIR=%%D
)

if "%EXTRACTED_DIR%"=="" goto :no_exe_error
if not exist "%EXTRACTED_DIR%\nginx.exe" goto :no_exe_error

set TARGET=%DEST_DIR%\nginx-windows-%ARCH%.exe
copy /Y "%EXTRACTED_DIR%\nginx.exe" "%TARGET%" >nul
copy /Y "%TARGET%" "%DEST_DIR%\nginx.exe" >nul

REM 清理临时文件
rmdir /S /Q "%EXTRACTED_DIR%" >nul 2>&1
del "%ZIP_PATH%" >nul 2>&1

echo === 已安装 ===
echo   %DEST_DIR%\nginx.exe ^(%ARCH%^)
"%DEST_DIR%\nginx.exe" -v 2>&1
endlocal
goto :eof

:download_error
echo 下载失败,检查网络或用 NGINX_VERSION_OVERRIDE 指定其他版本
endlocal
exit /b 1

:extract_error
echo 解压失败
endlocal
exit /b 1

:no_exe_error
echo 解压后找不到 nginx.exe
endlocal
exit /b 1
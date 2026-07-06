# reload-server.ps1 - Windows 上的 Nacos URL 热更新服务
# 用法(start.bat 调用): powershell -ExecutionPolicy Bypass -File bin/reload-server.ps1 <project_dir>
#
# 等价于 reload-server.py,但用 PowerShell 自带的 System.Net.HttpListener,
# 不依赖 Python / 其他第三方运行时(Win10/11 自带 PowerShell 5+)

param(
    [string]$ProjectDir = $PSScriptRoot + "\..",
    [int]$Port = 18081
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:NginxConf = Join-Path $ProjectDir "nginx-local.conf"
$script:NginxRendered = Join-Path $ProjectDir ".nginx.rendered.conf"
$script:LogFile = Join-Path $ProjectDir ".reload-server.log"
$script:PidFile = Join-Path $ProjectDir ".reload-server.pid"

# 写自己的 pid 文件
Set-Content -Path $script:PidFile -Value $PID -Encoding ASCII -NoNewline

function Find-Nginx {
    $candidates = @(
        (Join-Path $ProjectDir "bin\nginx-windows-amd64.exe"),
        (Join-Path $ProjectDir "bin\nginx.exe")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    }
    $cmd = Get-Command nginx -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:NginxBin = Find-Nginx

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "o"), $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Get-NacosUrl {
    if (-not (Test-Path $script:NginxConf)) { return $null }
    $content = Get-Content $script:NginxConf -Raw -Encoding UTF8
    if ($content -match 'proxy_pass\s+https?://([^/]+)/nacos/;') {
        return "http://$($Matches[1])/nacos/"
    }
    return $null
}

function Set-NacosUrl {
    param([string]$Host)
    $content = Get-Content $script:NginxConf -Raw -Encoding UTF8
    $newContent = [regex]::Replace($content, '(proxy_pass\s+https?://)[^/]+(/nacos/;)', "`$1$Host`$2")
    Set-Content -Path $script:NginxConf -Value $newContent -Encoding UTF8 -NoNewline
}

function Render-NginxConf {
    # PowerShell 渲染 nginx 配置模板(替代 bash 的 envsubst)
    $pidFileFwd = (Join-Path $ProjectDir ".nginx.pid").Replace("\", "/")
    $logFileFwd = (Join-Path $ProjectDir ".nginx.log").Replace("\", "/")
    $dashRoot = $ProjectDir.Replace("\", "/").TrimEnd("/")

    $template = Get-Content $script:NginxConf -Raw -Encoding UTF8
    $rendered = $template -replace '\$\{DASHBOARD_ROOT\}', $dashRoot

    $wrapper = @"
worker_processes 1;
pid $pidFileFwd;
error_log $logFileFwd warn;
events { worker_connections 256; }
http {
  default_type application/octet-stream;
  access_log off;
  sendfile on;
$rendered}
"@
    Set-Content -Path $script:NginxRendered -Value $wrapper -Encoding UTF8 -NoNewline
}

function Invoke-NginxReload {
    if (-not $script:NginxBin) {
        return @{ ok = $false; error = "找不到 nginx 二进制" }
    }
    if (-not (Test-Path $script:NginxRendered)) {
        return @{ ok = $false; error = "找不到 rendered 配置,请先跑 start.bat" }
    }
    try {
        $output = & $script:NginxBin -t -c $script:NginxRendered 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ ok = $false; error = "配置校验失败:$output" }
        }
        $reloadOutput = & $script:NginxBin -s reload -c $script:NginxRendered 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ ok = $false; error = "reload 失败:$reloadOutput" }
        }
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; error = "reload 异常:$_" }
    }
}

function Send-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [hashtable]$Data,
        [int]$Status = 200
    )
    $json = $Data | ConvertTo-Json -Depth 5 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

try {
    $listener.Start()
    Write-Log "reload-server listening on http://127.0.0.1:$Port (project: $ProjectDir)"
} catch {
    Write-Log "启动失败:$_"
    exit 1
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request

        # CORS headers
        $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
        $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($request.HttpMethod -eq "OPTIONS") {
            $context.Response.StatusCode = 204
            $context.Response.Close()
            continue
        }

        $path = $request.Url.LocalPath
        $method = $request.HttpMethod

        try {
            if ($path -eq "/api/health" -and $method -eq "GET") {
                Send-JsonResponse -Context $context -Data @{ ok = $true; nginx = $script:NginxBin }
            } elseif ($path -eq "/api/nacos-url" -and $method -eq "GET") {
                Send-JsonResponse -Context $context -Data @{ url = (Get-NacosUrl) }
            } elseif ($path -eq "/api/nacos-url" -and $method -eq "POST") {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()

                try {
                    $data = $body | ConvertFrom-Json
                } catch {
                    Send-JsonResponse -Context $context -Data @{ ok = $false; error = "请求体不是合法 JSON" } -Status 400
                    continue
                }

                $url = if ($data.url) { $data.url.Trim() } else { "" }

                if ($url -notmatch '^https?://([^/\s]+)/nacos/?$') {
                    Send-JsonResponse -Context $context -Data @{ ok = $false; error = "格式应为 http://host:port/nacos/(或 https://)" } -Status 400
                    continue
                }

                $host = $Matches[1]
                try {
                    Set-NacosUrl -Host $host
                    Render-NginxConf
                    $reloadResult = Invoke-NginxReload
                    if (-not $reloadResult.ok) {
                        Send-JsonResponse -Context $context -Data @{ ok = $false; error = $reloadResult.error } -Status 500
                    } else {
                        Send-JsonResponse -Context $context -Data @{ ok = $true; url = $url; host = $host }
                    }
                } catch {
                    Send-JsonResponse -Context $context -Data @{ ok = $false; error = "写入失败:$_" } -Status 500
                }
            } else {
                $context.Response.StatusCode = 404
                $context.Response.Close()
            }
        } catch {
            Write-Log "请求处理异常:$_"
            try {
                Send-JsonResponse -Context $context -Data @{ ok = $false; error = "服务器异常:$_" } -Status 500
            } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Remove-Item $script:PidFile -ErrorAction SilentlyContinue
    Write-Log "reload-server stopped"
}
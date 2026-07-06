#!/usr/bin/env bash
# 容器内启动脚本(作为 Docker ENTRYPOINT)
# 用现有的 bin/reload-server.sh(0 额外依赖,容器内也有 bash + nc)做热更新

set -euo pipefail

PROJECT_DIR=/app
TEMPLATE="$PROJECT_DIR/nginx-local.conf"
RENDERED="$PROJECT_DIR/.nginx.rendered.conf"
PID_FILE="$PROJECT_DIR/.nginx.pid"
LOG_FILE="$PROJECT_DIR/.nginx.log"
RELOAD_PID_FILE="$PROJECT_DIR/.reload-server.pid"
RELOAD_LOG_FILE="$PROJECT_DIR/.reload-server.log"

# 1. 渲染 nginx 配置(容器内 worker 跑 root 避免权限问题)
export DASHBOARD_ROOT="$PROJECT_DIR"
{
  echo "user root;"
  echo "worker_processes 1;"
  echo "pid $PID_FILE;"
  echo "error_log $LOG_FILE warn;"
  echo "events { worker_connections 256; }"
  echo "http {"
  echo "  default_type application/octet-stream;"
  echo "  access_log off;"
  echo "  sendfile on;"
  envsubst '${DASHBOARD_ROOT}' < "$TEMPLATE"
  echo "}"
} > "$RENDERED"

# 2. 启动 reload-server(后台,改 nginx-local.conf + reload)
nohup bash "$PROJECT_DIR/bin/reload-server.sh" "$PROJECT_DIR" >> "$RELOAD_LOG_FILE" 2>&1 &
echo $! > "$RELOAD_PID_FILE"
sleep 0.5

# 3. 校验并启动 nginx(前台,daemon off 让容器保持运行)
nginx -t -c "$RENDERED"
exec nginx -c "$RENDERED" -g "daemon off;"
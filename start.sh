#!/usr/bin/env bash
# 启动 nacos-ops-dashboard 的本地 nginx
# 用法: ./start.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$PROJECT_DIR/nginx-local.conf"
RENDERED="$PROJECT_DIR/.nginx.rendered.conf"
PID_FILE="$PROJECT_DIR/.nginx.pid"
LOG_FILE="$PROJECT_DIR/.nginx.log"

# 平台检测(规范化)
normalize_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    FreeBSD) echo "freebsd" ;;
    OpenBSD) echo "openbsd" ;;
    NetBSD) echo "netbsd" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "$(uname -s | tr 'A-Z' 'a-z')" ;;
  esac
}
normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "armv7" ;;
    i386|i686) echo "x86" ;;
    *) echo "$(uname -m)" ;;
  esac
}

CURRENT_OS="$(normalize_os)"
CURRENT_ARCH="$(normalize_arch)"

# nginx 查找顺序:
#   1. 项目自带: bin/nginx-<当前 os>-<当前 arch>(精确匹配)
#   2. 项目自带: bin/nginx 软链接
#   3. 系统 PATH
NGINX_BIN="$PROJECT_DIR/bin/nginx-$CURRENT_OS-$CURRENT_ARCH"
[[ ! -x "$NGINX_BIN" ]] && NGINX_BIN="$PROJECT_DIR/bin/nginx"
if [[ ! -x "$NGINX_BIN" ]]; then
  NGINX_BIN="$(command -v nginx || true)"
fi
if [[ -z "$NGINX_BIN" ]]; then
  echo "找不到 nginx。请先跑 ./bin/install-nginx.sh,或在 Debian/Ubuntu 执行 sudo apt install nginx,macOS 执行 brew install nginx" >&2
  exit 1
fi

# 已运行则先停
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "已经在跑 (pid $(cat "$PID_FILE")),先停掉再启" >&2
  "$PROJECT_DIR/stop.sh"
fi

# 启动 reload-server(用于前端弹窗动态改 Nacos 地址)
# 选择策略:
#   1. 优先 bash + nc(bin/reload-server.sh)— Linux 完美 0 依赖,Mac 上若启动失败自动 fallback
#   2. fallback python3(reload-server.py)— 稳定可靠,Mac CLT 自带 python3
#   3. 都不可用:提示弹窗功能不可用
RELOAD_PID_FILE="$PROJECT_DIR/.reload-server.pid"
RELOAD_LOG_FILE="$PROJECT_DIR/.reload-server.log"
RELOAD_PORT="${RELOAD_PORT:-18081}"
if [[ -f "$RELOAD_PID_FILE" ]] && kill -0 "$(cat "$RELOAD_PID_FILE")" 2>/dev/null; then
  : # reload-server 已在跑,跳过
else
  RELOAD_STARTED=0
  # 1. 优先 bash + nc
  if [[ -f "$PROJECT_DIR/bin/reload-server.sh" ]] && command -v nc >/dev/null 2>&1; then
    nohup bash "$PROJECT_DIR/bin/reload-server.sh" "$PROJECT_DIR" >> "$RELOAD_LOG_FILE" 2>&1 &
    RELOAD_PID=$!
    echo "$RELOAD_PID" > "$RELOAD_PID_FILE"
    # 等 0.5s,验证端口真的监听了(bash 3.2 + FIFO 在某些平台可能启动失败)
    sleep 0.5
    if lsof -nP -iTCP:"$RELOAD_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      RELOAD_STARTED=1
    else
      # bash reload-server 启动失败,清理后 fallback Python
      kill "$RELOAD_PID" 2>/dev/null
      rm -f "$RELOAD_PID_FILE"
    fi
  fi
  # 2. fallback Python
  if [[ "$RELOAD_STARTED" -eq 0 ]] && [[ -f "$PROJECT_DIR/bin/reload-server.py" ]] && command -v python3 >/dev/null 2>&1; then
    nohup python3 "$PROJECT_DIR/bin/reload-server.py" "$PROJECT_DIR" >> "$RELOAD_LOG_FILE" 2>&1 &
    echo $! > "$RELOAD_PID_FILE"
    RELOAD_STARTED=1
    sleep 0.3
  fi
  if [[ "$RELOAD_STARTED" -eq 0 ]]; then
    echo "提示:找不到合适的 reload-server,前端弹窗改地址功能不可用(其他功能正常)" >&2
  fi
fi

# 渲染模板 → 完整 nginx 主配置(events + http + server)
export DASHBOARD_ROOT="$PROJECT_DIR"
{
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

# 校验语法
"$NGINX_BIN" -t -c "$RENDERED"

# 后台启动
"$NGINX_BIN" -c "$RENDERED"

# 等 master 写 pid 文件
for _ in 1 2 3 4 5; do
  [[ -f "$PID_FILE" ]] && break
  sleep 0.2
done

cat <<EOF

nacos-ops-dashboard 已启动
  平台:    $CURRENT_OS / $CURRENT_ARCH
  nginx:   $NGINX_BIN
  reload:  $(cat "$RELOAD_PID_FILE" 2>/dev/null || echo "未启动") (pid)
  入口:    http://localhost:18080/dashboard/
  配置:    $RENDERED
  pid:     $PID_FILE ($(cat "$PID_FILE" 2>/dev/null || echo "?"))
  日志:    $LOG_FILE
  停止:    $PROJECT_DIR/stop.sh

EOF
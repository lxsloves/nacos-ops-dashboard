#!/usr/bin/env bash
# 停止 start.sh 拉起的 nginx + reload-server
# 用法: ./stop.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDERED="$PROJECT_DIR/.nginx.rendered.conf"
PID_FILE="$PROJECT_DIR/.nginx.pid"
RELOAD_PID_FILE="$PROJECT_DIR/.reload-server.pid"

# 同样的 nginx 查找优先级
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

NGINX_BIN="$PROJECT_DIR/bin/nginx-$CURRENT_OS-$CURRENT_ARCH"
[[ ! -x "$NGINX_BIN" ]] && NGINX_BIN="$PROJECT_DIR/bin/nginx"
if [[ ! -x "$NGINX_BIN" ]]; then
  NGINX_BIN="$(command -v nginx || true)"
fi

# 先停 reload-server
if [[ -f "$RELOAD_PID_FILE" ]]; then
  RPID="$(cat "$RELOAD_PID_FILE")"
  if kill -0 "$RPID" 2>/dev/null; then
    kill "$RPID" 2>/dev/null || true
  fi
  rm -f "$RELOAD_PID_FILE"
fi

if [[ ! -f "$PID_FILE" ]]; then
  echo "没有 pid 文件,似乎没在跑" >&2
  exit 0
fi

PID="$(cat "$PID_FILE")"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "pid $PID 已不在,清理 pid 文件" >&2
  rm -f "$PID_FILE"
  exit 0
fi

if [[ -n "$NGINX_BIN" ]]; then
  "$NGINX_BIN" -s stop -c "$RENDERED" 2>/dev/null || kill "$PID" 2>/dev/null || true
else
  kill "$PID" 2>/dev/null || true
fi
rm -f "$PID_FILE"
echo "已停止"
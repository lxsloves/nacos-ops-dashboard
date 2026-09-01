#!/usr/bin/env bash
# reload-server.sh - Nacos URL 热更新服务入口
# 用法(start.sh 调用): bash bin/reload-server.sh <project_dir> [port]
#
# 优先 Ruby WEBrick(macOS 自带,持久监听,且会 daemonize 脱离 IDE shell);
# 否则回退 bash+nc。

set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"
PORT="${2:-18081}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v ruby >/dev/null 2>&1 && [[ -f "$SELF_DIR/reload-server.rb" ]] \
  && ruby -rwebrick -e 'exit 0' 2>/dev/null; then
  exec ruby "$SELF_DIR/reload-server.rb" "$PROJECT_DIR" "$PORT"
fi

# ---------- 回退:bash + nc ----------
NGINX_CONF="$PROJECT_DIR/nginx-local.conf"
NGINX_RENDERED="$PROJECT_DIR/.nginx.rendered.conf"
PID_FILE="$PROJECT_DIR/.reload-server.pid"
LOG_FILE="$PROJECT_DIR/.reload-server.log"

find_nginx() {
  local os arch p
  os=$(uname -s | tr 'A-Z' 'a-z')
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
  esac
  for p in "$PROJECT_DIR/bin/nginx-$os-$arch" "$PROJECT_DIR/bin/nginx"; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return; }
  done
  command -v nginx 2>/dev/null || true
}

NGINX_BIN="$(find_nginx)"

get_nacos_url() {
  [[ -f "$NGINX_CONF" ]] || { printf '\n'; return; }
  grep -oE 'proxy_pass[[:space:]]+https?://[^/]+/nacos/;' "$NGINX_CONF" 2>/dev/null \
    | head -1 | sed -nE 's|.*https?://([^/]+)/nacos/;.*|http://\1/nacos/|p'
}

set_nacos_url() {
  local host="$1" tmp
  [[ -f "$NGINX_CONF" ]] || return 1
  tmp="${NGINX_CONF}.tmp.$$"
  sed -E "s|(proxy_pass[[:space:]]+https?://)[^/]+(/nacos/;)|\1${host}\2|" "$NGINX_CONF" > "$tmp" && mv "$tmp" "$NGINX_CONF"
}

render_conf() {
  local template
  template=$(<"$NGINX_CONF")
  template="${template//\$\{DASHBOARD_ROOT\}/$PROJECT_DIR}"
  cat > "$NGINX_RENDERED" <<EOF
worker_processes 1;
pid $PROJECT_DIR/.nginx.pid;
error_log $PROJECT_DIR/.nginx.log warn;
events { worker_connections 256; }
http {
  default_type application/octet-stream;
  access_log off;
  sendfile on;
${template}}
EOF
}

reload_nginx() {
  [[ -n "$NGINX_BIN" ]] || return 1
  [[ -f "$NGINX_RENDERED" ]] || return 1
  "$NGINX_BIN" -t -c "$NGINX_RENDERED" >/dev/null 2>&1 || return 1
  "$NGINX_BIN" -s reload -c "$NGINX_RENDERED" >/dev/null 2>&1
}

log_request() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG_FILE"
}

handle_request() {
  local request_line method path line content_length body status resp_body url host lower proto clean_url

  if ! IFS= read -r request_line; then
    return 1
  fi
  request_line="${request_line%$'\r'}"
  method="${request_line%% *}"
  path="${request_line#* }"
  path="${path%% *}"
  path="${path%\?*}"

  content_length=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == content-length:* ]]; then
      content_length=$(printf '%s' "$line" | sed -nE 's/^[Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+).*/\1/p')
      [[ -z "$content_length" ]] && content_length=0
    fi
  done

  body=""
  if [[ "$content_length" -gt 0 ]]; then
    if ! IFS= read -r -n "$content_length" body 2>/dev/null; then
      body=""
    fi
  fi

  status=200
  resp_body=""
  case "$path" in
    /api/health)
      resp_body='{"ok":true,"runtime":"bash+nc"}'
      ;;
    /api/nacos-url)
      if [[ "$method" == "GET" ]]; then
        url=$(get_nacos_url)
        resp_body="{\"url\":\"$url\"}"
      elif [[ "$method" == "POST" ]]; then
        url=$(printf '%s' "$body" | sed -nE 's|.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*|\1|p')
        if [[ "$url" =~ ^https?://([^/]+)/nacos(/|$|[?#]) ]]; then
          host="${BASH_REMATCH[1]}"
          proto="http"
          [[ "$url" =~ ^https:// ]] && proto="https"
          clean_url="${proto}://${host}/nacos/"
          if set_nacos_url "$host" && render_conf && reload_nginx; then
            resp_body="{\"ok\":true,\"url\":\"$clean_url\",\"host\":\"$host\"}"
          else
            status=500
            resp_body='{"ok":false,"error":"reload 失败(检查 .reload-server.log 和 .nginx.log)"}'
          fi
        else
          status=400
          resp_body='{"ok":false,"error":"格式应为 http://host:port/nacos/(可以是完整浏览器 URL,例如 http://host:8848/nacos/#/xxx)"}'
        fi
      fi
      ;;
    *)
      status=404
      resp_body='{"ok":false,"error":"not found"}'
      ;;
  esac

  local body_bytes
  body_bytes=$(printf '%s' "$resp_body" | wc -c | tr -d ' ')
  printf 'HTTP/1.1 %s OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s' \
    "$status" "$body_bytes" "$resp_body"

  log_request "$method $path -> $status"
  return 0
}

detect_nc() {
  case "$(uname -s)" in
    Darwin|*BSD) echo "nc -l 127.0.0.1 $PORT" ;;
    *)           echo "nc -l -p $PORT" ;;
  esac
}

NC_CMD=$(detect_nc)

# bash+nc 也尽量脱离会话(mac 无 setsid 时退化为 nohup 已有的行为)
if command -v setsid >/dev/null 2>&1; then
  # re-exec under setsid once
  if [[ -z "${RELOAD_SETSID:-}" ]]; then
    export RELOAD_SETSID=1
    exec setsid bash "$0" "$PROJECT_DIR" "$PORT"
  fi
fi

echo $$ > "$PID_FILE"
log_request "reload-server (bash+nc) listening on 0.0.0.0:$PORT"
trap '' PIPE
trap '[[ "$(cat "$PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$PID_FILE"' EXIT INT TERM

while true; do
  RESP=$(mktemp -u)
  if ! mkfifo "$RESP" 2>/dev/null; then
    log_request "mkfifo 失败"
    sleep 0.5
    continue
  fi
  bash -c "$NC_CMD < '$RESP'" 2>/dev/null | handle_request > "$RESP" 2>/dev/null || true
  rm -f "$RESP"
done

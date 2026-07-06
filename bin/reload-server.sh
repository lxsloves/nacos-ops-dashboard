#!/usr/bin/env bash
# reload-server.sh - bash + nc 实现的 Nacos URL 热更新服务
# 用法(start.sh 调用): bash bin/reload-server.sh <project_dir> [port]
#
# 跨平台 0 额外依赖:
#   Linux bash 4+/5+:bash + nc + coreutils 都是系统默认
#   macOS bash 3.2.57:Apple 自带的旧版 bash + BSD nc + coreutils,够用

set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"
PORT="${2:-18081}"

NGINX_CONF="$PROJECT_DIR/nginx-local.conf"
NGINX_RENDERED="$PROJECT_DIR/.nginx.rendered.conf"
PID_FILE="$PROJECT_DIR/.reload-server.pid"
LOG_FILE="$PROJECT_DIR/.reload-server.log"

# ---------- nginx 二进制定位 ----------
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

# ---------- URL 读写 ----------
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

# ---------- HTTP 处理单个请求(从 stdin 读,响应写到 stdout) ----------
handle_request() {
  local request_line method path line content_length body status resp_body url host lower

  # 读 request line(GET /api/xxx HTTP/1.1)
  if ! IFS= read -r request_line; then
    return 1
  fi
  request_line="${request_line%$'\r'}"
  method="${request_line%% *}"
  path="${request_line#* }"
  path="${path%% *}"
  path="${path%\?*}"  # 去掉 query string

  # 读 headers,空行结束
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

  # 读 body(用 read -n 而不是 read -N,因为后者是 bash 4+ 才支持)
  body=""
  if [[ "$content_length" -gt 0 ]]; then
    if ! IFS= read -r -n "$content_length" body 2>/dev/null; then
      body=""
    fi
  fi

  # 路由
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
        # 放宽:接受完整浏览器 URL(包含 fragment/query/path 都行),只要 protocol://host[:port]/nacos 在
        # 例:"http://172.18.66.210:8848/nacos/#/serviceManagement?..." → host=172.18.66.210:8848
        if [[ "$url" =~ ^https?://([^/]+)/nacos(/|$|[?#]) ]]; then
          host="${BASH_REMATCH[1]}"
          # 规范化 url:根据原始 url 的协议返回干净的 protocol://host/nacos/
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

  # 输出 HTTP 响应(Content-Length 必须是字节数,对中文要用 wc -c,不能用 ${#resp_body} 字符数)
  local body_bytes
  body_bytes=$(printf '%s' "$resp_body" | wc -c | tr -d ' ')
  printf 'HTTP/1.1 %s OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s' \
    "$status" "$body_bytes" "$resp_body"

  log_request "$method $path -> $status"
  return 0
}

# ---------- 检测 nc 类型(Mac/BSD 用 BSD nc,Linux 用 GNU nc) ----------
detect_nc() {
  case "$(uname -s)" in
    Darwin|*BSD) echo "nc -l 127.0.0.1 $PORT" ;;
    *)           echo "nc -l -p $PORT" ;;
  esac
}

NC_CMD=$(detect_nc)

# ---------- 启动 ----------
echo $$ > "$PID_FILE"
log_request "reload-server (bash+nc) listening on 0.0.0.0:$PORT"
trap 'rm -f "$PID_FILE" 2>/dev/null' EXIT INT TERM

# 主循环:每次连接用 FIFO 把响应写回 nc
while true; do
  RESP=$(mktemp -u)
  if ! mkfifo "$RESP" 2>/dev/null; then
    log_request "mkfifo 失败"
    sleep 0.5
    continue
  fi
  # nc 把客户端输入转给 handle_request 的 stdin
  # handle_request 的 stdout 通过 $RESP 写回 nc 的 stdin(nc 再写回客户端)
  bash -c "$NC_CMD < '$RESP'" 2>/dev/null | handle_request > "$RESP" 2>/dev/null || true
  rm -f "$RESP"
done
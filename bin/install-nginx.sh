#!/usr/bin/env bash
# 把系统 nginx 拷一份到本项目的 bin/ 下,让项目自带 nginx,不依赖系统 PATH
# 用法: ./bin/install-nginx.sh
#
# 各平台行为:
#   macOS / Linux / BSD: 从系统已装 nginx 拷贝到 bin/nginx-<os>-<arch>
#   Windows (Git Bash):  从 nginx.org 下载官方 nginx/Windows 包,解压到 bin/

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$PROJECT_DIR/bin"
mkdir -p "$DEST_DIR"

# 平台规范化
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

OS="$(normalize_os)"
ARCH="$(normalize_arch)"

# ---------- Windows (Git Bash / MSYS / Cygwin) 分支 ----------
if [[ "$OS" == "windows" ]]; then
  # 从 nginx.org 下载官方 nginx/Windows 包
  # Windows nginx 是纯二进制 zip,解压即可,不需要编译
  NGINX_VERSION="${NGINX_VERSION:-1.27.5}"
  DOWNLOAD_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.zip"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  # 下载
  if command -v curl >/dev/null 2>&1; then
    echo "下载 $DOWNLOAD_URL ..."
    curl -fSL --progress-bar -o "$TMP_DIR/nginx.zip" "$DOWNLOAD_URL" || {
      echo "下载失败,检查网络或设置 NGINX_VERSION 环境变量" >&2
      exit 1
    }
  elif command -v wget >/dev/null 2>&1; then
    echo "下载 $DOWNLOAD_URL ..."
    wget -q --show-progress -O "$TMP_DIR/nginx.zip" "$DOWNLOAD_URL" || {
      echo "下载失败,检查网络或设置 NGINX_VERSION 环境变量" >&2
      exit 1
    }
  else
    echo "需要 curl 或 wget 来下载 nginx for Windows" >&2
    exit 1
  fi

  # 解压
  if ! command -v unzip >/dev/null 2>&1; then
    echo "需要 unzip(Git Bash 自带;如果没装请用 pacman -S unzip 之类)" >&2
    exit 1
  fi
  unzip -q "$TMP_DIR/nginx.zip" -d "$TMP_DIR"

  EXTRACTED_DIR="$(find "$TMP_DIR" -maxdepth 1 -mindepth 1 -type d -name "nginx-*" | head -1)"
  if [[ -z "$EXTRACTED_DIR" || ! -f "$EXTRACTED_DIR/nginx.exe" ]]; then
    echo "解压后找不到 nginx.exe" >&2
    exit 1
  fi

  TARGET="$DEST_DIR/nginx-$OS-$ARCH.exe"
  cp "$EXTRACTED_DIR/nginx.exe" "$TARGET"
  chmod +x "$TARGET" 2>/dev/null || true

  # Windows 软链接需要管理员权限,直接复制一份简化(代价是多占 1.5MB)
  cp "$TARGET" "$DEST_DIR/nginx.exe"

  echo "已安装: $DEST_DIR/nginx.exe ($OS/$ARCH)"
  echo "提示:Windows 上 nginx 路径里请用正斜杠 / 或双反斜杠 \\\\"
  exit 0
fi

# ---------- POSIX 平台(macOS / Linux / BSD)分支 ----------

# 找系统 nginx 真实路径(按优先级遍历)
find_system_nginx() {
  # 1. PATH 里的 nginx
  if command -v nginx >/dev/null 2>&1; then
    command -v nginx
    return
  fi
  # 2. macOS homebrew(arm64 / x86_64)
  if [[ "$OS" == "darwin" ]]; then
    if command -v brew >/dev/null 2>&1 && brew --prefix nginx >/dev/null 2>&1; then
      echo "$(brew --prefix nginx)/bin/nginx"
      return
    fi
    [[ -x /opt/homebrew/bin/nginx ]] && { echo "/opt/homebrew/bin/nginx"; return; }
    [[ -x /usr/local/bin/nginx ]] && { echo "/usr/local/bin/nginx"; return; }
  fi
  # 3. Linux 常见路径(覆盖主流发行版 + Alpine)
  for p in \
    /usr/sbin/nginx \
    /usr/bin/nginx \
    /sbin/nginx \
    /usr/local/sbin/nginx \
    /usr/local/bin/nginx \
    /opt/nginx/sbin/nginx \
    /opt/nginx/bin/nginx; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
}

SRC="$(find_system_nginx || true)"

if [[ -z "$SRC" || ! -e "$SRC" ]]; then
  echo "找不到系统 nginx。请先安装:" >&2
  echo "  macOS:             brew install nginx" >&2
  echo "  Debian / Ubuntu:   sudo apt install nginx-core" >&2
  echo "  RHEL / CentOS:     sudo yum install nginx" >&2
  echo "  Alpine:            sudo apk add nginx" >&2
  exit 1
fi

# 解析符号链接到真实文件
if [[ -L "$SRC" ]]; then
  REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SRC" 2>/dev/null || readlink -f "$SRC" 2>/dev/null || echo "$SRC")"
  [[ -f "$REAL" ]] && SRC="$REAL"
fi

if [[ ! -f "$SRC" ]]; then
  echo "nginx 路径不是普通文件: $SRC" >&2
  exit 1
fi

# 拷贝到 bin/nginx-<os>-<arch>
TARGET="$DEST_DIR/nginx-$OS-$ARCH"
# 旧文件可能 read-only,先放宽写权限让 cp 能覆盖
[[ -f "$TARGET" ]] && chmod u+w "$TARGET" 2>/dev/null || true
cp "$SRC" "$TARGET"
chmod +x "$TARGET"

# 软链接 bin/nginx 指向当前平台版本
ln -sfn "nginx-$OS-$ARCH" "$DEST_DIR/nginx"

echo "已安装: $DEST_DIR/nginx -> $TARGET ($OS/$ARCH)"
"$DEST_DIR/nginx" -v 2>&1 || echo "(已安装,版本查询被系统拦截 — 不影响使用)"
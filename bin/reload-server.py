#!/usr/bin/env python3
"""
Reload server for nacos-ops-dashboard.
监听 127.0.0.1:18081,提供 Nacos 地址热更新能力。
  GET  /api/nacos-url    返回当前 Nacos URL
  POST /api/nacos-url    更新 Nacos URL + reload nginx
用法: python3 reload-server.py <project_dir> [port]
"""
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PROJECT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 18081

NGINX_CONF = os.path.join(PROJECT_DIR, "nginx-local.conf")
NGINX_RENDERED = os.path.join(PROJECT_DIR, ".nginx.rendered.conf")
LOG_FILE = os.path.join(PROJECT_DIR, ".reload-server.log")


def find_nginx():
    """跟 start.sh 同优先级:bin/nginx-<os>-<arch> -> bin/nginx -> 系统 PATH"""
    candidates = []
    # 平台特定
    import platform
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch_map = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "arm64", "arm64": "arm64"}
    arch = arch_map.get(machine, machine)
    candidates.append(os.path.join(PROJECT_DIR, "bin", f"nginx-{system}-{arch}"))
    candidates.append(os.path.join(PROJECT_DIR, "bin", "nginx"))
    if system == "windows":
        candidates.append(os.path.join(PROJECT_DIR, "bin", f"nginx-{system}-{arch}.exe"))
        candidates.append(os.path.join(PROJECT_DIR, "bin", "nginx.exe"))
    for p in candidates:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    from shutil import which
    return which("nginx") or ""


NGINX_BIN = find_nginx()


def read_nacos_url():
    if not os.path.isfile(NGINX_CONF):
        return None
    with open(NGINX_CONF, "r", encoding="utf-8") as f:
        content = f.read()
    m = re.search(r'proxy_pass\s+https?://([^/]+)/nacos/;', content)
    return f"http://{m.group(1)}/nacos/" if m else None


def write_nacos_url(host):
    """修改 nginx-local.conf 里的 proxy_pass 行,host 应为 ip:port 格式"""
    with open(NGINX_CONF, "r", encoding="utf-8") as f:
        content = f.read()
    new_content = re.sub(
        r'(proxy_pass\s+https?://)[^/]+(/nacos/;)',
        rf'\g<1>{host}\g<2>',
        content,
    )
    with open(NGINX_CONF, "w", encoding="utf-8") as f:
        f.write(new_content)


def reload_nginx():
    if not NGINX_BIN:
        return False, "找不到 nginx 二进制"
    if not os.path.isfile(NGINX_RENDERED):
        return False, f"找不到 rendered 配置 {NGINX_RENDERED}(请先跑 start.sh)"
    try:
        # 先 -t 校验新配置
        test = subprocess.run(
            [NGINX_BIN, "-t", "-c", NGINX_RENDERED],
            capture_output=True, text=True, timeout=10
        )
        if test.returncode != 0:
            return False, f"配置校验失败:{test.stderr.strip() or test.stdout.strip()}"
        # 重新渲染(reload 时 nginx -s reload 不重新解析配置文件,需要重启或重新渲染)
        # 简单做法:重新跑 start.sh 的渲染逻辑,但我们这里只 reload
        # 注意:nginx -s reload 只 reload 已经加载的配置,不会重新读取 nginx-local.conf
        # 所以需要重新渲染 .nginx.rendered.conf 后再 reload
        result = subprocess.run(
            [NGINX_BIN, "-s", "reload", "-c", NGINX_RENDERED],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return False, f"reload 失败:{result.stderr.strip() or result.stdout.strip()}"
        return True, None
    except subprocess.TimeoutExpired:
        return False, "nginx 命令超时"
    except Exception as e:
        return False, f"reload 异常:{e}"


def re_render_nginx_conf():
    """重新渲染 .nginx.rendered.conf,因为 nginx -s reload 不会重新读 nginx-local.conf"""
    import shutil
    envsubst = shutil.which("envsubst")
    if not envsubst:
        # 兜底:用 Python 做替换
        return _render_with_python()
    env = os.environ.copy()
    env["DASHBOARD_ROOT"] = PROJECT_DIR.replace("\\", "/")
    with open(NGINX_CONF, "r", encoding="utf-8") as f:
        template = f.read()
    rendered = subprocess.run(
        [envsubst, "${DASHBOARD_ROOT}"],
        input=template, capture_output=True, text=True, env=env, timeout=10
    )
    if rendered.returncode != 0:
        return False
    pid_file = os.path.join(PROJECT_DIR, ".nginx.pid")
    log_file = os.path.join(PROJECT_DIR, ".nginx.log")
    wrapper = (
        "worker_processes 1;\n"
        f"pid {pid_file};\n"
        f"error_log {log_file} warn;\n"
        "events { worker_connections 256; }\n"
        "http {\n"
        "  default_type application/octet-stream;\n"
        "  access_log off;\n"
        "  sendfile on;\n"
        f"{rendered.stdout}"
        "}\n"
    )
    with open(NGINX_RENDERED, "w", encoding="utf-8") as f:
        f.write(wrapper)
    return True


def _render_with_python():
    """Windows 上可能没有 envsubst,用 Python 替代"""
    pid_file = os.path.join(PROJECT_DIR, ".nginx.pid")
    log_file = os.path.join(PROJECT_DIR, ".nginx.log")
    with open(NGINX_CONF, "r", encoding="utf-8") as f:
        template = f.read()
    rendered = template.replace("${DASHBOARD_ROOT}", PROJECT_DIR.replace("\\", "/"))
    wrapper = (
        "worker_processes 1;\n"
        f"pid {pid_file.replace(chr(92), '/')};\n"
        f"error_log {log_file.replace(chr(92), '/')} warn;\n"
        "events { worker_connections 256; }\n"
        "http {\n"
        "  default_type application/octet-stream;\n"
        "  access_log off;\n"
        "  sendfile on;\n"
        f"{rendered}"
        "}\n"
    )
    with open(NGINX_RENDERED, "w", encoding="utf-8") as f:
        f.write(wrapper)
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # 日志写到文件,不刷 stdout
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(f"{self.address_string()} {format % args}\n")
        except Exception:
            pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/nacos-url":
            self._json({"url": read_nacos_url() or ""})
        elif self.path == "/api/health":
            self._json({"ok": True, "nginx": NGINX_BIN})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/api/nacos-url":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except Exception:
            self._json({"ok": False, "error": "请求体不是合法 JSON"}, 400)
            return
        url = (data.get("url") or "").strip()
        m = re.match(r'^https?://([^/\s]+)/nacos/?$', url)
        if not m:
            self._json({"ok": False, "error": "格式应为 http://host:port/nacos/(或 https://)"}, 400)
            return
        host = m.group(1)
        try:
            write_nacos_url(host)
            if not re_render_nginx_conf():
                self._json({"ok": False, "error": "渲染配置失败"}, 500)
                return
            ok, err = reload_nginx()
            if not ok:
                self._json({"ok": False, "error": err}, 500)
                return
            self._json({"ok": True, "url": url, "host": host})
        except Exception as e:
            self._json({"ok": False, "error": f"写入失败:{e}"}, 500)


if __name__ == "__main__":
    open(LOG_FILE, "a").close()
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"reload-server listening on http://127.0.0.1:{PORT} (project: {PROJECT_DIR})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
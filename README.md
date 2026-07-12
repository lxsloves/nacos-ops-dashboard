# nacos-ops-dashboard

本地 Nacos 实例管理面板。单文件 HTML + 自带 nginx,跑在 18080 端口。

## 干什么的

- 浏览本机 Nacos (`127.0.0.1:8848`) 的服务和实例
- 按 namespace / group / IP / 健康状态 / 上线状态筛选
- 批量上下线实例
- 浏览器里**弹窗配置 Nacos 地址**,自动写入 nginx 并 reload,无需重启

不是 Nacos 官方控制台的替代品,只是平时手动操作实例时省得在原版控制台里翻页面。

## 支持的平台

| OS | 架构 | nginx 来源 |
| --- | --- | --- |
| macOS | arm64 (Apple Silicon) | homebrew nginx(已 commit 到 bin/)|
| macOS | x86_64 (Intel) | homebrew nginx |
| Linux | x86_64 | apt / yum / dnf / apk nginx |
| Linux | arm64 / aarch64 | apt / yum nginx |
| Linux | armv7 | apt / yum nginx |
| Linux | x86 (32 位) | apt / yum nginx |
| Linux | Alpine | apk add nginx |
| FreeBSD / OpenBSD / NetBSD | 通用 | pkg / ports nginx |
| Windows | x86_64 | nginx.org 官方 nginx/Windows(已 commit 到 bin/)|

**所有平台 nginx 二进制都在 `bin/` 里,clone 后 0 安装**,直接 `./start.sh` 或 `start.bat` 即可。

## 启动

**macOS / Linux / BSD:**
```bash
./start.sh
# 浏览器打开 http://localhost:18080/dashboard/
# 第一次打开会弹窗让你设置 Nacos 地址 → 输入 → 自动 reload
./stop.sh
```

**Windows (cmd):**
```cmd
start.bat
:: 浏览器打开 http://localhost:18080/dashboard/
:: 第一次打开会弹窗让你设置 Nacos 地址 → 输入 → 自动 reload
stop.bat
```

## 运行时依赖

| 组件 | macOS / Linux / BSD | Windows |
| --- | --- | --- |
| bash / cmd | bash(系统自带)| cmd / PowerShell(系统自带)|
| `envsubst` | gettext 包(`brew install gettext` / `apt install gettext-base`)| PowerShell 替代 |
| `kill -0` 等 coreutils | 系统自带 | PowerShell `tasklist` 替代 |
| reload-server | bash + BSD nc(Mac) / GNU nc(Linux)| PowerShell 5+ |

**不需要任何额外安装**。如果某个工具真没装,`start.sh` / `start.bat` 会给出明确报错指引。

## Nacos 地址配置

- 第一次打开 dashboard,弹窗让你输入 Nacos URL(默认 `http://127.0.0.1:8848/nacos/`)
- 输入格式:`http://host:port/nacos/` 或 `https://host:port/nacos/`
- 提交后:改 `nginx-local.conf` → 重新渲染 → `nginx -s reload`,秒级生效
- 之后刷新页面不再弹窗(因为配置已经不是默认值)
- 想换地址:手动编辑 `nginx-local.conf` 第 22 行 `proxy_pass`,然后跑 `./start.sh`(会自动 reload)

## 升级 nginx

仓库维护者跑 `bin/install-nginx.sh`(macOS/Linux)或 `install-nginx.bat`(Windows),从 nginx.org 下载最新版替换 `bin/nginx-<os>-<arch>`,然后 commit。

## 端口冲突

默认 18080,要换就改 `nginx-local.conf` 第 2 行 `listen`,然后重启。

## 已知限制:Docker Desktop for Mac 访问不到内网 Nacos

如果你在 Mac 上用 `docker compose up -d` 跑,dashboard 反代到 **Mac 主机的内网 Nacos** 会失败(返回 504/502)。

**根因**:Docker Desktop 的 Docker 引擎是跑在一个 Linux 虚机里的(QEMU/HyperKit),这个 VM 跟 Mac 主机的网络栈是隔开的,容器无论走 bridge 还是 host 模式都到不了 Mac 的内网段(比如 `172.x` / `10.x` / `192.168.x` 等)。

**绕法**:
- **本机用 `./start.sh` 启动**(最简单),不走 Docker,直接走 Mac 自己的网络栈,内网/公网都通
- **Nacos 换成公网地址**,容器反代到公网 Nacos 是通的
- **在 Linux 机器上跑 Docker**(物理机/VM/云),没这限制

普通 Linux 上跑 Docker 没这个问题。

## 安全

- 仅监听本机 (`allow 127.0.0.1`, `deny all`)
- 管理接口 `/__admin__/` 只允许 127.0.0.1 访问,前端弹窗走它
- 凭据走浏览器 `sessionStorage`,**关闭浏览器标签页就清掉**
- 不要把 `nginx-local.conf` 部署到公网或者去掉访问限制
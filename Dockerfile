FROM nginx:alpine

# 装 bash(脚本需要)和 gettext(envsubst 需要)
# alpine 的 nginx 默认 listen 80,我们用 18080
RUN apk add --no-cache bash gettext

# 容器内工作目录
WORKDIR /app

# 复制项目文件(.dockerignore 排除了 .git、运行产物、Mac/Win 脚本等)
COPY . /app/

# 删除 Mac/Win 平台的 nginx 二进制及伪二进制,容器用系统自带的 /usr/sbin/nginx
RUN rm -f /app/bin/nginx /app/bin/nginx.exe /app/bin/nginx-darwin-arm64 /app/bin/nginx-windows-amd64.exe /app/bin/reload-server.ps1 /app/bin/reload-server.py

# 启动入口
RUN chmod +x /app/docker-start.sh
EXPOSE 18080

ENTRYPOINT ["/app/docker-start.sh"]
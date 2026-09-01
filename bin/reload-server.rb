#!/usr/bin/env ruby
# frozen_string_literal: true
# Nacos URL 热更新服务 (WEBrick)
# 用法: ruby bin/reload-server.rb <project_dir> [port]

require "webrick"
require "json"

project_dir = ARGV[0] || Dir.pwd
port = Integer(ARGV[1] || 18081)
nginx_conf = File.join(project_dir, "nginx-local.conf")
nginx_rendered = File.join(project_dir, ".nginx.rendered.conf")
pid_file = File.join(project_dir, ".reload-server.pid")
log_file = File.join(project_dir, ".reload-server.log")

def find_nginx(project_dir)
  os = `uname -s`.strip.downcase
  arch = `uname -m`.strip
  arch = "x86_64" if %w[x86_64 amd64].include?(arch)
  arch = "arm64" if %w[aarch64 arm64].include?(arch)
  [
    "#{project_dir}/bin/nginx-#{os}-#{arch}",
    "#{project_dir}/bin/nginx"
  ].each { |p| return p if File.executable?(p) }
  path = `command -v nginx 2>/dev/null`.strip
  path.empty? ? nil : path
end

def get_nacos_url(nginx_conf)
  return "" unless File.file?(nginx_conf)
  host = File.read(nginx_conf)[%r{proxy_pass\s+https?://([^/]+)/nacos/;}, 1]
  host ? "http://#{host}/nacos/" : ""
end

def set_nacos_url!(nginx_conf, host)
  text = File.read(nginx_conf)
  unless text =~ %r{proxy_pass\s+https?://[^/]+/nacos/;}
    raise "proxy_pass /nacos/ not found"
  end
  updated = text.sub(%r{(proxy_pass\s+https?://)[^/]+(/nacos/;)}) { "#{$1}#{host}#{$2}" }
  return if updated == text
  tmp = "#{nginx_conf}.tmp.#{Process.pid}"
  File.write(tmp, updated)
  File.rename(tmp, nginx_conf)
end

def render_conf!(project_dir, nginx_conf, nginx_rendered)
  template = File.read(nginx_conf).gsub("${DASHBOARD_ROOT}", project_dir)
  File.write(nginx_rendered, <<~CONF)
    worker_processes 1;
    pid #{project_dir}/.nginx.pid;
    error_log #{project_dir}/.nginx.log warn;
    events { worker_connections 256; }
    http {
      default_type application/octet-stream;
      access_log off;
      sendfile on;
    #{template}}
  CONF
end

def reload_nginx!(nginx_bin, nginx_rendered)
  raise "nginx not found" unless nginx_bin
  ok = system(nginx_bin, "-t", "-c", nginx_rendered, out: File::NULL, err: File::NULL)
  raise "nginx -t failed" unless ok
  ok = system(nginx_bin, "-s", "reload", "-c", nginx_rendered, out: File::NULL, err: File::NULL)
  raise "nginx -s reload failed" unless ok
end

def log!(log_file, msg)
  File.open(log_file, "a") { |f| f.puts("#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} #{msg}") }
end

# 脱离启动它的 shell/进程组,避免 Cursor/IDE 关掉终端时把服务一起杀掉
# (nginx 本身会 daemonize,所以不受影响;这边要对齐)
Process.daemon(true, true)

nginx_bin = find_nginx(project_dir)
File.write(pid_file, Process.pid.to_s)
log!(log_file, "reload-server (ruby/webrick) listening on 127.0.0.1:#{port}")

server = WEBrick::HTTPServer.new(
  Port: port,
  BindAddress: "127.0.0.1",
  AccessLog: [],
  Logger: WEBrick::Log.new(File.open(log_file, "a"), WEBrick::Log::WARN)
)

cleanup = proc do
  begin
    server.shutdown
  rescue StandardError
    nil
  end
  if File.file?(pid_file) && File.read(pid_file).strip == Process.pid.to_s
    File.delete(pid_file)
  end
end
trap("INT", &cleanup)
trap("TERM", &cleanup)

server.mount_proc("/api/health") do |_req, res|
  res["Content-Type"] = "application/json; charset=utf-8"
  res.body = '{"ok":true,"runtime":"ruby/webrick"}'
  log!(log_file, "GET /api/health -> 200")
end

server.mount_proc("/api/nacos-url") do |req, res|
  res["Content-Type"] = "application/json; charset=utf-8"
  res["Access-Control-Allow-Origin"] = "*"
  res["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  res["Access-Control-Allow-Headers"] = "Content-Type"

  if req.request_method == "OPTIONS"
    res.status = 200
    res.body = ""
    next
  end

  if req.request_method == "GET"
    res.body = JSON.generate({ "url" => get_nacos_url(nginx_conf) })
    log!(log_file, "GET /api/nacos-url -> 200")
    next
  end

  if req.request_method == "POST"
    begin
      body = JSON.parse(req.body || "{}")
      url = body["url"].to_s
      unless url =~ %r{\Ahttps?://([^/]+)/nacos(/|\z|[?#])}
        res.status = 400
        res.body = '{"ok":false,"error":"格式应为 http://host:port/nacos/(可以是完整浏览器 URL,例如 http://host:8848/nacos/#/xxx)"}'
        log!(log_file, "POST /api/nacos-url -> 400")
        next
      end
      host = Regexp.last_match(1)
      proto = url.start_with?("https://") ? "https" : "http"
      clean_url = "#{proto}://#{host}/nacos/"
      set_nacos_url!(nginx_conf, host)
      render_conf!(project_dir, nginx_conf, nginx_rendered)
      reload_nginx!(nginx_bin, nginx_rendered)
      res.body = JSON.generate({ "ok" => true, "url" => clean_url, "host" => host })
      log!(log_file, "POST /api/nacos-url -> 200")
    rescue StandardError => e
      res.status = 500
      res.body = JSON.generate({ "ok" => false, "error" => "reload 失败: #{e.message}" })
      log!(log_file, "POST /api/nacos-url -> 500 #{e.message}")
    end
    next
  end

  res.status = 404
  res.body = '{"ok":false,"error":"not found"}'
end

server.start

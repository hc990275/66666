#!/bin/bash

# ==============================================================================
# InstaBox 稳定极速版 (修复 1033 报错 + Xray原生多核 + 稳定HTTP/2隧道 + 主页)
# ==============================================================================

CF_TOKEN="$1"
TUNNEL_DOMAIN="$2"
UUID="$3"

if [ -z "$CF_TOKEN" ] || [ -z "$TUNNEL_DOMAIN" ]; then
    echo -e "\033[31m[错误] 缺少必要参数！\033[0m"
    echo -e "使用方法: bash $0 <Cloudflare_Token> <隧道域名> [可选UUID]"
    exit 1
fi

if [ -z "$UUID" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
        UUID=$(uuidgen)
    else
        UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d")
    fi
fi

WORK_DIR="/tmp/tunnel_server"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || exit 1

# 1. 安装基础依赖
echo -e "\033[32m[*] 正在检查系统依赖...\033[0m"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y nodejs curl unzip bc procps
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add nodejs curl unzip bc procps
fi

# 2. 下载官方 cloudflared
if [ ! -f "cloudflared" ]; then
    echo -e "\033[32m[*] 正在下载 cloudflared 核心...\033[0m"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    esac
    curl -sL --output cloudflared "$CF_URL"
    chmod +x cloudflared
fi

# 3. 下载 Xray-core
if [ ! -f "xray" ]; then
    echo -e "\033[32m[*] 正在拉取 Xray-core 核心...\033[0m"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
        aarch64|arm64) XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip" ;;
        *) XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" ;;
    esac
    curl -sL -o xray.zip "$XRAY_URL"
    unzip -o xray.zip xray >/dev/null 2>&1
    rm -f xray.zip
    chmod +x xray
fi

# 4. 生成 Web 控制中心主页 (端口 8080)
cat << 'WEB_EOF' > web_server.js
const http = require('http');
const PORT = 8080;
const DOMAIN = process.env.DOMAIN || '';
const UUID = process.env.UUID || '';

const server = http.createServer((req, res) => {
    const currentDomain = DOMAIN || req.headers.host || '127.0.0.1';
    const linkWs = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=ws&host=${currentDomain}&path=%2Fvless#InstaBox-WS`;
    const linkGrpc = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&mode=multi&sni=${currentDomain}#InstaBox-gRPC`;

    if (req.url === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({
            status: 'online',
            domain: currentDomain,
            uuid: UUID,
            uptime: Math.floor(process.uptime()),
            wsNode: linkWs,
            grpcNode: linkGrpc
        }));
        return;
    }

    const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>InstaBox 控制中心</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, sans-serif; background: #0b1120; color: #f8fafc; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 10px; padding: 20px; margin-bottom: 20px; }
        h1 { font-size: 20px; color: #38bdf8; margin-bottom: 16px; }
        h2 { font-size: 15px; color: #cbd5e1; margin-bottom: 10px; }
        .node-box { background: #0f172a; border: 1px solid #475569; padding: 12px; border-radius: 6px; font-family: monospace; font-size: 12px; word-break: break-all; color: #38bdf8; margin-bottom: 10px; }
        button { background: #0284c7; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; }
        button:hover { background: #0369a1; }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>InstaBox 服务管理控制台</h1>
            <p style="color:#10b981;font-weight:600;margin-bottom:8px;">● 状态：运行正常 (Active)</p>
            <p style="color:#94a3b8;font-size:13px;">域名：${currentDomain} | UUID: ${UUID}</p>
        </div>

        <div class="card">
            <h2>WebSocket 节点 (默认监听 8001，兼容所有客户端)</h2>
            <div class="node-box" id="node-ws">${linkWs}</div>
            <button onclick="navigator.clipboard.writeText(document.getElementById('node-ws').innerText); alert('复制成功！');">复制 WebSocket 节点</button>
        </div>

        <div class="card">
            <h2>gRPC 高并发节点</h2>
            <div class="node-box" id="node-grpc">${linkGrpc}</div>
            <button onclick="navigator.clipboard.writeText(document.getElementById('node-grpc').innerText); alert('复制成功！');">复制 gRPC 节点</button>
        </div>
    </div>
</body>
</html>`;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
});

server.listen(PORT, '0.0.0.0');
WEB_EOF

# 5. 配置 Xray 原生路由 (8001 端口直通，未匹配回落至 8080 显示主页)
cat << EOF > config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8001,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "level": 0 }],
        "decryption": "none",
        "fallbacks": [{ "dest": 8080 }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "port": 8003,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vless-grpc",
          "multiMode": true
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# 6. 防休眠守护脚本
cat << 'KEEP_EOF' > keepalive.sh
#!/bin/bash
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Active Heartbeat" >> /tmp/tunnel_server/keepalive.log
    curl -s -m 5 https://1.1.1.1 > /dev/null 2>&1
    tail -n 100 /tmp/tunnel_server/keepalive.log > /tmp/tunnel_server/keepalive.tmp 2>/dev/null && mv /tmp/tunnel_server/keepalive.tmp /tmp/tunnel_server/keepalive.log
    sleep 180
done
KEEP_EOF
chmod +x keepalive.sh

# 7. 清理历史残留进程
pkill -f "xray" 2>/dev/null
pkill -f "cloudflared" 2>/dev/null
pkill -f "node web_server.js" 2>/dev/null
pkill -f "keepalive.sh" 2>/dev/null

# 8. 启动全部进程
echo -e "\033[32m[*] 启动 Web 控制中心...\033[0m"
UUID="$UUID" DOMAIN="$TUNNEL_DOMAIN" nohup node web_server.js > web.log 2>&1 &

echo -e "\033[32m[*] 启动 Xray 代理引擎 (8001 端口)... \033[0m"
nohup ./xray -config config.json > xray.log 2>&1 &

# 关键修复点：使用纯粹稳定的 --protocol http2，去除异常参数
echo -e "\033[32m[*] 正在连接 Cloudflare 隧道 (HTTP/2)... \033[0m"
nohup ./cloudflared tunnel --protocol http2 run --token "$CF_TOKEN" > tunnel.log 2>&1 &

echo -e "\033[32m[*] 启动防休眠守护...\033[0m"
nohup ./keepalive.sh > /dev/null 2>&1 &

sleep 3

# 检查 cloudflared 是否真正在运行
if ! pgrep -x "cloudflared" > /dev/null; then
    echo -e "\033[31m[警告] cloudflared 启动失败！以下是最后报错日志：\033[0m"
    cat tunnel.log | tail -n 10
else
    echo -e "\n\033[32m====================================================\033[0m"
    echo -e "\033[32m[OK] 服务已完全恢复！Cloudflare 隧道已就绪。\033[0m"
    echo -e "管理控制台: https://${TUNNEL_DOMAIN}"
    echo -e "UUID: ${UUID}"
    echo -e "====================================================\n"
fi

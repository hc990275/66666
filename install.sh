#!/bin/bash

# ==============================================================================
# InstaBox 极速稳定版 (版本追踪 + 官方稳健参数 + Xray原生多核 + 网页后台 + 内部保活)
# ==============================================================================

# 当前脚本版本定义（每次修改代码请在此处递增，例如 v1.0.1 -> v1.0.2）
SCRIPT_VERSION="v1.0.1"

CF_TOKEN="$1"
TUNNEL_DOMAIN="$2"
UUID="$3"

if [ -z "$CF_TOKEN" ] || [ -z "$TUNNEL_DOMAIN" ]; then
    echo -e "\033[31m[错误] 缺少必要参数！\033[0m"
    echo -e "当前脚本版本: \033[33m$SCRIPT_VERSION\033[0m"
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

echo -e "\033[36m====================================================\033[0m"
echo -e "\033[36m[*] 正在执行部署，当前安装版本: $SCRIPT_VERSION\033[0m"
echo -e "\033[36m====================================================\033[0m"

# 1. 尝试安装依赖（自动判断 root 权限，普通用户自动跳过）
if [ "$(id -u)" -eq 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y nodejs curl unzip bc procps
    fi
fi

# 2. 准备 cloudflared 官方二进制
if [ ! -f "cloudflared" ]; then
    echo -e "\033[32m[*] 正在下载官方 cloudflared 二进制...\033[0m"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    esac
    curl -sL --output cloudflared "$CF_URL"
    chmod +x cloudflared
fi

# 3. 准备 Xray-core 官方核心
if [ ! -f "xray" ]; then
    echo -e "\033[32m[*] 正在拉取 Xray-core 官方极速核心...\033[0m"
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

# 4. 生成 Xray 高性能配置文件 (8001 端口直通，未匹配流量转入 8080 渲染主页)
cat << EOF > config.json
{
  "log": { "loglevel": "warning" },
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
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 5. 生成主页 Web 控制台 (监听本地 8080 端口，带版本号显示)
cat << 'WEB_EOF' > web_server.js
const http = require('http');
const PORT = 8080;
const DOMAIN = process.env.DOMAIN || '';
const UUID = process.env.UUID || '';
const VERSION = process.env.VERSION || 'v1.0.0';

const server = http.createServer((req, res) => {
    const currentDomain = DOMAIN || req.headers.host || '127.0.0.1';
    const linkWs = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=ws&host=${currentDomain}&path=%2Fvless#InstaBox-${VERSION}-WS`;
    const linkGrpc = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&mode=multi&sni=${currentDomain}#InstaBox-${VERSION}-gRPC`;

    if (req.url === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({
            status: 'online',
            version: VERSION,
            domain: currentDomain,
            uuid: UUID,
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
    <title>InstaBox 控制中心 - ${VERSION}</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b1120; color: #f8fafc; padding: 24px 16px; }
        .container { max-width: 820px; margin: 0 auto; }
        .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #1e293b; padding-bottom: 16px; margin-bottom: 24px; }
        .header h1 { font-size: 20px; color: #38bdf8; display: flex; align-items: center; gap: 8px; }
        .ver-badge { background: #3b82f6; color: white; padding: 2px 8px; border-radius: 6px; font-size: 12px; font-weight: normal; }
        .badge { background: #10b981; color: white; padding: 4px 12px; border-radius: 9999px; font-size: 13px; font-weight: bold; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
        .card h2 { font-size: 15px; color: #cbd5e1; margin-bottom: 12px; }
        .meta-line { color: #94a3b8; font-size: 13px; margin-bottom: 6px; }
        .meta-line strong { color: #f1f5f9; }
        .node-box { background: #0f172a; border: 1px solid #475569; padding: 12px; border-radius: 6px; font-family: monospace; font-size: 12px; word-break: break-all; color: #38bdf8; margin-bottom: 12px; }
        button { background: #0284c7; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: 500; }
        button:hover { background: #0369a1; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>InstaBox 服务管理控制台 <span class="ver-badge">${VERSION}</span></h1>
            <span class="badge">运行正常 (Active)</span>
        </div>
        <div class="card">
            <h2>运行环境</h2>
            <div class="meta-line">当前部署版本: <strong style="color: #38bdf8;">${VERSION}</strong></div>
            <div class="meta-line">绑定域名: <strong>${currentDomain}</strong></div>
            <div class="meta-line">代理核心: <strong>Xray-core 原生多核</strong></div>
            <div class="meta-line">用户 UUID: <strong>${UUID}</strong></div>
        </div>
        <div class="card">
            <h2>WebSocket 极速节点 (推荐)</h2>
            <div class="node-box" id="node-ws">${linkWs}</div>
            <button onclick="navigator.clipboard.writeText(document.getElementById('node-ws').innerText); alert('已复制！');">复制 WebSocket 节点</button>
        </div>
        <div class="card">
            <h2>gRPC 高并发节点</h2>
            <div class="node-box" id="node-grpc">${linkGrpc}</div>
            <button onclick="navigator.clipboard.writeText(document.getElementById('node-grpc').innerText); alert('已复制！');">复制 gRPC 节点</button>
        </div>
    </div>
</body>
</html>`;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
});

server.listen(PORT, '0.0.0.0');
WEB_EOF

# 6. 生成防休眠后台守护 (keepalive.sh)
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

# 8. 启动进程并传入版本环境变量
echo -e "\033[32m[*] 正在后台启动 Web 控制中心 (版本: $SCRIPT_VERSION)...\033[0m"
UUID="$UUID" DOMAIN="$TUNNEL_DOMAIN" VERSION="$SCRIPT_VERSION" nohup node web_server.js > web.log 2>&1 &

echo -e "\033[32m[*] 正在启动 Xray 原生多核引擎 (监听 8001 端口)...\033[0m"
nohup ./xray -config config.json > xray.log 2>&1 &

echo -e "\033[32m[*] 正在连接 Cloudflare 官方隧道...\033[0m"
nohup ./cloudflared tunnel run --token "$CF_TOKEN" > tunnel.log 2>&1 &

echo -e "\033[32m[*] 正在启动防休眠后台守护...\033[0m"
nohup ./keepalive.sh > /dev/null 2>&1 &

sleep 3

# 9. 状态自检与版本输出
if ! pgrep -f "cloudflared" > /dev/null; then
    echo -e "\033[31m[错误] cloudflared 启动失败，最后报错如下：\033[0m"
    tail -n 10 tunnel.log
else
    echo -e "\n\033[32m====================================================\033[0m"
    echo -e "\033[32m[OK] 部署成功！当前运行版本: \033[33m$SCRIPT_VERSION\033[0m"
    echo -e "绑定域名: https://${TUNNEL_DOMAIN}"
    echo -e "用户 UUID: ${UUID}"
    echo -e "====================================================\n"
fi

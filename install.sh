#!/bin/bash

# ==============================================================================
# InstaBox 终极版 (清爽主页 + 仅显订阅链接与版本号 + Xray多协议 + 内部保活)
# ==============================================================================

# 版本定义 (递增至 v1.0.4)
SCRIPT_VERSION="v1.0.4"

CF_TOKEN="$1"
TUNNEL_DOMAIN="$2"
UUID="$3"

if [ -z "$CF_TOKEN" ] || [ -z "$TUNNEL_DOMAIN" ]; then
    echo -e "\033[31m[错误] 缺少必要参数！\033[0m"
    echo -e "当前版本: \033[33m$SCRIPT_VERSION\033[0m"
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

# 1. 依赖环境检查
if [ "$(id -u)" -eq 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y nodejs curl unzip bc procps
    fi
fi

# 2. 下载官方 cloudflared
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

# 3. 下载 Xray-core
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

# 4. 生成 Xray 单端口 8001 复合入站
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
        "fallbacks": [
          {
            "path": "/xhttp",
            "dest": 8004,
            "xver": 0
          },
          {
            "alpn": "h2",
            "path": "/vless-grpc",
            "dest": 8003,
            "xver": 0
          },
          {
            "dest": 8080
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "port": 8003,
      "listen": "127.0.0.1",
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
    },
    {
      "port": 8004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "packet-up"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 5. 生成清爽 Web 控制中心 (仅保留版本号与订阅链接，移除所有直接节点)
cat << 'WEB_EOF' > web_server.js
const http = require('http');
const PORT = 8080;
const DOMAIN = process.env.DOMAIN || '';
const UUID = process.env.UUID || '';
const VERSION = process.env.VERSION || 'v1.0.4';

const server = http.createServer((req, res) => {
    const currentDomain = DOMAIN || req.headers.host || '127.0.0.1';
    
    // 构造节点数据用于生成订阅
    const linkWs = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=ws&host=${currentDomain}&path=%2Fvless#InstaBox-${VERSION}-WS`;
    const linkGrpc = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&mode=multi&sni=${currentDomain}#InstaBox-${VERSION}-gRPC`;
    const linkXhttp = `vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=xhttp&path=%2Fxhttp&mode=packet-up&sni=${currentDomain}&host=${currentDomain}#InstaBox-${VERSION}-XHTTP`;

    // 1. 通用 Base64 订阅接口 (/sub)
    if (req.url === '/sub') {
        const rawNodes = `${linkXhttp}\n${linkGrpc}\n${linkWs}`;
        const base64Data = Buffer.from(rawNodes, 'utf-8').toString('base64');
        res.writeHead(200, {
            'Content-Type': 'text/plain; charset=utf-8',
            'Subscription-Userinfo': 'upload=0; download=0; total=107374182400; expire=0',
            'Profile-Update-Interval': '24'
        });
        res.end(base64Data);
        return;
    }

    // 2. Clash / Mihomo 配置文件订阅接口 (/clash)
    if (req.url === '/clash') {
        const clashYaml = `port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "InstaBox-${VERSION}-XHTTP"
    type: vless
    server: ${currentDomain}
    port: 443
    uuid: ${UUID}
    network: xhttp
    tls: true
    servername: ${currentDomain}
    xhttp-opts:
      path: /xhttp
      mode: packet-up
  - name: "InstaBox-${VERSION}-gRPC"
    type: vless
    server: ${currentDomain}
    port: 443
    uuid: ${UUID}
    network: grpc
    tls: true
    servername: ${currentDomain}
    grpc-opts:
      grpc-service-name: vless-grpc
  - name: "InstaBox-${VERSION}-WS"
    type: vless
    server: ${currentDomain}
    port: 443
    uuid: ${UUID}
    network: ws
    tls: true
    servername: ${currentDomain}
    ws-opts:
      path: /vless
      headers:
        Host: ${currentDomain}
proxy-groups:
  - name: "自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - "InstaBox-${VERSION}-XHTTP"
      - "InstaBox-${VERSION}-gRPC"
      - "InstaBox-${VERSION}-WS"
rules:
  - MATCH,自动选择
`;
        res.writeHead(200, { 'Content-Type': 'text/yaml; charset=utf-8' });
        res.end(clashYaml);
        return;
    }

    // 3. Web 控制台主页 (清爽版，无节点字符串)
    const subUrl = `https://${currentDomain}/sub`;
    const clashUrl = `https://${currentDomain}/clash`;

    const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>InstaBox 控制中心 - ${VERSION}</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b1120; color: #f8fafc; padding: 32px 16px; }
        .container { max-width: 680px; margin: 0 auto; }
        .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #1e293b; padding-bottom: 16px; margin-bottom: 24px; }
        .header h1 { font-size: 20px; color: #38bdf8; display: flex; align-items: center; gap: 8px; }
        .ver-badge { background: #0284c7; color: white; padding: 2px 10px; border-radius: 6px; font-size: 13px; font-weight: 600; }
        .badge { background: #10b981; color: white; padding: 4px 12px; border-radius: 9999px; font-size: 13px; font-weight: bold; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 22px; margin-bottom: 20px; }
        .card h2 { font-size: 16px; color: #cbd5e1; margin-bottom: 14px; }
        .meta-line { color: #94a3b8; font-size: 14px; margin-bottom: 8px; }
        .meta-line strong { color: #f1f5f9; }
        .sub-group { margin-bottom: 18px; }
        .sub-group:last-child { margin-bottom: 0; }
        .sub-title { font-size: 13px; color: #94a3b8; margin-bottom: 6px; font-weight: 500; }
        .sub-box { background: #0f172a; border: 1px solid #334155; padding: 12px; border-radius: 8px; font-family: monospace; font-size: 13px; word-break: break-all; color: #38bdf8; margin-bottom: 8px; }
        button { background: #0284c7; color: white; border: none; padding: 9px 18px; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: 500; transition: background 0.2s; }
        button:hover { background: #0369a1; }
        button.btn-clash { background: #0d9488; }
        button.btn-clash:hover { background: #0f766e; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>InstaBox 控制中心 <span class="ver-badge">${VERSION}</span></h1>
            <span class="badge">运行正常 (Active)</span>
        </div>

        <div class="card" style="border-color: #0284c7;">
            <h2 style="color: #38bdf8;">服务订阅中心</h2>
            
            <div class="sub-group">
                <div class="sub-title">通用订阅 (支持 v2rayN / Sing-box / 蜜蜂版 / Shadowrocket，自动包含多协议节点):</div>
                <div class="sub-box" id="sub-url">${subUrl}</div>
                <button onclick="copyText('sub-url')">复制通用订阅地址</button>
            </div>

            <div class="sub-group" style="margin-top: 18px;">
                <div class="sub-title">Clash / Mihomo 专用订阅:</div>
                <div class="sub-box" id="clash-url">${clashUrl}</div>
                <button class="btn-clash" onclick="copyText('clash-url')">复制 Clash 订阅地址</button>
            </div>
        </div>

        <div class="card">
            <h2>运行环境</h2>
            <div class="meta-line">当前版本: <strong style="color: #38bdf8;">${VERSION}</strong></div>
            <div class="meta-line">绑定域名: <strong>${currentDomain}</strong></div>
            <div class="meta-line">核心驱动: <strong>Xray-core 原生极速分流 (XHTTP / gRPC / WS)</strong></div>
            <div class="meta-line">状态守护: <strong>内部防休眠活跃中</strong></div>
        </div>
    </div>

    <script>
        function copyText(id) {
            const text = document.getElementById(id).innerText;
            navigator.clipboard.writeText(text).then(function() {
                alert('订阅链接已复制到剪贴板！');
            });
        }
    </script>
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

# 8. 启动进程
echo -e "\033[32m[*] 正在后台启动 Web 控制中心与订阅服务 (版本: $SCRIPT_VERSION)...\033[0m"
UUID="$UUID" DOMAIN="$TUNNEL_DOMAIN" VERSION="$SCRIPT_VERSION" nohup node web_server.js > web.log 2>&1 &

echo -e "\033[32m[*] 正在启动 Xray 原生多协议分流引擎 (8001 主端口)...\033[0m"
nohup ./xray -config config.json > xray.log 2>&1 &

echo -e "\033[32m[*] 正在连接 Cloudflare 官方隧道...\033[0m"
nohup ./cloudflared tunnel run --token "$CF_TOKEN" > tunnel.log 2>&1 &

echo -e "\033[32m[*] 正在启动防休眠后台守护...\033[0m"
nohup ./keepalive.sh > /dev/null 2>&1 &

sleep 3

# 9. 构造订阅链接并输出
SUB_LINK="https://${TUNNEL_DOMAIN}/sub"
CLASH_LINK="https://${TUNNEL_DOMAIN}/clash"

if ! pgrep -f "cloudflared" > /dev/null; then
    echo -e "\033[31m[错误] cloudflared 启动失败，最后报错如下：\033[0m"
    tail -n 10 tunnel.log
else
    echo -e "\n\033[32m====================================================\033[0m"
    echo -e "\033[32m[OK] 部署成功！当前运行版本: \033[33m$SCRIPT_VERSION\033[0m"
    echo -e "管理控制台: https://${TUNNEL_DOMAIN}"
    echo -e "----------------------------------------------------"
    echo -e "\033[32m[通用订阅地址 (Base64)]:\033[0m"
    echo -e "$SUB_LINK"
    echo -e ""
    echo -e "\033[36m[Clash/Mihomo 配置文件订阅]:\033[0m"
    echo -e "$CLASH_LINK"
    echo -e "\033[32m====================================================\033[0m\n"
fi

#!/bin/bash

# ==============================================================================
# InstaBox 终极版 (v1.0.8: 精准PID强杀旧进程释放8001 + 修复WS握手 + 5组优选订阅)
# ==============================================================================

SCRIPT_VERSION="v1.0.8"

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

# 1. 强力清理所有历史残留进程（通过 ps + awk 精准提取 PID 强杀，兼容无 killall 环境）
echo -e "\033[33m[*] 正在强制清理旧进程并释放 8001 端口...\033[0m"
ps -ef | grep -E "xray|cloudflared|node|keepalive\.sh" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
sleep 2

# 2. 准备 cloudflared
if [ ! -f "cloudflared" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    esac
    curl -sL --output cloudflared "$CF_URL"
    chmod +x cloudflared
fi

# 3. 准备 Xray-core
if [ ! -f "xray" ]; then
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

# 4. 生成 Xray 配置 (8002: WS, 8003: gRPC, 8004: XHTTP，彻底让出 8001 给前置网关)
cat << EOF > config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 8002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "level": 0 }],
        "decryption": "none"
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

# 5. 生成前置 Web & 零损耗分流网关 (独占 8001 端口)
cat << 'WEB_EOF' > gateway.js
const http = require('http');
const net = require('net');

const PORT = 8001;
const DOMAIN = process.env.DOMAIN || '';
const UUID = process.env.UUID || '';
const VERSION = process.env.VERSION || 'v1.0.8';

const PREFERRED_DOMAINS = [
    { name: "IP.SB优选", host: "ip.sb" },
    { name: "万事达优选", host: "www.mastercard.com" },
    { name: "Shopify优选", host: "www.shopify.com" },
    { name: "VISA优选", host: "www.visa.com" },
    { name: "SaaS优选", host: "saas.sin.fan" }
];

const server = http.createServer((req, res) => {
    const currentDomain = DOMAIN || req.headers.host || '127.0.0.1';

    // 1. 通用 Base64 订阅 (/sub)
    if (req.url.startsWith('/sub')) {
        const nodeList = [];
        nodeList.push(`vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=xhttp&path=%2Fxhttp&mode=packet-up&sni=${currentDomain}&host=${currentDomain}#InstaBox-${VERSION}-默认直连-XHTTP`);
        nodeList.push(`vless://${UUID}@${currentDomain}:443?encryption=none&security=tls&type=ws&host=${currentDomain}&path=%2Fvless&sni=${currentDomain}#InstaBox-${VERSION}-默认直连-WS`);

        PREFERRED_DOMAINS.forEach(item => {
            nodeList.push(`vless://${UUID}@${item.host}:443?encryption=none&security=tls&type=xhttp&path=%2Fxhttp&mode=packet-up&sni=${currentDomain}&host=${currentDomain}#InstaBox-${item.name}-XHTTP`);
            nodeList.push(`vless://${UUID}@${item.host}:443?encryption=none&security=tls&type=ws&host=${currentDomain}&path=%2Fvless&sni=${currentDomain}#InstaBox-${item.name}-WS`);
        });

        const base64Data = Buffer.from(nodeList.join('\n'), 'utf-8').toString('base64');
        res.writeHead(200, {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            'Subscription-Userinfo': 'upload=0; download=0; total=107374182400; expire=0'
        });
        res.end(base64Data);
        return;
    }

    // 2. Clash 订阅 (/clash)
    if (req.url.startsWith('/clash')) {
        let clashYaml = `port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "InstaBox-默认-XHTTP"
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
  - name: "InstaBox-默认-WS"
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
`;

        PREFERRED_DOMAINS.forEach(item => {
            clashYaml += `  - name: "InstaBox-${item.name}-WS"
    type: vless
    server: ${item.host}
    port: 443
    uuid: ${UUID}
    network: ws
    tls: true
    servername: ${currentDomain}
    ws-opts:
      path: /vless
      headers:
        Host: ${currentDomain}
  - name: "InstaBox-${item.name}-XHTTP"
    type: vless
    server: ${item.host}
    port: 443
    uuid: ${UUID}
    network: xhttp
    tls: true
    servername: ${currentDomain}
    xhttp-opts:
      path: /xhttp
      mode: packet-up
`;
        });

        clashYaml += `proxy-groups:
  - name: "自动选择(最低延迟)"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - "InstaBox-默认-XHTTP"
      - "InstaBox-默认-WS"
`;
        PREFERRED_DOMAINS.forEach(item => {
            clashYaml += `      - "InstaBox-${item.name}-WS"\n`;
            clashYaml += `      - "InstaBox-${item.name}-XHTTP"\n`;
        });

        clashYaml += `rules:\n  - MATCH,自动选择(最低延迟)\n`;

        res.writeHead(200, {
            'Content-Type': 'text/yaml; charset=utf-8',
            'Cache-Control': 'no-store, no-cache, must-revalidate'
        });
        res.end(clashYaml);
        return;
    }

    // 3. XHTTP 代理请求转发给 Xray (8004)
    if (req.url.startsWith('/xhttp')) {
        const proxyReq = http.request({
            host: '127.0.0.1',
            port: 8004,
            path: req.url,
            method: req.method,
            headers: req.headers
        }, (proxyRes) => {
            res.writeHead(proxyRes.statusCode, proxyRes.headers);
            proxyRes.pipe(res);
        });
        proxyReq.on('error', () => res.end());
        req.pipe(proxyReq);
        return;
    }

    // 4. 其余所有路径均返回 Web 控制中心主页 (绝不返回 404)
    const subUrl = `https://${currentDomain}/sub`;
    const clashUrl = `https://${currentDomain}/clash`;

    const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>InstaBox 控制中心 - ${VERSION}</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b1120; color: #f8fafc; padding: 32px 16px; }
        .container { max-width: 680px; margin: 0 auto; }
        .header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #1e293b; padding-bottom: 16px; margin-bottom: 24px; }
        .header h1 { font-size: 20px; color: #38bdf8; display: flex; align-items: center; gap: 8px; }
        .ver-badge { background: #0284c7; color: white; padding: 3px 10px; border-radius: 6px; font-size: 13px; font-weight: bold; }
        .badge { background: #10b981; color: white; padding: 4px 12px; border-radius: 9999px; font-size: 13px; font-weight: bold; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 22px; margin-bottom: 20px; }
        .card h2 { font-size: 16px; color: #cbd5e1; margin-bottom: 14px; }
        .meta-line { color: #94a3b8; font-size: 14px; margin-bottom: 8px; }
        .meta-line strong { color: #f1f5f9; }
        .sub-group { margin-bottom: 18px; }
        .sub-group:last-child { margin-bottom: 0; }
        .sub-title { font-size: 13px; color: #94a3b8; margin-bottom: 6px; font-weight: 500; }
        .sub-box { background: #0f172a; border: 1px solid #334155; padding: 12px; border-radius: 8px; font-family: monospace; font-size: 13px; word-break: break-all; color: #38bdf8; margin-bottom: 8px; }
        button { background: #0284c7; color: white; border: none; padding: 9px 18px; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: 500; }
        button:hover { background: #0369a1; }
        button.btn-clash { background: #0d9488; }
        button.btn-clash:hover { background: #0f766e; }
        .tag-info { background: #059669; color: white; padding: 2px 6px; border-radius: 4px; font-size: 12px; margin-left: 6px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>InstaBox 控制中心 <span class="ver-badge">${VERSION}</span></h1>
            <span class="badge">运行正常 (Active)</span>
        </div>

        <div class="card" style="border-color: #0284c7;">
            <h2 style="color: #38bdf8;">服务订阅中心 <span class="tag-info">内置 5 组优选</span></h2>
            
            <div class="sub-group">
                <div class="sub-title">通用订阅 (支持 v2rayN / Sing-box / 蜜蜂版 / 自动聚合节点):</div>
                <div class="sub-box" id="sub-url">${subUrl}</div>
                <button onclick="copyText('sub-url')">复制通用订阅地址</button>
            </div>

            <div class="sub-group" style="margin-top: 18px;">
                <div class="sub-title">Clash / Mihomo 专用订阅 (自动测速选择最低延迟优选):</div>
                <div class="sub-box" id="clash-url">${clashUrl}</div>
                <button class="btn-clash" onclick="copyText('clash-url')">复制 Clash 订阅地址</button>
            </div>
        </div>

        <div class="card">
            <h2>运行环境</h2>
            <div class="meta-line">当前版本: <strong style="color: #38bdf8;">${VERSION}</strong></div>
            <div class="meta-line">绑定域名: <strong>${currentDomain}</strong></div>
            <div class="meta-line">核心驱动: <strong>Xray-core 原生极速分流 (XHTTP / WS)</strong></div>
            <div class="meta-line">加速配置: <strong>已注入 ip.sb / mastercard / shopify / visa / saas.sin.fan</strong></div>
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

    res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store, no-cache, must-revalidate'
    });
    res.end(html);
});

// 完整重构 WebSocket Upgrade 转发给 Xray (8002 端口)
server.on('upgrade', (req, socket, head) => {
    if (req.url.startsWith('/vless')) {
        const proxySocket = net.connect({ host: '127.0.0.1', port: 8002 }, () => {
            let reqHeaders = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
            for (let i = 0; i < req.rawHeaders.length; i += 2) {
                reqHeaders += `${req.rawHeaders[i]}: ${req.rawHeaders[i+1]}\r\n`;
            }
            reqHeaders += '\r\n';
            proxySocket.write(reqHeaders);
            if (head && head.length > 0) proxySocket.write(head);
            socket.pipe(proxySocket).pipe(socket);
        });
        proxySocket.on('error', () => socket.destroy());
        socket.on('error', () => proxySocket.destroy());
    } else {
        socket.destroy();
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Gateway listening on 0.0.0.0:${PORT}`);
});
WEB_EOF

# 6. 防休眠守护 (keepalive.sh)
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

# 7. 按顺序启动全部进程
echo -e "\033[32m[*] 正在启动 Xray 原生多核引擎 (后端端口 8002/8003/8004)...\033[0m"
nohup ./xray -config config.json > xray.log 2>&1 &

echo -e "\033[32m[*] 正在启动前置网关与 Web 控制中心 (监听 8001 主端口, 版本: $SCRIPT_VERSION)...\033[0m"
UUID="$UUID" DOMAIN="$TUNNEL_DOMAIN" VERSION="$SCRIPT_VERSION" nohup node gateway.js > gateway.log 2>&1 &

echo -e "\033[32m[*] 正在连接 Cloudflare 官方隧道...\033[0m"
nohup ./cloudflared tunnel run --token "$CF_TOKEN" > tunnel.log 2>&1 &

echo -e "\033[32m[*] 正在启动防休眠后台守护...\033[0m"
nohup ./keepalive.sh > /dev/null 2>&1 &

sleep 3

# 8. 严格检查进程是否存活
echo -e "\n\033[36m==================== 运行状态自检 ====================\033[0m"
ps -ef | grep -E "xray|cloudflared|gateway\.js" | grep -v grep

if ! ps -ef | grep "gateway.js" | grep -v grep > /dev/null; then
    echo -e "\033[31m[错误] gateway.js 未能成功启动！日志如下：\033[0m"
    cat gateway.log
else
    SUB_LINK="https://${TUNNEL_DOMAIN}/sub"
    CLASH_LINK="https://${TUNNEL_DOMAIN}/clash"
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

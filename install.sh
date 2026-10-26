cat << 'EOF' > run.sh
#!/bin/bash

# 检查是否传入了 Cloudflare Tunnel Token
CF_TOKEN="$1"
if [ -z "$CF_TOKEN" ]; then
    echo -e "\033[31m[错误] 请在运行脚本时携带 Cloudflare Tunnel Token！\033[0m"
    echo -e "使用方法: bash run.sh <你的Cloudflare_Token> [UUID]"
    exit 1
fi

# 检查或生成 UUID
UUID="$2"
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

# 1. 确保安装了 Node.js 与 curl
echo -e "\033[32m[*] 正在检查系统基础环境...\033[0m"
if ! command -v node >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y nodejs curl
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add nodejs curl
    fi
fi

# 2. 准备 cloudflared 二进制程序
if [ ! -f "cloudflared" ]; then
    echo -e "\033[32m[*] 正在下载 cloudflared 二进制...\033[0m"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
    esac
    curl -sL --output cloudflared "$URL"
    chmod +x cloudflared
fi

# 3. 生成 Node.js 代理与 Web 管理后台核心 (server.js)
echo -e "\033[32m[*] 正在生成核心服务代码...\033[0m"
cat << 'APP_EOF' > server.js
const http = require('http');
const net = require('net');
const crypto = require('crypto');
const os = require('os');

// 从环境变量读取配置
const PORT = process.env.PORT || 8001;
const UUID = process.env.UUID || 'a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d';
const WS_PATH = '/vless';

// 转换 UUID 为 16 字节 Buffer
function parseUuid(uuidStr) {
    return Buffer.from(uuidStr.replace(/-/g, ''), 'hex');
}
const uuidBuffer = parseUuid(UUID);

// 统计信息
let connectedClients = 0;
let totalBytesIn = 0;
let totalBytesOut = 0;
const logs = [];

function recordLog(msg) {
    const timestamp = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    const logLine = `[${timestamp}] ${msg}`;
    logs.push(logLine);
    if (logs.length > 50) {
        logs.shift();
    }
}

// 创建 HTTP 基础服务器
const server = http.createServer((req, res) => {
    // API: 获取运行状态与节点信息
    if (req.url === '/api/status') {
        const hostname = req.headers.host || 'eee.abcai.online';
        const vlessLink = `vless://${UUID}@${hostname}:443?encryption=none&security=tls&type=ws&host=${hostname}&path=${encodeURIComponent(WS_PATH)}#InstaBox-${hostname}`;
        
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({
            status: 'running',
            uptime: Math.floor(process.uptime()),
            connections: connectedClients,
            bytesIn: totalBytesIn,
            bytesOut: totalBytesOut,
            uuid: UUID,
            path: WS_PATH,
            domain: hostname,
            vlessNode: vlessLink,
            logs: logs
        }));
        return;
    }

    // 访问 Web 管理控制台主页
    if (req.url === '/' || req.url === '/index.html') {
        const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>InstaBox 管理控制台</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #0f172a; color: #f8fafc; padding: 20px; }
        .container { max-width: 860px; margin: 0 auto; }
        .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid #334155; }
        .header h1 { font-size: 20px; font-weight: 600; color: #38bdf8; }
        .badge { background: #10b981; color: white; padding: 4px 10px; border-radius: 9999px; font-size: 12px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 16px; }
        .card h3 { font-size: 13px; color: #94a3b8; margin-bottom: 8px; }
        .card p { font-size: 20px; font-weight: bold; color: #f1f5f9; }
        .section { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 20px; margin-bottom: 24px; }
        .section h2 { font-size: 16px; margin-bottom: 14px; color: #cbd5e1; }
        .node-box { background: #0f172a; border: 1px solid #475569; border-radius: 6px; padding: 12px; font-family: monospace; font-size: 12px; word-break: break-all; color: #38bdf8; margin-bottom: 12px; }
        button { background: #0284c7; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: 500; }
        button:hover { background: #0369a1; }
        .log-box { background: #0f172a; border-radius: 6px; padding: 12px; height: 180px; overflow-y: auto; font-family: monospace; font-size: 12px; color: #94a3b8; }
        .log-item { margin-bottom: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>InstaBox 服务管理控制台</h1>
            <span class="badge" id="status-badge">运行中 (Active)</span>
        </div>

        <div class="grid">
            <div class="card">
                <h3>已运行时间</h3>
                <p id="uptime">0 秒</p>
            </div>
            <div class="card">
                <h3>当前活跃连接</h3>
                <p id="conn-count">0</p>
            </div>
            <div class="card">
                <h3>入站流量</h3>
                <p id="bytes-in">0 KB</p>
            </div>
            <div class="card">
                <h3>出站流量</h3>
                <p id="bytes-out">0 KB</p>
            </div>
        </div>

        <div class="section">
            <h2>节点连接地址 (VLESS + WS + TLS)</h2>
            <div class="node-box" id="node-link">正在加载配置...</div>
            <button onclick="copyNodeLink()">复制节点链接</button>
        </div>

        <div class="section">
            <h2>运行日志</h2>
            <div class="log-box" id="log-list">
                <div class="log-item">初始化日志窗口...</div>
            </div>
        </div>
    </div>

    <script>
        function formatBytes(bytes) {
            if (bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return (bytes / Math.pow(k, i)).toFixed(2) + ' ' + sizes[i];
        }

        function formatUptime(seconds) {
            const h = Math.floor(seconds / 3600);
            const m = Math.floor((seconds % 3600) / 60);
            const s = seconds % 60;
            return h + '小时 ' + m + '分 ' + s + '秒';
        }

        async function updateStatus() {
            try {
                const res = await fetch('/api/status');
                const data = await res.json();
                document.getElementById('uptime').innerText = formatUptime(data.uptime);
                document.getElementById('conn-count').innerText = data.connections;
                document.getElementById('bytes-in').innerText = formatBytes(data.bytesIn);
                document.getElementById('bytes-out').innerText = formatBytes(data.bytesOut);
                document.getElementById('node-link').innerText = data.vlessNode;

                const logContainer = document.getElementById('log-list');
                logContainer.innerHTML = '';
                data.logs.forEach(function(l) {
                    const item = document.createElement('div');
                    item.className = 'log-item';
                    item.innerText = l;
                    logContainer.appendChild(item);
                });
            } catch (e) {
                console.error(e);
            }
        }

        function copyNodeLink() {
            const text = document.getElementById('node-link').innerText;
            navigator.clipboard.writeText(text).then(function() {
                alert('节点链接已复制到剪贴板！');
            });
        }

        updateStatus();
        setInterval(updateStatus, 3000);
    </script>
</body>
</html>`;
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
    }

    // 默认返回 404
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not Found');
});

// 处理 WebSocket Upgrade 握手 (VLESS 协议转发)
server.on('upgrade', (req, socket, head) => {
    // 仅匹配设定路径
    if (!req.url.startsWith(WS_PATH)) {
        socket.destroy();
        return;
    }

    const secWsKey = req.headers['sec-websocket-key'];
    if (!secWsKey) {
        socket.destroy();
        return;
    }

    // 完成 WebSocket 标准握手
    const hash = crypto.createHash('sha1');
    hash.update(secWsKey + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11');
    const secAccept = hash.digest('base64');

    const headers = [
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Accept: ${secAccept}`
    ];
    socket.write(headers.join('\r\n') + '\r\n\r\n');

    connectedClients++;
    recordLog(`新客户端接入: ${req.socket.remoteAddress || 'Cloudflare Edge'}`);

    let isHandshakeComplete = false;
    let targetSocket = null;
    let initialBuffer = head || Buffer.alloc(0);

    // 解析 WebSocket 数据帧
    function unmaskWsPayload(buffer) {
        if (buffer.length < 2) return null;
        let offset = 2;
        let payloadLen = buffer[1] & 0x7f;
        if (payloadLen === 126) {
            if (buffer.length < 4) return null;
            payloadLen = buffer.readUInt16BE(2);
            offset = 4;
        } else if (payloadLen === 127) {
            if (buffer.length < 10) return null;
            payloadLen = Number(buffer.readBigUInt64BE(2));
            offset = 10;
        }

        const isMasked = (buffer[1] & 0x80) !== 0;
        if (!isMasked) return null;

        if (buffer.length < offset + 4 + payloadLen) return null;
        const maskKey = buffer.slice(offset, offset + 4);
        offset += 4;

        const payload = buffer.slice(offset, offset + payloadLen);
        for (let i = 0; i < payload.length; i++) {
            payload[i] ^= maskKey[i % 4];
        }
        return { payload, totalLen: offset + payloadLen };
    }

    // 打包 WebSocket 二进制帧回传客户端
    function makeWsFrame(payload) {
        const len = payload.length;
        let header;
        if (len < 126) {
            header = Buffer.alloc(2);
            header[0] = 0x82; // 二进制帧, FIN
            header[1] = len;
        } else if (len <= 0xffff) {
            header = Buffer.alloc(4);
            header[0] = 0x82;
            header[1] = 126;
            header.writeUInt16BE(len, 2);
        } else {
            header = Buffer.alloc(10);
            header[0] = 0x82;
            header[1] = 127;
            header.writeBigUInt64BE(BigInt(len), 2);
        }
        return Buffer.concat([header, payload]);
    }

    // 数据流动监听
    socket.on('data', (chunk) => {
        totalBytesIn += chunk.length;
        initialBuffer = Buffer.concat([initialBuffer, chunk]);

        while (initialBuffer.length > 0) {
            const frame = unmaskWsPayload(initialBuffer);
            if (!frame) break;
            initialBuffer = initialBuffer.slice(frame.totalLen);
            const data = frame.payload;

            if (!isHandshakeComplete) {
                // VLESS 握手认证
                if (data.length < 17) continue;
                const clientUuid = data.slice(1, 17);
                if (Buffer.compare(clientUuid, uuidBuffer) !== 0) {
                    recordLog('UUID 校验失败，断开连接');
                    socket.destroy();
                    return;
                }

                let p = 17;
                const optLen = data[p];
                p += 1 + optLen;
                const cmd = data[p]; // 1: TCP, 2: UDP
                p += 1;
                const port = data.readUInt16BE(p);
                p += 2;
                const addrType = data[p];
                p += 1;

                let address = '';
                if (addrType === 1) { // IPv4
                    address = data.slice(p, p + 4).join('.');
                    p += 4;
                } else if (addrType === 2) { // Domain
                    const domainLen = data[p];
                    p += 1;
                    address = data.slice(p, p + domainLen).toString();
                    p += domainLen;
                } else if (addrType === 3) { // IPv6
                    address = data.slice(p, p + 16).toString('hex').match(/.{1,4}/g).join(':');
                    p += 16;
                }

                const remainPayload = data.slice(p);
                isHandshakeComplete = true;

                // 连接远端目标地址
                targetSocket = net.connect({ host: address, port: port }, () => {
                    recordLog(`成功转发流量到 -> ${address}:${port}`);
                    // 回复 VLESS 握手响应包 (版本0, 附加长度0)
                    const vlessRes = Buffer.from([0, 0]);
                    socket.write(makeWsFrame(vlessRes));

                    if (remainPayload.length > 0) {
                        targetSocket.write(remainPayload);
                    }
                });

                targetSocket.on('data', (targetChunk) => {
                    totalBytesOut += targetChunk.length;
                    socket.write(makeWsFrame(targetChunk));
                });

                targetSocket.on('error', (err) => {
                    recordLog(`目标服务器异常: ${err.message}`);
                    socket.destroy();
                });

                targetSocket.on('close', () => {
                    socket.destroy();
                });
            } else {
                if (targetSocket && !targetSocket.destroyed) {
                    targetSocket.write(data);
                }
            }
        }
    });

    socket.on('close', () => {
        connectedClients = Math.max(0, connectedClients - 1);
        if (targetSocket) targetSocket.destroy();
    });

    socket.on('error', () => {
        connectedClients = Math.max(0, connectedClients - 1);
        if (targetSocket) targetSocket.destroy();
    });
});

server.listen(PORT, '0.0.0.0', () => {
    recordLog(`本地服务已监听 0.0.0.0:${PORT}`);
    console.log(`[OK] 本地代理与管理面板已启动，端口: ${PORT}`);
});
APP_EOF

# 4. 清理旧进程并启动
pkill -f "node server.js" 2>/dev/null
pkill -f "cloudflared" 2>/dev/null

echo -e "\033[32m[*] 正在后台启动 Node.js 核心服务...\033[0m"
PORT=8001 UUID="$UUID" nohup node server.js > server.log 2>&1 &

echo -e "\033[32m[*] 正在建立 Cloudflare 隧道连接...\033[0m"
nohup ./cloudflared tunnel run --token "$CF_TOKEN" > tunnel.log 2>&1 &

sleep 3

echo -e "\n\033[32m====================================================\033[0m"
echo -e "\033[32m服务已成功部署并运行！\033[0m"
echo -e "监听端口: 8001"
echo -e "用户 UUID: $UUID"
echo -e "WS 路径:   /vless"
echo -e "管理面板: 打开你的隧道域名（例如: https://eee.abcai.online）"
echo -e "查看日志: tail -f $WORK_DIR/tunnel.log 或 tail -f $WORK_DIR/server.log"
echo -e "\033[32m====================================================\033[0m\n"
EOF

chmod +x run.sh

#!/bin/bash

# ==============================================================================
# InstaBox 终极硬核性能版 (Xray 原生单端口零拷贝 + XHTTP + gRPC + HTTP/2隧道)
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

# 1. 基础系统依赖与网络栈调优
echo -e "\033[32m[*] 正在配置系统基础运行环境与 TCP 调优...\033[0m"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl unzip bc procps
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add curl unzip bc procps
fi

# 调整内核缓冲区与拥塞算法
if [ -w /etc/sysctl.conf ]; then
    cat << 'SYS_EOF' >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
SYS_EOF
    sysctl -p >/dev/null 2>&1
fi

# 2. 下载官方 cloudflared
if [ ! -f "cloudflared" ]; then
    echo -e "\033[32m[*] 正在下载官方 cloudflared 核心...\033[0m"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    esac
    curl -sL --output cloudflared "$CF_URL"
    chmod +x cloudflared
fi

# 3. 下载最新稳定版 Xray-core
if [ ! -f "xray" ]; then
    echo -e "\033[32m[*] 正在拉取 Xray-core 原生高性能核心...\033[0m"
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

# 4. 生成原生多协议监听（8001 主端口直通 XHTTP，8003 直通 gRPC，8004 直通 WS）
# XHTTP 设为主入站（8001），由 Cloudflare Tunnel 默认打入，延迟与吞吐最强
echo -e "\033[32m[*] 正在生成原生零损耗 Xray 路由配置...\033[0m"
cat << EOF > config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "xhttp-in",
      "port": 8001,
      "listen": "0.0.0.0",
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
        },
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "grpc-in",
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
    },
    {
      "tag": "ws-in",
      "port": 8004,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    }
  ]
}
EOF

# 5. 内部轻量仿真保活守护程序 (keepalive.sh)
cat << 'KEEP_EOF' > keepalive.sh
#!/bin/bash
LOG_FILE="/tmp/tunnel_server/keepalive.log"

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] KeepAlive Heartbeat Active" >> "$LOG_FILE"
    curl -s -m 5 https://1.1.1.1 > /dev/null 2>&1
    if command -v bc >/dev/null 2>&1; then
        echo "scale=50; 4*a(1)" | bc -l > /dev/null 2>&1
    fi
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    sleep 180
done
KEEP_EOF
chmod +x keepalive.sh

# 6. 清理所有旧进程
pkill -f "xray" 2>/dev/null
pkill -f "cloudflared" 2>/dev/null
pkill -f "keepalive.sh" 2>/dev/null

# 7. 启动服务（启动 Xray + HTTP/2 多路复用隧道）
echo -e "\033[32m[*] 启动 Xray 原生引擎...\033[0m"
nohup ./xray -config config.json > xray.log 2>&1 &

echo -e "\033[32m[*] 启动 Cloudflare 极速 HTTP/2 隧道 (对齐 8001 端口)...\033[0m"
nohup ./cloudflared tunnel --protocol http2 --http2-max-streams 1000 run --token "$CF_TOKEN" > tunnel.log 2>&1 &

echo -e "\033[32m[*] 启动后台防休眠守护程序...\033[0m"
nohup ./keepalive.sh > /dev/null 2>&1 &

sleep 3

# 8. 输出终极配置链接
LINK_XHTTP="vless://${UUID}@${TUNNEL_DOMAIN}:443?encryption=none&security=tls&type=xhttp&path=%2Fxhttp&mode=packet-up&sni=${TUNNEL_DOMAIN}&host=${TUNNEL_DOMAIN}#InstaBox-XHTTP-PacketUp"

echo -e "\n\033[32m====================================================\033[0m"
echo -e "\033[32m[OK] 最强性能引擎已就绪！\033[0m"
echo -e "核心模式: 原生 Xray 直通 (零中间代理耗损)"
echo -e "传输协议: XHTTP (packet-up 极限吞吐模式)"
echo -e "隧道配置: HTTP/2 双向复用 (最大并发流: 1000)"
echo -e "绑定域名: $TUNNEL_DOMAIN"
echo -e "用户 UUID: $UUID"
echo -e "----------------------------------------------------"
echo -e "\033[33m最强性能节点链接 (直接导入客户端使用):\033[0m"
echo -e "$LINK_XHTTP"
echo -e "\033[32m====================================================\033[0m\n"

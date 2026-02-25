#!/bin/bash

echo "正在安装 Xray 和 Cloudflared..."

# 安装 Xray
echo "安装 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 安装 Cloudflared
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-arm64 -O cloudflared
else
    wget -q https://github.com/cloudflare/cloudflared/releases/download/2025.10.1/cloudflared-linux-amd64 -O cloudflared
fi
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/

# 停止可能存在的进程
sudo systemctl stop xray 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "生成的 UUID: $UUID"

# 创建 Xray 配置文件
echo "创建 Xray 配置..."
sudo tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
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
      "settings": {}
    }
  ]
}
EOF

# 启动 Xray
echo "启动 Xray..."
sudo systemctl start xray
sudo systemctl enable xray

# 等待启动
sleep 3

# 检查 Xray 是否运行
if sudo systemctl is-active --quiet xray; then
    echo "✓ Xray 启动成功"
else
    echo "✗ Xray 启动失败"
    sudo systemctl status xray
    exit 1
fi

# 检查端口
if netstat -tuln 2>/dev/null | grep -q ":8443" || ss -tuln 2>/dev/null | grep -q ":8443"; then
    echo "✓ Xray 正在监听端口 8443"
else
    echo "✗ Xray 未监听端口 8443"
    exit 1
fi

# 启动 Cloudflared 隧道
echo "启动 Cloudflared 隧道..."
nohup cloudflared tunnel --url http://localhost:8443 > cloudflared.log 2>&1 &
CLOUDFLARED_PID=$!

# 等待隧道建立
echo "等待隧道建立..."
sleep 10

# 获取公共 URL
PUBLIC_URL=""
for i in {1..10}; do
    if [ -f cloudflared.log ]; then
        PUBLIC_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" cloudflared.log | head -1)
        if [ -n "$PUBLIC_URL" ]; then
            break
        fi
    fi
    sleep 2
done

# 提取域名和端口
if [ -n "$PUBLIC_URL" ]; then
    DOMAIN=$(echo $PUBLIC_URL | sed 's|https://||' | sed 's|/.*||')
    PORT="443"
else
    DOMAIN="等待生成"
    PORT="443"
fi

# 显示访问信息
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=================================================="
echo "安装完成！VLESS 代理服务器已启动"
echo "=================================================="
echo ""
echo "【连接信息】"
echo "协议: VLESS"
echo "UUID: $UUID"
echo "端口: 8443 (本地) / 443 (外网)"
echo "传输协议: WebSocket"
echo "路径: /vless"
echo "TLS: 无 (本地) / 是 (Cloudflare)"
echo ""
echo "本地访问: $IP:8443"
if [ -n "$PUBLIC_URL" ]; then
    echo "外网访问: $DOMAIN:$PORT"
    echo "完整 URL: $PUBLIC_URL"
else
    echo "外网访问: 正在生成... (查看: cat cloudflared.log)"
fi
echo ""
echo "【客户端配置示例】"
echo "地址: $DOMAIN"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "传输: ws"
echo "路径: /vless"
echo "TLS: tls"
echo "SNI: $DOMAIN"
echo ""
echo "【VLESS 链接】(外网访问)"
if [ -n "$PUBLIC_URL" ]; then
    VLESS_LINK="vless://$UUID@$DOMAIN:$PORT?type=ws&path=/vless&security=tls&sni=$DOMAIN#CloudflareVLESS"
    echo "$VLESS_LINK"
fi
echo ""
echo "【管理命令】"
echo "查看状态: sudo systemctl status xray"
echo "查看日志: sudo journalctl -u xray -f"
echo "停止服务: sudo systemctl stop xray"
echo "重启服务: sudo systemctl restart xray"
echo "查看隧道: cat cloudflared.log"
echo ""
echo "=================================================="

# 保存配置信息
cat > vless_config.txt <<EOF
VLESS 代理服务器配置信息
========================
UUID: $UUID
本地地址: $IP:8443
外网地址: $DOMAIN:$PORT
WebSocket 路径: /vless
传输协议: WebSocket
TLS: 通过 Cloudflare

VLESS 链接:
$VLESS_LINK

Cloudflared PID: $CLOUDFLARED_PID
EOF

echo $CLOUDFLARED_PID > cloudflared.pid
echo "配置已保存到 vless_config.txt"

#!/bin/sh
# 安装 goproxy 到越狱设备（需 root 权限，通过 SSH 执行）
# 用法: 先将 goproxy-ios 传到设备，然后在本目录执行 ./install.sh
set -e
BIN=/usr/local/bin/goproxy
mkdir -p /usr/local/bin
cp ./goproxy-ios "$BIN"
chmod 755 "$BIN"
# 附带默认配置文件（http 智能分流模式用到）
touch /usr/local/bin/blocked /usr/local/bin/direct
echo "[OK] installed to $BIN"
echo "运行示例:"
echo "  $BIN http -p :33080                # HTTP 代理"
echo "  $BIN tcp -p :38080 -T tcp          # TCP 端口映射"
echo "  $BIN tserver -p :38080             # 内网穿透服务端"

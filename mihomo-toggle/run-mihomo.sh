#!/bin/sh
CONFIG_DIR=/var/mobile/.config/mihomo
CFG_FILE=$CONFIG_DIR/.config_path
if [ -f "$CFG_FILE" ]; then
  CONFIG=$(/bin/cat "$CFG_FILE")
fi
if [ -z "$CONFIG" ]; then
  CONFIG=$CONFIG_DIR/baidu.yaml
fi
exec /var/jb/usr/local/bin/mihomo -d "$CONFIG_DIR" -f "$CONFIG"

#!/usr/bin/env bash
# 给一台 Komari 节点装 TcpQuality 三网回程附件（一键安装）
#
# 用法（在节点上，root 身份）：
#   bash install-tcpquality.sh <节点UUID> [附件zip本地路径]
#   例：bash install-tcpquality.sh 84c29338-b012-457e-906b-1663711747f6
#
# 做的事：下附件包并验 SHA256 -> 解压 -> prepare（下 rootfs，约 100MB）
#   -> 从 systemd 启动参数取 Agent 身份（写 0600 配置，全程不打印 token）
#   -> enroll 登记 -> 跑一次 collector 验收（约 15-25 分钟）
#   -> 验收通过才开定时。只装附件，不改 Agent 本身、不改代理配置。
# 建议后台跑（SSH 断了也不怕）：
#   nohup bash install-tcpquality.sh <节点UUID> > /tmp/tcpquality-install.log 2>&1 &
#   tail -f /tmp/tcpquality-install.log
#
# 注意：附件包从本仓库下载（永久链接）。如果节点下不到 GitHub，把附件 zip
# 传到节点上，用第二个参数传路径，例如：
#   bash install-tcpquality.sh <节点UUID> /tmp/atlas-komari-tcpquality-0.4.0.zip

set -euo pipefail

UUID="${1:-}"
ZIP_ARG="${2:-}"
ATTACH_VERSION="0.4.0"
AGENT_DIR="/opt/komari"
ATTACH_DIR="$AGENT_DIR/attachments/tcpquality/$ATTACH_VERSION"
DATA_DIR="/var/lib/komari-agent/attachments/tcpquality"
CONFIG_FILE="/etc/komari-agent/attachments/tcpquality/config.json"
ZIP_URL="https://raw.githubusercontent.com/4258806/komari-tcpquality/main/atlas-komari-tcpquality-0.4.0.zip"
ZIP_SHA256="d8dc2957d8239dbd9774de2ce4a846cbf6874fed62310f02e0fcd680a797ede2"
ZIP_PATH="/tmp/atlas-komari-tcpquality-0.4.0.zip"

if [ -z "$UUID" ]; then
  echo "用法: bash $0 <节点UUID> [附件zip本地路径]"
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 2
fi

echo "== 1/6 检查环境 =="
python3 -c "import sys; assert sys.version_info >= (3, 12), 'Python 需要 3.12 以上'; print('Python', sys.version.split()[0], 'OK')"
for cmd in unshare chroot mount ip curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺命令: $cmd"; exit 1; }
done
FREE_KB=$(df --output=avail -k / | tail -1)
[ "$FREE_KB" -ge 614400 ] || { echo "磁盘剩余不足 600MB"; exit 1; }
echo "环境 OK，磁盘剩余 $((FREE_KB / 1024)) MB"

echo "== 2/6 取附件包 =="
if [ -n "$ZIP_ARG" ] && [ -f "$ZIP_ARG" ]; then
  cp "$ZIP_ARG" "$ZIP_PATH"
  echo "用本地包: $ZIP_ARG"
else
  echo "下载附件包（从本仓库）"
  curl -fSL -o "$ZIP_PATH" "$ZIP_URL"
fi
echo "$ZIP_SHA256  $ZIP_PATH" | sha256sum -c -
mkdir -p "$ATTACH_DIR"
cd "$ATTACH_DIR"
python3 -m zipfile -e "$ZIP_PATH" .
ls
echo "附件包就绪: $ATTACH_DIR"

echo "== 3/6 准备 rootfs（下载约 100MB，自动校验 SHA256）=="
python3 prepare.py --data "$DATA_DIR"

echo "== 4/6 准备 Agent 身份 =="
if [ -f /etc/komari-agent/config.json ]; then
  AGENT_CONFIG="/etc/komari-agent/config.json"
  echo "用现有 Agent 配置文件"
else
  AGENT_CONFIG="/etc/komari-agent/agent-config.json"
  python3 - <<'PYEOF'
import json, re, os
unit = open("/etc/systemd/system/komari-agent.service").read()
m = re.search(r"-e\s+(\S+)\s+-t\s+(\S+)", unit)
if not m:
    raise SystemExit("在 komari-agent.service 里没找到 -e 和 -t 参数")
endpoint, token = m.group(1), m.group(2)
os.makedirs("/etc/komari-agent", mode=0o700, exist_ok=True)
p = "/etc/komari-agent/agent-config.json"
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"endpoint": endpoint, "token": token}, f)
print("agent-config written; endpoint:", endpoint)
PYEOF
fi

echo "== 5/6 登记（enroll）=="
python3 enroll.py \
  --agent-config "$AGENT_CONFIG" \
  --uuid "$UUID" \
  --data "$DATA_DIR" \
  --config "$CONFIG_FILE"

echo "== 6/6 验收采集（约 15-25 分钟）=="
timeout 2400 python3 collector.py run --config "$CONFIG_FILE"
echo "验收通过，开定时..."
python3 enroll.py \
  --agent-config "$AGENT_CONFIG" \
  --uuid "$UUID" \
  --data "$DATA_DIR" \
  --config "$CONFIG_FILE" \
  --enable-schedule

echo "全部完成。"
echo "最后一步（网页上，1 分钟）：后台 -> 插件 -> Atlas Return Route Probe -> 配置，"
echo "在 nodes 原有大括号里面、已有节点后面加一个英文逗号，再粘下面这段："
echo "\"$UUID\": {\"enabled\": true, \"city\": \"beijing\", \"periodMinutes\": 720, \"collector\": \"tcpquality\"}"
echo "注意：不要把新节点连同大括号一起粘到原来后面——两个大括号并排是错的，插件会读不懂配置。"
echo "（插件固定时刻改造完成后再把 periodMinutes 换成 times）"

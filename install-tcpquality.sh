#!/usr/bin/env bash
# 给一台 Komari 节点装 TcpQuality 三网回程附件（一键安装）
#
# 用法（在节点上，root 身份；UUID 不用填，脚本按硬件指纹自动识别）：
#   bash install-tcpquality.sh [附件zip本地路径]
#   例：bash install-tcpquality.sh
# 只有指纹认不出时才需要手动传 UUID（目前 3 台同配置的 E2 会这样）：
#   bash install-tcpquality.sh 84c29338-b012-457e-906b-1663711747f6
#
# 做的事：下附件包并验 SHA256 -> 解压 -> prepare（下 rootfs，约 100MB）
#   -> 从 systemd 启动参数（没 systemd 时从正在跑的 Agent 进程）取 Agent 身份（写 0600 配置，全程不打印 token）
#   -> enroll 登记 -> 跑一次 collector 验收（约 15-25 分钟）
#   -> 验收通过才开定时。只装附件，不改 Agent 本身、不改代理配置。
# 建议后台跑（SSH 断了也不怕）：
#   nohup bash install-tcpquality.sh > /tmp/tcpquality-install.log 2>&1 &
#   tail -f /tmp/tcpquality-install.log
#
# 注意：附件包从本仓库下载（永久链接）。如果节点下不到 GitHub，把附件 zip
# 传到节点上，用参数传路径，例如：
#   bash install-tcpquality.sh /tmp/atlas-komari-tcpquality-0.4.0.zip

set -euo pipefail

UUID=""
ZIP_ARG=""
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [ -n "${1:-}" ]; then
  if [[ "$1" =~ $UUID_RE ]]; then UUID="$1"; shift
  elif [ -f "$1" ]; then ZIP_ARG="$1"; shift
  else echo "第一个参数既不是 UUID 也不是附件 zip 路径：$1"; echo "用法：bash $0 [节点UUID] [附件zip本地路径]（UUID 不填会自动识别）"; exit 2; fi
fi
if [ -n "${1:-}" ]; then ZIP_ARG="$1"; fi
ATTACH_VERSION="0.4.0"
AGENT_DIR="/opt/komari"
ATTACH_DIR="$AGENT_DIR/attachments/tcpquality/$ATTACH_VERSION"
DATA_DIR="/var/lib/komari-agent/attachments/tcpquality"
CONFIG_FILE="/etc/komari-agent/attachments/tcpquality/config.json"
ZIP_URL="https://raw.githubusercontent.com/4258806/komari-tcpquality/main/atlas-komari-tcpquality-0.4.0.zip"
ZIP_SHA256="d8dc2957d8239dbd9774de2ce4a846cbf6874fed62310f02e0fcd680a797ede2"
ZIP_PATH="/tmp/atlas-komari-tcpquality-0.4.0.zip"

# 用本机硬件指纹在探针上认出自己（UUID 参数没给时用）。
# 指纹：内核版本 + CPU 核数 + 内存 + 根盘大小，对照 {endpoint}/api/nodes；
# 恰好一台匹配才认。成功只打印 UUID，失败只把原因打印到 stderr。
detect_uuid() {
  local endpoint="$1"
  local kernel cores mem disk nodes_json
  kernel="$(uname -r)"
  cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
  mem="$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)"
  disk="$(df -P -k / | awk 'NR==2 {print $2 * 1024}')"
  nodes_json="$(curl -fsSL -m 20 "$endpoint/api/nodes")" || { echo "连不上 $endpoint/api/nodes，自动识别不了" >&2; return 1; }
  printf '%s' "$nodes_json" | python3 -c '
import json, sys
kernel, cores, mem, disk = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
nodes = json.load(sys.stdin)["data"]
hits = []
for n in nodes:
    if n.get("kernel_version") != kernel: continue
    if n.get("cpu_cores") != cores: continue
    if abs(n.get("mem_total", 0) - mem) > mem * 0.01: continue
    if abs(n.get("disk_total", 0) - disk) > disk * 0.01: continue
    hits.append(n)
if len(hits) == 1:
    print(hits[0]["uuid"])
    sys.exit(0)
if not hits:
    print("指纹没对上任何节点（内核/CPU/内存/磁盘都不匹配）", file=sys.stderr)
    sys.exit(2)
print("指纹对上了 %d 台节点：%s" % (len(hits), "、".join(h["name"] for h in hits)), file=sys.stderr)
sys.exit(3)
' "$kernel" "$cores" "$mem" "$disk"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行"
  exit 2
fi

echo "== 1/6 检查环境 =="
python3 -c "import sys; assert sys.version_info >= (3, 12), 'Python 需要 3.12 以上'; print('Python', sys.version.split()[0], 'OK')"
for cmd in unshare chroot mount ip curl sha256sum timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺命令: $cmd"; exit 1; }
done
FREE_KB=$(df -P -k / | awk 'NR==2 {print $4}')
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
if ! python3 prepare.py --data "$DATA_DIR" 2>/tmp/tcpquality-prepare.err; then
  if grep -q "refusing overwrite" /tmp/tcpquality-prepare.err && [ -f "$DATA_DIR/rootfs-prepared.json" ]; then
    echo "rootfs 已存在（之前那次已备好并验过），跳过准备"
  else
    cat /tmp/tcpquality-prepare.err >&2
    exit 1
  fi
fi
rm -f /tmp/tcpquality-prepare.err

echo "== 4/6 准备 Agent 身份 =="
if [ -f /etc/komari-agent/config.json ]; then
  AGENT_CONFIG="/etc/komari-agent/config.json"
  echo "用现有 Agent 配置文件"
else
  AGENT_CONFIG="/etc/komari-agent/agent-config.json"
  python3 - <<'PYEOF'
import json, re, os, subprocess
endpoint = token = None
unit_path = "/etc/systemd/system/komari-agent.service"
if os.path.exists(unit_path):
    m = re.search(r"-e\s+(\S+)\s+-t\s+(\S+)", open(unit_path).read())
    if m:
        endpoint, token = m.group(1), m.group(2)
if not endpoint:
    # 没 systemd 单元时，从正在跑的 Agent 进程命令行里取（Alpine 等不用 systemd 的系统）
    try:
        out = subprocess.check_output(["ps", "aux"], text=True)
    except Exception:
        out = ""
    for line in out.splitlines():
        # 只认 Agent 本体那行：二进制名以 agent 结尾，后面紧跟 -e 地址 -t token
        m = re.search(r"(\S*agent)\s+-e\s+(\S+)\s+-t\s+(\S+)", line)
        if m:
            endpoint, token = m.group(2), m.group(3).strip("\"'")
            break
if not endpoint:
    raise SystemExit("既没找到 komari-agent.service，也没在运行的进程里找到 Agent 的 -e 和 -t 参数")
os.makedirs("/etc/komari-agent", mode=0o700, exist_ok=True)
p = "/etc/komari-agent/agent-config.json"
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"endpoint": endpoint, "token": token}, f)
print("agent-config written; endpoint:", endpoint)
PYEOF
fi

ENDPOINT="$(python3 -c "import json; print(json.load(open('$AGENT_CONFIG'))['endpoint'])")"
if [ -z "$UUID" ]; then
  echo "没给 UUID，用硬件指纹在探针上识别本节点..."
  DETECT_ERR="/tmp/tcpquality-detect.err"
  if ! UUID="$(detect_uuid "$ENDPOINT" 2>"$DETECT_ERR")"; then
    cat "$DETECT_ERR" >&2
    echo "自动识别失败，请手动传 UUID，例如：bash $0 84c29338-b012-457e-906b-1663711747f6" >&2
    rm -f "$DETECT_ERR"
    exit 2
  fi
  rm -f "$DETECT_ERR"
  echo "识别出本节点 UUID: $UUID"
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

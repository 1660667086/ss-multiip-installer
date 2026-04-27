#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/shadowsocks}"
BASE_CONFIG="${BASE_CONFIG:-$CONFIG_DIR/config.json}"
PORT="${PORT:-80}"
PASSWORD="${PASSWORD:-1}"
METHOD="${METHOD:-aes-256-gcm}"
TIMEOUT="${TIMEOUT:-300}"
NAMESERVER="${NAMESERVER:-8.8.8.8}"
PLUGIN="${PLUGIN:-obfs-server}"
PLUGIN_OPTS="${PLUGIN_OPTS:-obfs=http}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/ss-multiip}"
UPSTREAM_INSTALL_URL="${UPSTREAM_INSTALL_URL:-https://raw.githubusercontent.com/1660667086/123/master/install-ss-plugins-fixed.sh}"
FORCE_UPSTREAM="${FORCE_UPSTREAM:-0}"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export NEEDRESTART_SUSPEND="${NEEDRESTART_SUSPEND:-1}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-900}"
SYSTEMCTL_TIMEOUT_SECONDS="${SYSTEMCTL_TIMEOUT_SECONDS:-10}"

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "请使用 root 运行."
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  if has_cmd apt-get; then
    apt-get update
    apt-get install -y "$@"
  elif has_cmd dnf; then
    dnf install -y "$@"
  elif has_cmd yum; then
    yum install -y "$@"
  else
    return 1
  fi
}

ensure_base_tools() {
  local cmd
  for cmd in curl ip python3; do
    if ! has_cmd "$cmd"; then
      echo "缺少基础命令: $cmd"
      echo "请先安装后重新运行。"
      exit 1
    fi
  done
}

prompt_value() {
  local var_name="$1" prompt="$2" default_value="$3" value
  read -r -p "${prompt} (默认: ${default_value}): " value
  printf -v "$var_name" '%s' "${value:-$default_value}"
}

fast_packages_available() {
  has_cmd apt-cache || return 1
  apt-cache policy shadowsocks-libev 2>/dev/null | awk '$1 == "Candidate:" { found=1; ok=($2 != "(none)") } END { exit !(found && ok) }' || return 1
  apt-cache policy simple-obfs 2>/dev/null | awk '$1 == "Candidate:" { found=1; ok=($2 != "(none)") } END { exit !(found && ok) }' || return 1
}

fast_install_shadowsocks() {
  local use_fast

  [[ "$FORCE_UPSTREAM" == "1" ]] && return 1
  fast_packages_available || return 1

  echo "检测到系统源可直接安装 shadowsocks-libev + simple-obfs。"
  read -r -p "使用快速安装，跳过源码编译吗？(默认: y) [y/n]: " use_fast
  [[ "${use_fast:-y}" =~ ^[Nn]$ ]] && return 1

  install_packages shadowsocks-libev simple-obfs

  prompt_value PORT "请输入最终监听端口" "$PORT"
  prompt_value PASSWORD "请输入密码" "$PASSWORD"
  prompt_value METHOD "请输入加密方式" "$METHOD"

  PLUGIN="$(command -v obfs-server || echo obfs-server)"
  prompt_value PLUGIN_OPTS "请输入服务端插件参数" "$PLUGIN_OPTS"
}

systemctl_best_effort() {
  has_cmd systemctl || return 0
  if has_cmd timeout; then
    timeout "${SYSTEMCTL_TIMEOUT_SECONDS}" systemctl "$@" 2>/dev/null || true
  else
    systemctl "$@" 2>/dev/null || true
  fi
}

prepare_noninteractive_apt() {
  if [[ -d /etc/apt/apt.conf.d ]]; then
    cat > /etc/apt/apt.conf.d/99ss-multiip-installer <<APTCONF
DPkg::Lock::Timeout "${APT_LOCK_WAIT_SECONDS}";
APT::Get::Assume-Yes "true";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
  "--no-triggers";
};
APTCONF
  fi

  systemctl_best_effort stop apt-daily.service apt-daily-upgrade.service
  systemctl_best_effort stop apt-daily.timer apt-daily-upgrade.timer

  wait_for_apt_locks

  if has_cmd debconf-set-selections; then
    printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | debconf-set-selections || true
    printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | debconf-set-selections || true
  fi

  if has_cmd dpkg && dpkg --audit 2>/dev/null | grep -q .; then
    echo "检测到 dpkg 上次未配置完成，正在修复..."
    dpkg --configure -a
  fi
}

wait_for_apt_locks() {
  local waited=0
  local holders

  while true; do
    holders="$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true)"
    if [[ -z "$holders" ]]; then
      return
    fi

    if (( waited == 0 )); then
      echo "检测到 apt/dpkg 正在被其他进程占用，等待释放锁..."
      ps -fp $holders 2>/dev/null || true
    fi

    if (( waited >= APT_LOCK_WAIT_SECONDS )); then
      echo "等待 apt/dpkg 锁超时。当前占用进程:"
      ps -fp $holders 2>/dev/null || true
      echo "请等系统自动更新结束后重新运行本脚本。不要手动删除 lock 文件。"
      exit 1
    fi

    sleep 5
    waited=$((waited + 5))
  done
}

ensure_shadowsocks_tools() {
  if has_cmd ss-server && has_cmd obfs-server; then
    return
  fi

  if fast_install_shadowsocks && has_cmd ss-server && has_cmd obfs-server; then
    return
  fi

  echo "未检测到 ss-server 或 obfs-server，开始调用原 ss-plugins-fixed 安装脚本..."
  cd /root
  rm -rf /root/ss-plugins-fixed
  rm -f install-ss-plugins-fixed.sh
  curl -fL -o install-ss-plugins-fixed.sh "$UPSTREAM_INSTALL_URL"
  chmod +x install-ss-plugins-fixed.sh

  ./install-ss-plugins-fixed.sh

  if ! has_cmd ss-server || ! has_cmd obfs-server; then
    cat >&2 <<'MSG'

原安装脚本已结束，但仍缺少 ss-server 或 obfs-server。
请确认安装菜单里已经选择 Shadowsocks-libev + simple-obfs，然后重新运行本脚本。
MSG
    exit 1
  fi
}

write_base_config() {
  mkdir -p "$CONFIG_DIR"

  if [[ -f "$BASE_CONFIG" ]]; then
    cp -a "$BASE_CONFIG" "${BASE_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "已存在基础配置，已备份并保留原密码/加密/插件参数: $BASE_CONFIG"
  fi

  python3 - "$BASE_CONFIG" "$PORT" "$PASSWORD" "$METHOD" "$TIMEOUT" "$NAMESERVER" "$PLUGIN" "$PLUGIN_OPTS" <<'PY'
import json
import sys

path, port, password, method, timeout, nameserver, plugin, plugin_opts = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}

data["server"] = "0.0.0.0"
data["server_port"] = int(port)
data.setdefault("password", password)
data.setdefault("timeout", int(timeout))
data.setdefault("method", method)
data.setdefault("ipv6_first", False)
data.setdefault("nameserver", nameserver)
data.setdefault("mode", "tcp_and_udp")
data.setdefault("plugin", plugin)
data.setdefault("plugin_opts", plugin_opts)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write("\n")
PY
  echo "已写入基础配置: $BASE_CONFIG"
}

write_multiip_command() {
  cat > "$BIN_PATH" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/shadowsocks}"
BASE_CONFIG="${BASE_CONFIG:-$CONFIG_DIR/config.json}"
SERVICE_PREFIX="${SERVICE_PREFIX:-ss-ip}"
PORT="${PORT:-}"
SS_SERVER="${SS_SERVER:-$(command -v ss-server || true)}"
PUBLIC_IP_CHECK_URLS=(
  "https://api.ipify.org"
  "https://ifconfig.me/ip"
  "https://icanhazip.com"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1" >&2; exit 1; }
}

json_get() {
  python3 - "$BASE_CONFIG" "$1" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get(key, "")
print(value if value is not None else "")
PY
}

json_make_config() {
  local src="$1" dst="$2" bind_ip="$3" port="$4"
  python3 - "$src" "$dst" "$bind_ip" "$port" <<'PY'
import json
import sys

src, dst, bind_ip, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
data["server"] = bind_ip
data["server_port"] = port
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write("\n")
PY
}

get_public_ip() {
  local bind_ip="$1" iface="$2" url ip
  for url in "${PUBLIC_IP_CHECK_URLS[@]}"; do
    ip="$(curl -4 -fsS --max-time 8 --interface "$bind_ip" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  for url in "${PUBLIC_IP_CHECK_URLS[@]}"; do
    ip="$(curl -4 -fsS --max-time 8 --interface "$iface" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  return 1
}

write_service() {
  local index="$1" bind_ip="$2" public_ip="$3" config_file="$4"
  local service_file="/etc/systemd/system/${SERVICE_PREFIX}${index}.service"

  cat > "$service_file" <<SERVICE
[Unit]
Description=Shadowsocks libev on ${public_ip}:${PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_SERVER} -c ${config_file} -b ${bind_ip}
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
SERVICE
}

systemctl_retry() {
  local attempt
  for attempt in 1 2 3; do
    if systemctl "$@"; then
      return 0
    fi

    echo "systemctl $* 失败，尝试恢复 systemd 后重试 ($attempt/3)..."
    systemctl daemon-reexec 2>/dev/null || true
    sleep 3
  done

  echo "systemctl $* 最终失败." >&2
  return 1
}

reload_systemd() {
  systemctl_retry daemon-reload
}

start_service() {
  local service="$1"
  systemctl_retry enable "$service"
  systemctl_retry restart "$service"
}

main() {
  [[ $EUID -eq 0 ]] || { echo "请使用 root 运行." >&2; exit 1; }
  need_cmd ip
  need_cmd curl
  need_cmd python3
  [[ -n "$SS_SERVER" && -x "$SS_SERVER" ]] || { echo "找不到 ss-server." >&2; exit 1; }
  [[ -f "$BASE_CONFIG" ]] || { echo "找不到基础配置: $BASE_CONFIG" >&2; exit 1; }

  mkdir -p "$CONFIG_DIR"

  if [[ -z "$PORT" ]]; then
    PORT="$(json_get server_port)"
  fi
  [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "端口无效: $PORT" >&2; exit 1; }

  cp -a "$BASE_CONFIG" "${BASE_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"

  echo "基础配置: $BASE_CONFIG"
  echo "ss-server: $SS_SERVER"
  echo "端口: $PORT"
  echo "开始检测本机 IPv4 地址和公网出口..."

  mapfile -t ADDRS < <(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print $2" "a[1]}' | sort -u)
  if [[ ${#ADDRS[@]} -eq 0 ]]; then
    echo "没有检测到全局 IPv4 地址." >&2
    exit 1
  fi

  systemctl stop "${SERVICE_PREFIX}"'*.service' 2>/dev/null || true
  systemctl disable "${SERVICE_PREFIX}"'*.service' 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE_PREFIX}[0-9]*.service

  systemctl stop shadowsocks-libev.service 2>/dev/null || true
  systemctl disable shadowsocks-libev.service 2>/dev/null || true

  local index=0 line iface bind_ip public_ip config_file seen_public=""
  for line in "${ADDRS[@]}"; do
    iface="${line%% *}"
    bind_ip="${line##* }"
    echo "检测: $iface / $bind_ip"
    public_ip="$(get_public_ip "$bind_ip" "$iface" || true)"

    if [[ -z "$public_ip" ]]; then
      echo "  跳过: 无法检测公网出口."
      continue
    fi

    if grep -qw "$public_ip" <<<"$seen_public"; then
      echo "  跳过: 公网 IP $public_ip 已添加过."
      continue
    fi

    seen_public+=" $public_ip"
    index=$((index + 1))
    config_file="$CONFIG_DIR/config-ip${index}.json"
    json_make_config "$BASE_CONFIG" "$config_file" "$bind_ip" "$PORT"
    write_service "$index" "$bind_ip" "$public_ip" "$config_file"
    echo "  添加: ${public_ip}:${PORT} -> 本地 ${bind_ip}，配置 ${config_file}"
  done

  if [[ $index -eq 0 ]]; then
    echo "没有可用公网出口." >&2
    exit 1
  fi

  reload_systemd
  for n in $(seq 1 "$index"); do
    start_service "${SERVICE_PREFIX}${n}.service"
  done

  echo
  echo "完成，共创建 $index 个节点:"
  for n in $(seq 1 "$index"); do
    systemctl --no-pager --full status "${SERVICE_PREFIX}${n}.service" | sed -n '1,8p'
  done

  echo
  echo "监听检查:"
  ss -lntup | grep ":${PORT}" || true
}

main "$@"
SCRIPT

  chmod +x "$BIN_PATH"
  ln -sf "$BIN_PATH" /usr/bin/ss-multiip 2>/dev/null || true
  echo "已安装命令: $BIN_PATH"
}

main() {
  need_root
  ensure_base_tools
  prepare_noninteractive_apt
  ensure_shadowsocks_tools
  write_base_config
  write_multiip_command
  "$BIN_PATH"

  echo
  echo "以后新增/删除 IP 后，直接运行:"
  echo "  ss-multiip"
}

main "$@"

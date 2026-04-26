#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/shadowsocks}"
BASE_CONFIG="${BASE_CONFIG:-$CONFIG_DIR/config.json}"
PORT="${PORT:-80}"
PASSWORD="${PASSWORD:-1}"
METHOD="${METHOD:-aes-128-gcm}"
TIMEOUT="${TIMEOUT:-300}"
NAMESERVER="${NAMESERVER:-8.8.8.8}"
PLUGIN="${PLUGIN:-obfs-server}"
PLUGIN_OPTS="${PLUGIN_OPTS:-obfs=http}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/ss-multiip}"
UPSTREAM_INSTALL_URL="${UPSTREAM_INSTALL_URL:-https://raw.githubusercontent.com/1660667086/123/master/install-ss-plugins-fixed.sh}"

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
  local packages=("$@")
  if has_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif has_cmd dnf; then
    dnf install -y "${packages[@]}"
  elif has_cmd yum; then
    yum install -y "${packages[@]}"
  else
    echo "未找到 apt/dnf/yum，无法自动安装依赖: ${packages[*]}"
    return 1
  fi
}

ensure_base_tools() {
  local missing=()
  has_cmd curl || missing+=(curl)
  has_cmd ip || missing+=(iproute2)
  has_cmd python3 || missing+=(python3)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "安装基础依赖: ${missing[*]}"
    install_packages "${missing[@]}"
  fi
}

ensure_shadowsocks_tools() {
  if has_cmd ss-server && has_cmd obfs-server; then
    return
  fi

  echo "未检测到 ss-server 或 obfs-server，开始调用原 ss-plugins-fixed 安装脚本..."
  cd /root
  rm -rf /root/ss-plugins-fixed
  rm -f install-ss-plugins-fixed.sh
  curl -fL -o install-ss-plugins-fixed.sh "$UPSTREAM_INSTALL_URL"
  chmod +x install-ss-plugins-fixed.sh

  # Feed the upstream menu non-interactively:
  # install, ss-libev, random temporary port, password, default aes-128-gcm,
  # install plugin, simple-obfs, default http, default obfs-host, start.
  printf '2\n1\n\n%s\n\ny\n3\n\n\n\n' "$PASSWORD" | ./install-ss-plugins-fixed.sh

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
    echo "已存在基础配置，已备份并覆盖为多 IP 默认配置: $BASE_CONFIG"
  fi

  python3 - "$BASE_CONFIG" "$PORT" "$PASSWORD" "$METHOD" "$TIMEOUT" "$NAMESERVER" "$PLUGIN" "$PLUGIN_OPTS" <<'PY'
import json
import sys

path, port, password, method, timeout, nameserver, plugin, plugin_opts = sys.argv[1:]
data = {
    "server": "0.0.0.0",
    "server_port": int(port),
    "password": password,
    "timeout": int(timeout),
    "method": method,
    "ipv6_first": False,
    "nameserver": nameserver,
    "mode": "tcp_and_udp",
    "plugin": plugin,
    "plugin_opts": plugin_opts,
}

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

  if systemctl list-unit-files | grep -q '^shadowsocks-libev.service'; then
    systemctl stop shadowsocks-libev.service 2>/dev/null || true
    systemctl disable shadowsocks-libev.service 2>/dev/null || true
  fi

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

  systemctl daemon-reload
  for n in $(seq 1 "$index"); do
    systemctl enable --now "${SERVICE_PREFIX}${n}.service"
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
  ensure_shadowsocks_tools
  write_base_config
  write_multiip_command
  "$BIN_PATH"

  echo
  echo "以后新增/删除 IP 后，直接运行:"
  echo "  ss-multiip"
}

main "$@"

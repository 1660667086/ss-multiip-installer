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
INSTALL_UPSTREAM="${INSTALL_UPSTREAM:-0}"
SKIP_FAST_INSTALL="${SKIP_FAST_INSTALL:-0}"
SS_IMPL="${SS_IMPL:-auto}"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export NEEDRESTART_SUSPEND="${NEEDRESTART_SUSPEND:-1}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-900}"
SYSTEMCTL_TIMEOUT_SECONDS="${SYSTEMCTL_TIMEOUT_SECONDS:-10}"
APT_UPDATE_TIMEOUT_SECONDS="${APT_UPDATE_TIMEOUT_SECONDS:-240}"
APT_REFRESHED=0

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
    if ! apt_candidates_available "$@"; then
      apt_update_safe
    fi
    apt-get -o Dpkg::Use-Pty=0 install -y "$@"
  elif has_cmd dnf; then
    dnf install -y "$@"
  elif has_cmd yum; then
    yum install -y "$@"
  else
    return 1
  fi
}

apt_update_safe() {
  wait_for_apt_locks
  if has_cmd timeout; then
    timeout "${APT_UPDATE_TIMEOUT_SECONDS}" apt-get \
      -o Dpkg::Use-Pty=0 \
      -o APT::Color=0 \
      -o APT::Update::Post-Invoke-Success::= \
      -o APT::Update::Post-Invoke::= \
      update || return 1
  else
    apt-get \
      -o Dpkg::Use-Pty=0 \
      -o APT::Color=0 \
      -o APT::Update::Post-Invoke-Success::= \
      -o APT::Update::Post-Invoke::= \
      update || return 1
  fi
  APT_REFRESHED=1
}

apt_package_has_candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '$1 == "Candidate:" { found=1; ok=($2 != "(none)") } END { exit !(found && ok) }'
}

apt_candidates_available() {
  local pkg
  has_cmd apt-cache || return 1
  for pkg in "$@"; do
    apt_package_has_candidate "$pkg" || return 1
  done
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
  read_prompt value "${prompt} (默认: ${default_value}): " "$default_value"
  printf -v "$var_name" '%s' "${value:-$default_value}"
}

read_prompt() {
  local __var_name="$1" prompt="$2" default_value="$3" value

  if [[ -r /dev/tty ]]; then
    if read -r -p "$prompt" value </dev/tty; then
      printf -v "$__var_name" '%s' "${value:-$default_value}"
      return
    fi
  elif read -r -p "$prompt" value; then
    printf -v "$__var_name" '%s' "${value:-$default_value}"
    return
  fi

  printf -v "$__var_name" '%s' "$default_value"
}

fast_packages_available() {
  if apt_candidates_available shadowsocks-libev simple-obfs; then
    return 0
  fi
  if has_cmd apt-get && [[ "$APT_REFRESHED" != "1" ]]; then
    echo "系统源暂未找到 shadowsocks-libev/simple-obfs，先刷新 apt 索引后重试..."
    apt_update_safe || return 1
    apt_candidates_available shadowsocks-libev simple-obfs || return 1
  fi
  return 1
}

fast_install_shadowsocks() {
  [[ "$FORCE_UPSTREAM" == "1" ]] && return 1
  [[ "$SKIP_FAST_INSTALL" == "1" ]] && return 1
  fast_packages_available || return 1

  echo "检测到系统源可直接安装 shadowsocks-libev + simple-obfs，自动补齐多 IP 必需组件。"

  install_packages shadowsocks-libev simple-obfs pwgen

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

has_supported_server() {
  has_cmd ss-server || has_cmd ssservice || has_cmd go-shadowsocks2
}

ensure_shadowsocks_tools() {
  local use_upstream

  if has_supported_server; then
    return
  fi

  if fast_install_shadowsocks && has_supported_server; then
    return
  fi

  if [[ "$FORCE_UPSTREAM" != "1" && "$INSTALL_UPSTREAM" != "1" ]]; then
    if [[ -r /dev/tty ]]; then
      echo
      echo "没有检测到已安装的 Shadowsocks 服务端，也无法从系统源快速补齐。"
      read_prompt use_upstream "是否进入原 ss-plugins 安装菜单？(默认: y) [y/n]: " "y"
      if [[ ! "${use_upstream:-y}" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        exit 1
      fi
    else
      cat >&2 <<'MSG'

没有检测到 ss-server、ssservice 或 go-shadowsocks2，且系统源里没有可直接安装的 shadowsocks-libev/simple-obfs。
多 IP 功能必须依赖其中一种 Shadowsocks 服务端。非交互运行时不会自动进入原安装脚本，避免进入大依赖/源码编译后卡住。

你可以先确认系统源是否正常，或显式运行:
  INSTALL_UPSTREAM=1 ./install-ss-multiip.sh
MSG
      exit 1
    fi
  fi

  echo "未检测到 Shadowsocks 服务端，开始调用原 ss-plugins-fixed 安装脚本..."
  cd /root
  rm -rf /root/ss-plugins-fixed
  rm -f install-ss-plugins-fixed.sh
  curl -fL -o install-ss-plugins-fixed.sh "$UPSTREAM_INSTALL_URL"
  chmod +x install-ss-plugins-fixed.sh

  ./install-ss-plugins-fixed.sh

  if ! has_supported_server; then
    cat >&2 <<'MSG'

原安装脚本已结束，但仍缺少 ss-server、ssservice 或 go-shadowsocks2。
请确认安装菜单里已经选择任意 Shadowsocks 版本，然后重新运行本脚本。
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
    loaded = True
except FileNotFoundError:
    data = {}
    loaded = False

data["server"] = "0.0.0.0"
data["server_port"] = int(port)
data.setdefault("password", password)
data.setdefault("timeout", int(timeout))
data.setdefault("method", method)
data.setdefault("ipv6_first", False)
data.setdefault("nameserver", nameserver)
data.setdefault("mode", "tcp_and_udp")
if "plugin" in data or not loaded:
    data.setdefault("plugin", plugin)
if "plugin_opts" in data or not loaded:
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
SS_IMPL="${SS_IMPL:-auto}"
SS_BIN="${SS_BIN:-}"
PUBLIC_IP_CHECK_URLS=(
  "https://api.ipify.org"
  "https://ifconfig.me/ip"
  "https://icanhazip.com"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1" >&2; exit 1; }
}

json_get() {
  local key="$1" path="${2:-$BASE_CONFIG}"
  python3 - "$path" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get(key, "")
print(value if value is not None else "")
PY
}

detect_impl() {
  if [[ "$SS_IMPL" != "auto" ]]; then
    echo "$SS_IMPL"
    return
  fi

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'ssservice( |$)' >/dev/null 2>&1 && { echo "ss-rust"; return; }
    pgrep -f 'go-shadowsocks2( |$)' >/dev/null 2>&1 && { echo "go-ss2"; return; }
    pgrep -f 'ss-server( |$)' >/dev/null 2>&1 && { echo "ss-libev"; return; }
  fi

  [[ -x /usr/local/bin/ssservice || -x /usr/bin/ssservice ]] && { echo "ss-rust"; return; }
  [[ -x /usr/local/bin/go-shadowsocks2 || -x /usr/bin/go-shadowsocks2 ]] && { echo "go-ss2"; return; }
  [[ -x /usr/local/bin/ss-server || -x /usr/bin/ss-server || -n "$(command -v ss-server || true)" ]] && { echo "ss-libev"; return; }
  return 1
}

detect_bin() {
  local impl="$1"
  case "$impl" in
    ss-libev) command -v ss-server || true ;;
    ss-rust) command -v ssservice || true ;;
    go-ss2) command -v go-shadowsocks2 || true ;;
  esac
}

go_ss2_method() {
  case "$1" in
    aes-128-gcm) echo "AEAD_AES_128_GCM" ;;
    aes-256-gcm) echo "AEAD_AES_256_GCM" ;;
    chacha20-ietf-poly1305) echo "AEAD_CHACHA20_POLY1305" ;;
    *) echo "$1" ;;
  esac
}

run_one() {
  local impl="$1" config_file="$2" bind_ip="$3" bin nameserver port password method mode plugin plugin_opts
  bin="${SS_BIN:-$(detect_bin "$impl")}"
  [[ -n "$bin" && -x "$bin" ]] || { echo "找不到 $impl 服务端程序." >&2; exit 1; }

  case "$impl" in
    ss-libev)
      exec "$bin" -c "$config_file" -b "$bind_ip"
      ;;
    ss-rust)
      nameserver="$(json_get nameserver "$config_file")"
      if [[ -n "$nameserver" ]]; then
        exec "$bin" server -c "$config_file" --dns "$nameserver" -vvv
      fi
      exec "$bin" server -c "$config_file" -vvv
      ;;
    go-ss2)
      port="$(json_get server_port "$config_file")"
      password="$(json_get password "$config_file")"
      method="$(go_ss2_method "$(json_get method "$config_file")")"
      mode="$(json_get mode "$config_file")"
      plugin="$(json_get plugin "$config_file")"
      plugin_opts="$(json_get plugin_opts "$config_file")"
      set -- -s "ss://${method}:${password}@${bind_ip}:${port}"
      case "$mode" in
        tcp_only) set -- "$@" -tcp ;;
        udp_only) set -- "$@" -udp ;;
        tcp_and_udp|"") set -- "$@" -tcp -udp ;;
      esac
      set -- "$@" -verbose
      if [[ -n "$plugin" ]]; then
        set -- "$@" -plugin "$plugin" -plugin-opts "$plugin_opts"
      fi
      exec "$bin" "$@"
      ;;
    *)
      echo "不支持的 Shadowsocks 实现: $impl" >&2
      exit 1
      ;;
  esac
}

json_make_config() {
  local src="$1" dst="$2" bind_ip="$3" port="$4" impl="$5"
  python3 - "$src" "$dst" "$bind_ip" "$port" "$impl" <<'PY'
import json
import sys

src, dst, bind_ip, port, impl = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
data["server"] = bind_ip
data["server_port"] = port
if impl == "ss-rust":
    data["outbound_bind_addr"] = bind_ip
else:
    data.pop("outbound_bind_addr", None)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write("\n")
PY
}

network_for_addr() {
  local iface="$1" bind_ip="$2"
  local cidr
  cidr="$(ip -o -4 addr show dev "$iface" scope global | awk -v ip="$bind_ip" '{split($4,a,"/"); if (a[1] == ip) print $4}' | head -n 1)"
  [[ -n "$cidr" ]] || return 1
  python3 - "$cidr" <<'PY'
import ipaddress
import sys

print(ipaddress.ip_interface(sys.argv[1]).network)
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

b64_text() {
  python3 - "$1" <<'PY'
import base64
import sys

print(base64.b64encode(sys.argv[1].encode()).decode())
PY
}

url_encode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

client_plugin_name() {
  local plugin_name
  plugin_name="$(basename "$1")"
  case "$plugin_name" in
    obfs-server) echo "obfs-local" ;;
    ck-server) echo "ck-client" ;;
    gq-server) echo "gq-client" ;;
    mtt-server) echo "mtt-client" ;;
    *) echo "$plugin_name" ;;
  esac
}

ss_link_for() {
  local public_ip="$1" config_file="$2"
  local method password port plugin plugin_opts userinfo link client_plugin plugin_query

  method="$(json_get method "$config_file")"
  password="$(json_get password "$config_file")"
  port="$(json_get server_port "$config_file")"
  plugin="$(json_get plugin "$config_file")"
  plugin_opts="$(json_get plugin_opts "$config_file")"
  userinfo="$(b64_text "${method}:${password}")"
  link="ss://${userinfo}@${public_ip}:${port}"

  if [[ -n "$plugin" ]]; then
    client_plugin="$(client_plugin_name "$plugin")"
    plugin_query="$client_plugin"
    if [[ -n "$plugin_opts" ]]; then
      plugin_query="${plugin_query};${plugin_opts}"
    fi
    link="${link}/?plugin=$(url_encode "$plugin_query")"
  fi

  echo "$link"
}

print_node_info() {
  local index="$1" public_ip="$2" config_file="$3"
  local method password port plugin plugin_opts

  method="$(json_get method "$config_file")"
  password="$(json_get password "$config_file")"
  port="$(json_get server_port "$config_file")"
  plugin="$(json_get plugin "$config_file")"
  plugin_opts="$(json_get plugin_opts "$config_file")"

  echo "节点 ${index}:"
  echo " 地址     : ${public_ip}"
  echo " 端口     : ${port}"
  echo " 密码     : ${password}"
  echo " 加密     : ${method}"
  if [[ -n "$plugin" ]]; then
    echo " 插件程序 : $(client_plugin_name "$plugin")"
    echo " 插件选项 : ${plugin_opts}"
  fi
  echo " SS 链接  : $(ss_link_for "$public_ip" "$config_file")"
  echo
}

service_user() {
  echo "ssip$1"
}

ensure_service_user() {
  local user="$1" shell_path
  if id -u "$user" >/dev/null 2>&1; then
    getent group "$user" >/dev/null 2>&1 || groupadd --system "$user"
    return
  fi
  shell_path="/usr/sbin/nologin"
  [[ -x "$shell_path" ]] || shell_path="/sbin/nologin"
  useradd --system --user-group --no-create-home --shell "$shell_path" "$user"
}

cleanup_iptables_rule() {
  local user="$1" mark="$2"
  while iptables -t mangle -D OUTPUT -m owner --uid-owner "$user" -j MARK --set-mark "$mark" 2>/dev/null; do
    :
  done
}

cleanup_policy_routes() {
  local n user mark table
  for n in $(seq 1 255); do
    user="$(service_user "$n")"
    mark=$((10000 + n))
    table="$mark"
    cleanup_iptables_rule "$user" "$mark"
    while ip rule del fwmark "$mark" table "$table" 2>/dev/null; do
      :
    done
    ip route flush table "$table" 2>/dev/null || true
  done
}

setup_policy_route() {
  local index="$1" iface="$2" bind_ip="$3" user="$4"
  local mark table priority gateway network

  mark=$((10000 + index))
  table="$mark"
  priority=$((20000 + index))
  gateway="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')"
  [[ -n "$gateway" ]] || gateway="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  network="$(network_for_addr "$iface" "$bind_ip" || true)"

  cleanup_iptables_rule "$user" "$mark"
  while ip rule del fwmark "$mark" table "$table" 2>/dev/null; do
    :
  done
  ip route flush table "$table" 2>/dev/null || true

  if [[ -n "$network" ]]; then
    ip route replace "$network" dev "$iface" src "$bind_ip" table "$table" 2>/dev/null || true
  fi
  if [[ -n "$gateway" ]]; then
    ip route replace default via "$gateway" dev "$iface" src "$bind_ip" onlink table "$table"
  else
    ip route replace default dev "$iface" src "$bind_ip" table "$table"
  fi
  ip rule add fwmark "$mark" table "$table" priority "$priority"
  iptables -t mangle -A OUTPUT -m owner --uid-owner "$user" -j MARK --set-mark "$mark"
  ip route flush cache 2>/dev/null || true
}

self_path() {
  case "$0" in
    /*) readlink -f "$0" 2>/dev/null || echo "$0" ;;
    */*) readlink -f "$0" 2>/dev/null || echo "$0" ;;
    *) command -v "$0" 2>/dev/null || echo "/usr/local/bin/ss-multiip" ;;
  esac
}

write_service() {
  local index="$1" iface="$2" bind_ip="$3" public_ip="$4" config_file="$5" impl="$6" user="$7"
  local service_file="/etc/systemd/system/${SERVICE_PREFIX}${index}.service" bin_path
  bin_path="$(self_path)"

  cat > "$service_file" <<SERVICE
[Unit]
Description=Shadowsocks ${impl} on ${public_ip}:${PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${user}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStartPre=+${bin_path} setup-route ${index} ${iface} ${bind_ip} ${user}
ExecStart=${bin_path} run-one ${impl} ${config_file} ${bind_ip}
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

wait_service_active() {
  local service="$1" waited=0 state
  while (( waited < 20 )); do
    if systemctl is-active --quiet "$service"; then
      return 0
    fi
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
    if [[ "$state" == "failed" ]]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

main() {
  if [[ "${1:-}" == "run-one" ]]; then
    shift
    run_one "$@"
  fi
  if [[ "${1:-}" == "setup-route" ]]; then
    shift
    setup_policy_route "$@"
    exit
  fi

  [[ $EUID -eq 0 ]] || { echo "请使用 root 运行." >&2; exit 1; }
  need_cmd ip
  need_cmd iptables
  need_cmd curl
  need_cmd python3
  [[ -f "$BASE_CONFIG" ]] || { echo "找不到基础配置: $BASE_CONFIG" >&2; exit 1; }

  SERVER_IMPL="$(detect_impl)" || { echo "找不到可用的 ss-server/ssservice/go-shadowsocks2." >&2; exit 1; }
  SERVER_BIN="${SS_BIN:-$(detect_bin "$SERVER_IMPL")}"
  [[ -n "$SERVER_BIN" && -x "$SERVER_BIN" ]] || { echo "找不到 $SERVER_IMPL 服务端程序." >&2; exit 1; }

  mkdir -p "$CONFIG_DIR"

  if [[ -z "$PORT" ]]; then
    PORT="$(json_get server_port)"
  fi
  [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "端口无效: $PORT" >&2; exit 1; }

  cp -a "$BASE_CONFIG" "${BASE_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"

  echo "基础配置: $BASE_CONFIG"
  echo "Shadowsocks 实现: $SERVER_IMPL"
  echo "服务端程序: $SERVER_BIN"
  echo "端口: $PORT"
  echo "开始检测本机 IPv4 地址和公网出口..."

  mapfile -t ADDRS < <(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print $2" "a[1]}' | sort -u)
  if [[ ${#ADDRS[@]} -eq 0 ]]; then
    echo "没有检测到全局 IPv4 地址." >&2
    exit 1
  fi

  systemctl stop "${SERVICE_PREFIX}"'*.service' 2>/dev/null || true
  systemctl disable "${SERVICE_PREFIX}"'*.service' 2>/dev/null || true
  cleanup_policy_routes
  rm -f /etc/systemd/system/${SERVICE_PREFIX}[0-9]*.service

  systemctl stop shadowsocks-libev.service 2>/dev/null || true
  systemctl disable shadowsocks-libev.service 2>/dev/null || true
  systemctl stop shadowsocks-rust.service go-shadowsocks2.service 2>/dev/null || true
  systemctl disable shadowsocks-rust.service go-shadowsocks2.service 2>/dev/null || true

  local index=0 line iface bind_ip public_ip config_file user seen_public=""
  local -a node_public_ips=() node_config_files=()
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
    user="$(service_user "$index")"
    ensure_service_user "$user"
    json_make_config "$BASE_CONFIG" "$config_file" "$bind_ip" "$PORT" "$SERVER_IMPL"
    write_service "$index" "$iface" "$bind_ip" "$public_ip" "$config_file" "$SERVER_IMPL" "$user"
    node_public_ips+=("$public_ip")
    node_config_files+=("$config_file")
    echo "  添加: ${public_ip}:${PORT} -> 本地 ${bind_ip}，出口绑定 ${bind_ip}，配置 ${config_file}"
  done

  if [[ $index -eq 0 ]]; then
    echo "没有可用公网出口." >&2
    exit 1
  fi

  reload_systemd
  for n in $(seq 1 "$index"); do
    start_service "${SERVICE_PREFIX}${n}.service"
    if ! wait_service_active "${SERVICE_PREFIX}${n}.service"; then
      echo "${SERVICE_PREFIX}${n}.service 未在等待时间内进入 active，继续打印诊断信息。"
    fi
  done

  echo
  echo "完成，共创建 $index 个节点:"
  for n in $(seq 1 "$index"); do
    (systemctl --no-pager --full status "${SERVICE_PREFIX}${n}.service" || true) | sed -n '1,10p'
  done

  echo
  echo "多 IP 配置信息:"
  for n in $(seq 1 "$index"); do
    print_node_info "$n" "${node_public_ips[$((n - 1))]}" "${node_config_files[$((n - 1))]}"
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

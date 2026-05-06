#!/bin/sh
# =====================================================
# НАЗВАНИЕ: F5GO OpenWrt Dumb AP Configurator
# ОПИСАНИЕ: Переводит OpenWrt в режим "глупой" точки доступа:
#           объединяет LAN/WAN порты в br-lan, удаляет WAN-интерфейсы,
#           задает статический LAN IP, gateway и DNS, отключает DHCP/RA на AP,
#           поднимает Wi-Fi (2.4/5 ГГц) в режиме AP на сети LAN.
# =====================================================

set -eu

GREEN="$(printf '\033[1;92m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[01;31m')"
BLUE="$(printf '\033[36m')"
NC="$(printf '\033[m')"

msg_info() { echo "${YELLOW}.. $1...${NC}"; }
msg_ok() { echo "${GREEN}OK: $1${NC}"; }
msg_warn() { echo "${BLUE}WARN: $1${NC}"; }
msg_error() { echo "${RED}ОШИБКА: $1${NC}" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg_error "Запустите скрипт от root (через sudo)."
    exit 1
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    msg_error "Не найдена команда: $1"
    exit 1
  fi
}

is_ipv4() {
  echo "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  '
}

ask_non_empty() {
  prompt="$1"
  default="$2"
  while :; do
    printf "%s (Enter = %s): " "$prompt" "$default" >&2
    read -r value
    [ -z "$value" ] && value="$default"
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
    msg_warn "Значение не может быть пустым."
  done
}

ask_wifi_key() {
  while :; do
    printf "Пароль Wi-Fi (WPA2-PSK, минимум 8 символов): " >&2
    read -r key
    if [ "${#key}" -lt 8 ]; then
      msg_warn "Пароль слишком короткий. Минимум 8 символов."
      continue
    fi
    echo "$key"
    return 0
  done
}

ask_wifi_mode() {
  while :; do
    echo "Режим Wi-Fi:" >&2
    echo "  1) Одна сеть (один SSID на 2.4 и 5 ГГц) [рекомендуется]" >&2
    echo "  2) Раздельные сети (отдельный SSID для 2.4 и 5 ГГц)" >&2
    printf "Выбор [1]: " >&2
    read -r mode
    [ -z "$mode" ] && mode="1"
    case "$mode" in
      1|2) echo "$mode"; return 0 ;;
      *) msg_warn "Введите 1 или 2." ;;
    esac
  done
}

get_radio_band() {
  radio="$1"
  band="$(uci -q get "wireless.${radio}.band" 2>/dev/null || true)"
  if [ -n "$band" ]; then
    echo "$band"
    return 0
  fi

  hwmode="$(uci -q get "wireless.${radio}.hwmode" 2>/dev/null || true)"
  case "$hwmode" in
    *11g*|*11n*) echo "2g" ;;
    *11a*|*11ac*|*11ax*) echo "5g" ;;
    *) echo "unknown" ;;
  esac
}

find_or_create_ap_iface() {
  radio="$1"
  found=""
  for sec in $(uci -q show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-iface$/\1/p"); do
    dev="$(uci -q get "wireless.${sec}.device" 2>/dev/null || true)"
    mode="$(uci -q get "wireless.${sec}.mode" 2>/dev/null || true)"
    net="$(uci -q get "wireless.${sec}.network" 2>/dev/null || true)"
    if [ "$dev" = "$radio" ] && [ "$mode" = "ap" ] && [ "$net" = "lan" ]; then
      found="$sec"
      break
    fi
  done
  if [ -z "$found" ]; then
    found="$(uci add wireless wifi-iface)"
  fi
  echo "$found"
}

ask_ip() {
  prompt="$1"
  default="$2"
  while :; do
    printf "%s (Enter = %s): " "$prompt" "$default" >&2
    read -r value
    [ -z "$value" ] && value="$default"
    if is_ipv4 "$value"; then
      echo "$value"
      return 0
    fi
    msg_warn "Некорректный IPv4 адрес: $value"
  done
}

suggest_lan_ip() {
  gw="$1"
  o1="$(echo "$gw" | cut -d. -f1)"
  o2="$(echo "$gw" | cut -d. -f2)"
  o3="$(echo "$gw" | cut -d. -f3)"
  o4="$(echo "$gw" | cut -d. -f4)"

  if [ "$o4" -ge 254 ]; then
    echo "${o1}.${o2}.${o3}.2"
    return 0
  fi

  next=$((o4 + 1))
  candidate="${o1}.${o2}.${o3}.${next}"
  if [ "$candidate" = "$gw" ]; then
    candidate="${o1}.${o2}.${o3}.2"
  fi
  echo "$candidate"
}

file_add_unique() {
  file="$1"
  item="$2"
  [ -z "$item" ] && return 0
  if ! grep -Fx "$item" "$file" >/dev/null 2>&1; then
    echo "$item" >> "$file"
  fi
}

collect_bridge_ports() {
  bridge_name="$1"
  out_file="$2"
  bridge_sections="$(uci -q show network | sed -n "s/^network\.\([^=]*\)\.name='${bridge_name}'$/\1/p")"
  for section in $bridge_sections; do
    ports="$(uci -q get "network.${section}.ports" 2>/dev/null || true)"
    [ -z "$ports" ] && ports="$(uci -q get "network.${section}.ifname" 2>/dev/null || true)"
    for p in $ports; do
      case "$p" in
        ""|lo|br-*|@*) continue ;;
      esac
      file_add_unique "$out_file" "$p"
    done
  done
}

collect_iface_device_ports() {
  iface="$1"
  out_file="$2"
  device="$(uci -q get "network.${iface}.device" 2>/dev/null || true)"
  [ -z "$device" ] && device="$(uci -q get "network.${iface}.ifname" 2>/dev/null || true)"
  for dev in $device; do
    case "$dev" in
      ""|lo|@*) continue ;;
      br-*) collect_bridge_ports "$dev" "$out_file" ;;
      *) file_add_unique "$out_file" "$dev" ;;
    esac
  done
}

print_file_as_csv() {
  file="$1"
  if [ ! -s "$file" ]; then
    echo "-"
    return 0
  fi
  tr '\n' ',' < "$file" | sed 's/,$//'
}

require_root
need_cmd uci
need_cmd ip
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd cut

TMP_DIR="$(mktemp -d)"
LAN_IFACES_FILE="${TMP_DIR}/lan_ifaces"
WAN_IFACES_FILE="${TMP_DIR}/wan_ifaces"
BR_PORTS_FILE="${TMP_DIR}/bridge_ports"
touch "$LAN_IFACES_FILE" "$WAN_IFACES_FILE" "$BR_PORTS_FILE"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

msg_info "Определение основного шлюза"
DETECTED_GW="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
[ -z "$DETECTED_GW" ] && DETECTED_GW="$(uci -q get network.lan.gateway 2>/dev/null || true)"
[ -z "$DETECTED_GW" ] && DETECTED_GW="192.168.1.1"

if ! is_ipv4 "$DETECTED_GW"; then
  DETECTED_GW="192.168.1.1"
fi

SUGGESTED_LAN_IP="$(suggest_lan_ip "$DETECTED_GW")"
CURRENT_NETMASK="$(uci -q get network.lan.netmask 2>/dev/null || true)"
[ -z "$CURRENT_NETMASK" ] && CURRENT_NETMASK="255.255.255.0"
is_ipv4 "$CURRENT_NETMASK" || CURRENT_NETMASK="255.255.255.0"

echo
msg_ok "Определен основной шлюз: $DETECTED_GW"
LAN_IP="$(ask_ip "IP этого OpenWrt" "$SUGGESTED_LAN_IP")"
GATEWAY_IP="$DETECTED_GW"
DNS_IP="$DETECTED_GW"
NETMASK_IP="$CURRENT_NETMASK"
msg_ok "Шлюз будет использован автоматически: $GATEWAY_IP"
msg_ok "DNS будет использован автоматически: $DNS_IP"
msg_ok "Маска будет использована автоматически: $NETMASK_IP"
echo
WIFI_MODE="$(ask_wifi_mode)"
if [ "$WIFI_MODE" = "1" ]; then
  WIFI_SSID="$(ask_non_empty "Имя Wi-Fi сети (SSID)" "F5GO.ONE")"
  WIFI_KEY="$(ask_wifi_key)"
else
  WIFI_SSID_24="$(ask_non_empty "SSID для 2.4 ГГц" "F5GO.ONE-2.4GHz")"
  WIFI_SSID_5="$(ask_non_empty "SSID для 5 ГГц" "F5GO.ONE-5GHz")"
  WIFI_KEY="$(ask_wifi_key)"
fi

msg_info "Определение LAN/WAN интерфейсов из network"
for iface in $(uci -q show network | sed -n "s/^network\.\([A-Za-z0-9_][A-Za-z0-9_]*\)=interface$/\1/p"); do
  case "$iface" in
    loopback) ;;
    lan|lan*) file_add_unique "$LAN_IFACES_FILE" "$iface" ;;
    wan|wan*|wwan|wwan*) file_add_unique "$WAN_IFACES_FILE" "$iface" ;;
  esac
done

msg_info "Уточнение LAN/WAN интерфейсов из firewall зон (если есть)"
for zone_sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^=]*\)=zone$/\1/p"); do
  zone_name="$(uci -q get "firewall.${zone_sec}.name" 2>/dev/null || true)"
  zone_nets="$(uci -q get "firewall.${zone_sec}.network" 2>/dev/null || true)"
  [ -z "$zone_nets" ] && continue
  for net_if in $zone_nets; do
    case "$zone_name" in
      lan) file_add_unique "$LAN_IFACES_FILE" "$net_if" ;;
      wan) file_add_unique "$WAN_IFACES_FILE" "$net_if" ;;
    esac
  done
done

file_add_unique "$LAN_IFACES_FILE" "lan"

msg_info "Сбор портов из LAN/WAN устройств и существующего br-lan"
collect_bridge_ports "br-lan" "$BR_PORTS_FILE"

for iface in $(cat "$LAN_IFACES_FILE"); do
  collect_iface_device_ports "$iface" "$BR_PORTS_FILE"
done
for iface in $(cat "$WAN_IFACES_FILE"); do
  collect_iface_device_ports "$iface" "$BR_PORTS_FILE"
done

# На некоторых платах порты прямо называются lan*/wan* и не всегда прописаны в UCI.
for netdev_path in /sys/class/net/*; do
  netdev="$(basename "$netdev_path")"
  case "$netdev" in
    lan*|wan*) file_add_unique "$BR_PORTS_FILE" "$netdev" ;;
  esac
done

if [ ! -s "$BR_PORTS_FILE" ]; then
  msg_error "Не удалось определить порты для br-lan. Прерывание."
  exit 1
fi

echo
msg_info "Найдены LAN интерфейсы: $(print_file_as_csv "$LAN_IFACES_FILE")"
msg_info "Найдены WAN интерфейсы: $(print_file_as_csv "$WAN_IFACES_FILE")"
msg_info "Найдены порты для br-lan: $(print_file_as_csv "$BR_PORTS_FILE")"
echo

msg_info "Удаление WAN интерфейсов из network"
for wan_if in $(cat "$WAN_IFACES_FILE"); do
  [ "$wan_if" = "lan" ] && continue
  [ "$wan_if" = "loopback" ] && continue
  uci -q delete "network.${wan_if}" || true
done
uci -q delete network.wan || true
uci -q delete network.wan6 || true

msg_info "Поиск/создание секции br-lan"
BRLAN_SECTION="$(uci -q show network | sed -n "s/^network\.\([^=]*\)\.name='br-lan'$/\1/p" | head -n1)"
if [ -z "$BRLAN_SECTION" ]; then
  BRLAN_SECTION="f5go_brlan"
  uci -q set "network.${BRLAN_SECTION}=device"
fi

msg_info "Настройка bridge br-lan"
uci -q set "network.${BRLAN_SECTION}.name=br-lan"
uci -q set "network.${BRLAN_SECTION}.type=bridge"
uci -q delete "network.${BRLAN_SECTION}.ports" || true
uci -q delete "network.${BRLAN_SECTION}.ifname" || true
for p in $(cat "$BR_PORTS_FILE"); do
  uci -q add_list "network.${BRLAN_SECTION}.ports=${p}"
done

msg_info "Настройка интерфейса LAN (static + gateway + dns)"
uci -q set network.lan=interface
uci -q set network.lan.device=br-lan
uci -q set network.lan.proto=static
uci -q set network.lan.ipaddr="$LAN_IP"
uci -q set network.lan.netmask="$NETMASK_IP"
uci -q set network.lan.gateway="$GATEWAY_IP"
uci -q delete network.lan.dns || true
uci -q add_list "network.lan.dns=${DNS_IP}"

msg_info "Отключение DHCP IPv4 и DHCPv6/RA на этой точке доступа"
uci -q set dhcp.lan=dhcp
uci -q set dhcp.lan.ignore=1
uci -q set dhcp.lan.ra=disabled
uci -q set dhcp.lan.dhcpv6=disabled
uci -q set dhcp.lan.ndp=disabled

msg_info "Настройка Wi-Fi точек доступа"
RADIOS="$(uci -q show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p")"
if [ -n "$RADIOS" ]; then
  for radio in $RADIOS; do
    band="$(get_radio_band "$radio")"
    if [ "$WIFI_MODE" = "1" ]; then
      ssid="$WIFI_SSID"
    else
      case "$band" in
        2g) ssid="$WIFI_SSID_24" ;;
        5g) ssid="$WIFI_SSID_5" ;;
        *) ssid="$WIFI_SSID_5" ;;
      esac
    fi

    iface_sec="$(find_or_create_ap_iface "$radio")"
    uci -q set "wireless.${radio}.disabled=0"
    uci -q set "wireless.${iface_sec}=wifi-iface"
    uci -q set "wireless.${iface_sec}.device=${radio}"
    uci -q set "wireless.${iface_sec}.mode=ap"
    uci -q set "wireless.${iface_sec}.network=lan"
    uci -q set "wireless.${iface_sec}.ssid=${ssid}"
    uci -q set "wireless.${iface_sec}.encryption=psk2"
    uci -q set "wireless.${iface_sec}.key=${WIFI_KEY}"
    uci -q set "wireless.${iface_sec}.disabled=0"
    msg_ok "Wi-Fi настроен: радио=${radio}, band=${band}, ssid=${ssid}"
  done
else
  msg_warn "wifi-device секции не найдены. Пропускаю настройку Wi-Fi."
fi

msg_info "Сохранение настроек"
uci commit network
uci commit dhcp
uci commit wireless

echo
msg_warn "После нажатия Enter сеть перезагрузится, текущее подключение может пропасть."
msg_warn "Для повторного подключения используй новый IP точки доступа: $LAN_IP"
printf "Нажмите Enter для продолжения... "
read -r _

msg_info "Перезапуск сервисов сети"
/etc/init.d/network restart
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
/etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/wireless restart >/dev/null 2>&1 || wifi reload >/dev/null 2>&1 || true

echo
msg_ok "Готово. OpenWrt переведен в режим 'глупой' точки доступа."
echo "Итоговые ключевые настройки:"
uci -q show network.lan
uci -q show "network.${BRLAN_SECTION}" | sed -n "/name='br-lan'/p;/type='bridge'/p;/ports='/p"
echo "dhcp.lan.ignore=$(uci -q get dhcp.lan.ignore 2>/dev/null || echo 1)"
echo "dhcp.lan.ra=$(uci -q get dhcp.lan.ra 2>/dev/null || echo disabled)"
echo "dhcp.lan.dhcpv6=$(uci -q get dhcp.lan.dhcpv6 2>/dev/null || echo disabled)"
echo "dhcp.lan.ndp=$(uci -q get dhcp.lan.ndp 2>/dev/null || echo disabled)"

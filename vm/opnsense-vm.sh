#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: michelroegl-brunner | MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# Fork Elenedeath: upstream structure (community-scripts/core vm-core.func) with
# the official OPNsense DVD ISO + automated installer instead of the FreeBSD
# image bootstrap. Fork additions: installer keymap (default / French accent
# keys), UFS/ZFS choice, LAN DHCP/static with optional LAN DHCP server, local
# ISO cache reuse.

COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/Elenedeath/ProxmoxVE/main}"
# Telemetrie comme a l'origine du fork : runs attribues a "ProxmoxVE"
export REPO_SOURCE="${REPO_SOURCE:-ProxmoxVE}"
source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/pve/vm-core.func")
load_functions

#API VARIABLES
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
APP="OPNsense"
APP_TYPE="vm"
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="26.7"
#
ISO_TYPE="dvd"
ISO_ARCH="amd64"
ISO_FILENAME="OPNsense-${var_version}-${ISO_TYPE}-${ISO_ARCH}.iso.bz2"
ISO_RAW_FILENAME="OPNsense-${var_version}-${ISO_TYPE}-${ISO_ARCH}.iso"
INSTALL_ROOT_PASSWORD="opnsense"
FORCE_ISO_DOWNLOAD="no"
KEYMAP_MODE="default"
FILESYSTEM_MODE="ufs"
LAN_IP_MODE="dhcp"
LAN_STATIC_IP_DEFAULT="192.168.1.2"
LAN_STATIC_MASK_DEFAULT="24"
LAN_STATIC_GW_DEFAULT="192.168.1.1"
ENABLE_LAN_DHCP_SERVER="n"
LAN_DHCP_RANGE_START=""
LAN_DHCP_RANGE_END=""
# OVMF without pre-enrolled Secure Boot keys, the OPNsense ISO is not signed
EFI_OPTS=",efitype=4m,pre-enrolled-keys=0"

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

HA=$(echo "\033[1;34m")
THIN="discard=on,ssd=1,"

header_info
echo -e "Loading..."
set -Eeo pipefail
shopt -s inherit_errexit
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

vm_require_arch amd64

function check_disk_space() {
  local path="$1"
  local required_gb="$2"
  local available_kb
  available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  [ "$available_gb" -ge "$required_gb" ]
}

# The compressed ISO and the decompressed one live here at the same time (~4 GB)
TEMP_DIR=$(mktemp -d)
if ! check_disk_space "$TEMP_DIR" 4 && [ -d "/var/tmp" ] && check_disk_space "/var/tmp" 4; then
  rm -rf "$TEMP_DIR"
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
fi
pushd "$TEMP_DIR" >/dev/null

vm_preflight
vm_require_tools bzip2

# qm sendkey sends US key names. With the installer keymap set to French
# (accent keys) the guest reads them as AZERTY, so digits need shift, "." is
# shift-comma and ":" is the US "." key. Only what the script types (digits,
# dots, lowercase words) is remapped.
function send_line_to_vm() {
  echo -e "${DGN}Sending line: ${YW}$1${CL}"
  for ((i = 0; i < ${#1}; i++)); do
    character=${1:i:1}
    case $character in
    " ") character="spc" ;;
    "-") character="minus" ;;
    "=") character="equal" ;;
    ",") character="comma" ;;
    ".")
      if [ "$KEYMAP_MODE" = "french-accent" ]; then
        character="shift-comma"
      else
        character="dot"
      fi
      ;;
    "/") character="slash" ;;
    "'") character="apostrophe" ;;
    ";") character="semicolon" ;;
    '\') character="backslash" ;;
    '`') character="grave_accent" ;;
    "[") character="bracket_left" ;;
    "]") character="bracket_right" ;;
    "_") character="shift-minus" ;;
    "+") character="shift-equal" ;;
    "?") character="shift-slash" ;;
    "<") character="shift-comma" ;;
    ">") character="shift-dot" ;;
    '"') character="shift-apostrophe" ;;
    ":")
      if [ "$KEYMAP_MODE" = "french-accent" ]; then
        character="dot"
      else
        character="shift-semicolon"
      fi
      ;;
    "|") character="shift-backslash" ;;
    "~") character="shift-grave_accent" ;;
    "{") character="shift-bracket_left" ;;
    "}") character="shift-bracket_right" ;;
    "A") character="shift-a" ;;
    "B") character="shift-b" ;;
    "C") character="shift-c" ;;
    "D") character="shift-d" ;;
    "E") character="shift-e" ;;
    "F") character="shift-f" ;;
    "G") character="shift-g" ;;
    "H") character="shift-h" ;;
    "I") character="shift-i" ;;
    "J") character="shift-j" ;;
    "K") character="shift-k" ;;
    "L") character="shift-l" ;;
    "M") character="shift-m" ;;
    "N") character="shift-n" ;;
    "O") character="shift-o" ;;
    "P") character="shift-p" ;;
    "Q") character="shift-q" ;;
    "R") character="shift-r" ;;
    "S") character="shift-s" ;;
    "T") character="shift-t" ;;
    "U") character="shift-u" ;;
    "V") character="shift-v" ;;
    "W") character="shift-w" ;;
    "X") character="shift-x" ;;
    "Y") character="shift-y" ;;
    "Z") character="shift-z" ;;
    "!") character="shift-1" ;;
    "@") character="shift-2" ;;
    "#") character="shift-3" ;;
    '$') character="shift-4" ;;
    "%") character="shift-5" ;;
    "^") character="shift-6" ;;
    "&") character="shift-7" ;;
    "*") character="shift-8" ;;
    "(") character="shift-9" ;;
    ")") character="shift-0" ;;
    [0-9])
      if [ "$KEYMAP_MODE" = "french-accent" ]; then
        character="shift-$character"
      fi
      ;;
    esac
    qm sendkey $VMID "$character" >/dev/null
    sleep 0.03
  done
  qm sendkey $VMID ret >/dev/null
  sleep 0.3
}

function send_key_to_vm() {
  qm sendkey $VMID "$1" >/dev/null
  sleep 0.4
}

function wait_for_boot() {
  local seconds="$1"
  echo -e "${DGN}Waiting ${seconds}s for guest state changes${CL}"
  sleep "$seconds"
}

function get_available_bridges() {
  ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort
}

function validate_ip_octets() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  [[ "$1" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

function prompt_router_input() {
  local var_name="$1" title="$2" prompt="$3" default_value="$4" value
  if vm_dialog inputbox "$title" "$prompt" 8 58 "$default_value" --cancel-button Exit-Script; then
    value="$VM_DIALOG_RESULT"
    printf -v "$var_name" '%s' "$value"
  else
    exit_script
  fi
}

function prompt_optional_static_ip() {
  local ip_var="$1" gw_var="$2" mask_var="$3" prefix="$4" ip_value gw_value mask_value
  prompt_router_input "$ip_var" "${prefix} IP ADDRESS" "Set a ${prefix} IP (empty = DHCP)" "${!ip_var:-}"
  ip_value="${!ip_var}"
  if [ -z "$ip_value" ]; then
    echo -e "${DGN}Using DHCP AS ${prefix} IP ADDRESS${CL}"
    return 0
  fi
  if ! validate_ip_octets "$ip_value"; then
    msg_error "Invalid IP Address format for ${prefix} IP. Needs to be 0.0.0.0, was $ip_value"
    exit 1
  fi
  echo -e "${DGN}Using ${prefix} IP ADDRESS: ${BGN}$ip_value${CL}"

  prompt_router_input "$gw_var" "${prefix} GATEWAY IP ADDRESS" "Set a ${prefix} GATEWAY IP" "${!gw_var:-}"
  gw_value="${!gw_var}"
  if [ -z "$gw_value" ]; then
    msg_error "${prefix} gateway is required for a static IP."
    exit 1
  fi
  if ! validate_ip_octets "$gw_value"; then
    msg_error "Invalid IP Address format for ${prefix} Gateway. Needs to be 0.0.0.0, was $gw_value"
    exit 1
  fi
  echo -e "${DGN}Using ${prefix} GATEWAY ADDRESS: ${BGN}$gw_value${CL}"

  prompt_router_input "$mask_var" "${prefix} NETMASK" "Set a ${prefix} netmask (24 for example)" "${!mask_var:-}"
  mask_value="${!mask_var}"
  if [ -z "$mask_value" ]; then
    msg_error "${prefix} netmask is required for a static IP."
    exit 1
  fi
  if [[ ! "$mask_value" =~ ^[0-9]+$ || "$mask_value" -lt 1 || "$mask_value" -gt 32 ]]; then
    msg_error "Invalid ${prefix} NETMASK format. Needs to be 1-32, was $mask_value"
    exit 1
  fi
  echo -e "${DGN}Using ${prefix} NETMASK: ${BGN}$mask_value${CL}"
}

function prompt_router_mac() {
  local var_name="$1" title="$2" prompt="$3" default_value="$4" label="$5" value
  prompt_router_input "$var_name" "$title" "$prompt" "$default_value"
  value="${!var_name}"
  [[ -n "$value" ]] || value="$default_value"
  printf -v "$var_name" '%s' "$value"
  if ! validate_mac_address "$value"; then
    msg_error "Invalid ${label}: $value"
    exit 1
  fi
  echo -e "${DGN}Using ${label}: ${BGN}$value${CL}"
}

function select_network_mode() {
  local available_bridges bridge_count default_wan_brg
  available_bridges=$(get_available_bridges)
  bridge_count=$(echo "$available_bridges" | wc -l)
  default_wan_brg=$(echo "$available_bridges" | grep -v "^${BRG}$" | head -n1 || true)

  if [[ "${VM_UNATTENDED:-0}" == "1" ]]; then
    WAN_BRG="${VM_WAN_BRIDGE:-}"
  elif [ "$bridge_count" -ge 2 ]; then
    if vm_dialog radiolist "NETWORK CONFIGURATION" --cancel-button Exit-Script \
      "Choose network setup mode for OPNsense:\n" 14 70 2 \
      "dual" "Dual Interface (Firewall/Router) - uses ${default_wan_brg}" ON \
      "single" "Single Interface (Proxy/VPN/IDS Server)" OFF; then
      if [ "$VM_DIALOG_RESULT" = "dual" ]; then
        WAN_BRG="$default_wan_brg"
        echo -e "${DGN}Network Mode: ${BGN}Dual Interface (Firewall)${CL}"
        echo -e "${DGN}Using WAN Bridge: ${BGN}${WAN_BRG}${CL}"
        echo -e "${DGN}Using WAN MAC Address: ${BGN}${WAN_MAC}${CL}"
      else
        echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
        WAN_BRG=""
      fi
    else
      exit_script
    fi
  else
    echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
    echo -e "${YW}  (Only one bridge detected, dual interface requires a second bridge)${CL}"
    WAN_BRG=""
  fi
}

function prompt_wan_bridge() {
  local wan_bridges wan_menu=() first=true brg
  wan_bridges=$(get_available_bridges | grep -v "^${BRG}$" || true)
  if [ -z "$wan_bridges" ]; then
    WAN_BRG=""
    msg_warn "Only one bridge is available; using single-interface mode."
    return 0
  fi
  while IFS= read -r brg; do
    if $first; then
      wan_menu+=("$brg" "" "ON")
      first=false
    else
      wan_menu+=("$brg" "" "OFF")
    fi
  done <<<"$wan_bridges"

  if vm_dialog radiolist "WAN BRIDGE" "Select WAN Bridge" 14 58 6 "${wan_menu[@]}"; then
    WAN_BRG="$VM_DIALOG_RESULT"
    [[ -n "$WAN_BRG" ]] || WAN_BRG=$(echo "$wan_bridges" | head -n1)
    echo -e "${DGN}Using WAN Bridge: ${BGN}$WAN_BRG${CL}"
  else
    exit_script
  fi
}

# --- Fork additions: installer options -----------------------------------------

function prompt_installer_keymap() {
  local fr_default="OFF" def_default="ON"
  # Preselect French when the Proxmox/VM keyboard is French
  if [[ "${VM_KEYBOARD:-$(vm_keyboard_default)}" == fr* ]]; then
    fr_default="ON"
    def_default="OFF"
  fi
  if vm_dialog radiolist "INSTALLER KEYMAP" --cancel-button Exit-Script \
    "Keymap selected in the OPNsense installer:\n" 12 66 2 \
    "default" "Default keymap (US)" "$def_default" \
    "french-accent" "French (accent keys)" "$fr_default"; then
    KEYMAP_MODE="${VM_DIALOG_RESULT:-default}"
  else
    exit_script
  fi
  echo -e "${DGN}Installer Keymap: ${BGN}${KEYMAP_MODE}${CL}"
}

function prompt_filesystem() {
  if vm_dialog radiolist "FILESYSTEM" --cancel-button Exit-Script \
    "Filesystem for the OPNsense installation:\n" 12 58 2 \
    "ufs" "UFS" ON \
    "zfs" "ZFS" OFF; then
    FILESYSTEM_MODE="${VM_DIALOG_RESULT:-ufs}"
  else
    exit_script
  fi
  echo -e "${DGN}Filesystem: ${BGN}${FILESYSTEM_MODE^^}${CL}"
}

# Static LAN asks whether OPNsense should serve DHCP on it
function prompt_lan_dhcp_server() {
  ENABLE_LAN_DHCP_SERVER="n"
  LAN_DHCP_RANGE_START=""
  LAN_DHCP_RANGE_END=""
  [ "$LAN_IP_MODE" = "static" ] || return 0
  if vm_dialog yesno "LAN DHCP SERVER" "Enable DHCP server on LAN?" 10 60; then
    ENABLE_LAN_DHCP_SERVER="y"
    local net="${IP_ADDR%.*}"
    prompt_router_input "LAN_DHCP_RANGE_START" "DHCP RANGE START" "Enter DHCP range start address:" "${net}.100"
    prompt_router_input "LAN_DHCP_RANGE_END" "DHCP RANGE END" "Enter DHCP range end address:" "${net}.200"
    if ! validate_ip_octets "$LAN_DHCP_RANGE_START" || ! validate_ip_octets "$LAN_DHCP_RANGE_END"; then
      msg_error "Invalid DHCP range: ${LAN_DHCP_RANGE_START} - ${LAN_DHCP_RANGE_END}"
      exit 1
    fi
    echo -e "${DGN}LAN DHCP Server: ${BGN}${LAN_DHCP_RANGE_START} - ${LAN_DHCP_RANGE_END}${CL}"
  else
    echo -e "${DGN}LAN DHCP Server: ${BGN}disabled${CL}"
  fi
}

# Default mode: DHCP or static LAN prefilled with 192.168.1.2/24 via 192.168.1.1
function configure_lan_mode() {
  if vm_dialog radiolist "LAN CONFIGURATION" --cancel-button Exit-Script \
    "Choose LAN IP mode for OPNsense:\n" 12 72 2 \
    "dhcp" "DHCP on LAN interface" ON \
    "static" "Static IP on LAN interface" OFF; then
    LAN_IP_MODE="${VM_DIALOG_RESULT:-dhcp}"
  else
    exit_script
  fi
  if [ "$LAN_IP_MODE" = "static" ]; then
    IP_ADDR="$LAN_STATIC_IP_DEFAULT"
    NETMASK="$LAN_STATIC_MASK_DEFAULT"
    LAN_GW="$LAN_STATIC_GW_DEFAULT"
    prompt_optional_static_ip "IP_ADDR" "LAN_GW" "NETMASK" "LAN"
    [ -n "$IP_ADDR" ] || LAN_IP_MODE="dhcp"
  else
    IP_ADDR=""
    echo -e "${DGN}Using DHCP AS LAN IP ADDRESS${CL}"
  fi
  prompt_lan_dhcp_server
}

function prompt_iso_cache() {
  if vm_dialog yesno "ISO CACHE" "Reuse local OPNsense ISO if already present?" 10 62; then
    FORCE_ISO_DOWNLOAD="no"
  else
    FORCE_ISO_DOWNLOAD="yes"
  fi
}

function prompt_installer_options() {
  if [[ "${VM_UNATTENDED:-0}" == "1" ]]; then
    KEYMAP_MODE="${OPNSENSE_KEYMAP:-$KEYMAP_MODE}"
    FILESYSTEM_MODE="${OPNSENSE_FILESYSTEM:-$FILESYSTEM_MODE}"
    return 0
  fi
  prompt_installer_keymap
  prompt_filesystem
  prompt_iso_cache
}

# -------------------------------------------------------------------------------

function default_settings() {
  vm_apply_machine_type "i440fx"
  VMID=$(get_valid_nextid)
  DISK_SIZE="20G"
  MACHINE=""
  DISK_CACHE=""
  HN="opnsense"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  IP_ADDR=""
  WAN_IP_ADDR=""
  LAN_GW=""
  WAN_GW=""
  NETMASK=""
  WAN_NETMASK=""
  VLAN=""
  MAC=$GEN_MAC
  WAN_MAC=$GEN_MAC_LAN
  WAN_BRG=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}Allocated RAM: ${BGN}${RAM_SIZE}${CL}"
  if ! ip link show "${BRG}" &>/dev/null; then
    msg_error "Bridge '${BRG}' does not exist"
    exit
  else
    echo -e "${DGN}Using LAN Bridge: ${BGN}${BRG}${CL}"
  fi
  echo -e "${DGN}Using LAN VLAN: ${BGN}Default${CL}"
  echo -e "${DGN}Using LAN MAC Address: ${BGN}${MAC}${CL}"
  select_network_mode
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  prompt_installer_options
  if [[ "${VM_UNATTENDED:-0}" != "1" ]]; then
    configure_lan_mode
  fi
  echo -e "${BL}Creating a OPNsense VM using the above default settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  IP_ADDR=""
  WAN_IP_ADDR=""
  LAN_GW=""
  WAN_GW=""
  NETMASK=""
  WAN_NETMASK=""
  VLAN=""
  MTU=""
  vm_prompt_disk_size "20G"
  vm_prompt_keyboard
  vm_prompt_verbose "no"
  vm_prompt_start_vm "yes"
  vm_prompt_vmid "${VMID:-$(get_valid_nextid)}"
  vm_prompt_machine_type "i440fx"
  vm_prompt_cpu_model "kvm64"
  vm_prompt_disk_cache "none"
  vm_prompt_hostname "opnsense"
  vm_prompt_cpu_cores "4"
  vm_prompt_ram "8192"

  prompt_router_input "BRG" "LAN BRIDGE" "Set a LAN Bridge" "vmbr0"
  [[ -n "$BRG" ]] || BRG="vmbr0"
  if ! ip link show "${BRG}" &>/dev/null; then
    msg_error "Bridge '${BRG}' does not exist"
    exit 1
  fi
  echo -e "${DGN}Using LAN Bridge: ${BGN}$BRG${CL}"

  prompt_optional_static_ip "IP_ADDR" "LAN_GW" "NETMASK" "LAN"
  if [ -n "$IP_ADDR" ]; then
    LAN_IP_MODE="static"
  else
    LAN_IP_MODE="dhcp"
  fi
  prompt_lan_dhcp_server
  prompt_wan_bridge
  if [[ -n "$WAN_BRG" ]]; then
    prompt_optional_static_ip "WAN_IP_ADDR" "WAN_GW" "WAN_NETMASK" "WAN"
  fi
  prompt_router_mac "MAC" "LAN MAC ADDRESS" "Set a LAN MAC Address" "$GEN_MAC" "LAN MAC address"
  if [[ -n "$WAN_BRG" ]]; then
    prompt_router_mac "WAN_MAC" "WAN MAC ADDRESS" "Set a WAN MAC Address" "$GEN_MAC_LAN" "WAN MAC address"
  else
    WAN_MAC="$GEN_MAC_LAN"
  fi
  prompt_installer_options

  if vm_confirm_advanced_settings "Ready to create OPNsense VM?"; then
    echo -e "${RD}Creating a OPNsense VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function find_opnsense_iso_url() {
  local base url
  for base in \
    "https://pkg.opnsense.org/releases/mirror/" \
    "https://mirrors.dotsrc.org/opnsense/releases/mirror/" \
    "https://mirror.ntct.edu.tw/opnsense/releases/mirror/"; do
    url="${base}${ISO_FILENAME}"
    if curl -fsI "$url" >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
  done
  return 1
}

function ensure_opnsense_iso() {
  if [ "$FORCE_ISO_DOWNLOAD" != "yes" ] && [ -f "$ISO_PATH" ]; then
    msg_ok "Reusing existing ISO ${CL}${BL}${ISO_PATH}${CL}"
    return 0
  fi

  msg_info "Locating official OPNsense ISO"
  ISO_URL=$(find_opnsense_iso_url) || {
    msg_error "Unable to locate ${ISO_FILENAME} on known OPNsense mirrors."
    exit 117
  }
  msg_ok "Download URL: ${CL}${BL}${ISO_URL}${CL}"

  if ! check_disk_space "$TEMP_DIR" 4; then
    AVAILABLE_GB=$(df -h "$TEMP_DIR" | awk 'NR==2 {print $4}')
    msg_error "Insufficient disk space in temporary directory ($TEMP_DIR)."
    msg_error "Available: ${AVAILABLE_GB}, Required: ~4GB for the OPNsense ISO."
    exit 214
  fi

  msg_info "Downloading official OPNsense ISO archive"
  curl -f#SL -o "${ISO_FILENAME}" "$ISO_URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${CL}${BL}${ISO_FILENAME}${CL}"

  msg_info "Decompressing ISO archive"
  bzip2 -df "${ISO_FILENAME}"
  msg_ok "Decompressed ${CL}${BL}${ISO_RAW_FILENAME}${CL}"

  msg_info "Copying ISO into Proxmox ISO storage"
  mkdir -p "$(dirname "$ISO_PATH")"
  mv -f "${ISO_RAW_FILENAME}" "$ISO_PATH"
  msg_ok "ISO copied to ${CL}${BL}${ISO_PATH}${CL}"
}

# The answers below are matched to OPNsense's console dialog (setaddr.php).
function configure_lan_ip_after_login() {
  msg_info "Logging into installed system"
  send_line_to_vm "root"
  wait_for_boot 2
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  wait_for_boot 4

  msg_info "Opening console menu option 2 for IP configuration"
  send_line_to_vm "2"
  wait_for_boot 2

  if [ "$LAN_IP_MODE" = "dhcp" ]; then
    msg_info "Configuring LAN for DHCP"
    send_line_to_vm "1"
    send_line_to_vm "y"
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
  else
    msg_info "Configuring static LAN address"
    send_line_to_vm "1"
    send_line_to_vm "n"
    send_line_to_vm "${IP_ADDR}"
    send_line_to_vm "${NETMASK}"
    send_line_to_vm "${LAN_GW}"
    send_line_to_vm "n"
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm "${ENABLE_LAN_DHCP_SERVER}"
    if [ "$ENABLE_LAN_DHCP_SERVER" = "y" ]; then
      send_line_to_vm "${LAN_DHCP_RANGE_START}"
      send_line_to_vm "${LAN_DHCP_RANGE_END}"
    fi
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
  fi
  wait_for_boot 15
  msg_ok "LAN configuration sent"

  # Static WAN (from upstream), same console dialog
  if [ -n "$WAN_BRG" ] && [ "$WAN_IP_ADDR" != "" ]; then
    msg_info "Configuring static WAN address"
    send_line_to_vm "2"
    send_line_to_vm "2"
    send_line_to_vm "n"
    send_line_to_vm "${WAN_IP_ADDR}"
    send_line_to_vm "${WAN_NETMASK}"
    send_line_to_vm "${WAN_GW}"
    send_line_to_vm "n"
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
    wait_for_boot 10
    msg_ok "WAN configuration sent"
  fi
}

function automate_installer() {
  msg_info "Waiting for OPNsense live ISO to boot"
  wait_for_boot 90
  msg_ok "Live ISO should be ready"

  msg_info "Starting installer session"
  send_line_to_vm "installer"
  send_line_to_vm "opnsense"
  msg_ok "Installer credentials sent"

  msg_info "Waiting for installer menu"
  wait_for_boot 12

  if [ "$KEYMAP_MODE" = "default" ]; then
    msg_info "Accepting default keymap"
    send_key_to_vm ret
  else
    msg_info "Selecting French (accent keys) keymap"
    for _ in {1..27}; do
      send_key_to_vm down
    done
    send_key_to_vm ret
    wait_for_boot 2
    send_key_to_vm up
    wait_for_boot 2
    send_key_to_vm ret
  fi
  wait_for_boot 2

  msg_info "Switching boot order to disk"
  qm set $VMID -boot order='scsi0;ide2' >/dev/null
  msg_ok "Disk boot order configured"

  if [ "$FILESYSTEM_MODE" = "ufs" ]; then
    msg_info "Selecting UFS filesystem"
    send_key_to_vm down
    send_key_to_vm ret
    wait_for_boot 2

    msg_info "Selecting target disk"
    send_key_to_vm down
    send_key_to_vm spc
    send_key_to_vm ret
    wait_for_boot 280
  else
    msg_info "Selecting ZFS filesystem"
    send_key_to_vm ret
    wait_for_boot 2

    msg_info "Accepting default ZFS device type"
    send_key_to_vm ret
    wait_for_boot 2

    msg_info "Selecting target disk"
    send_key_to_vm spc
    send_key_to_vm ret
    wait_for_boot 2

    msg_info "Confirming destructive install"
    send_key_to_vm left
    send_key_to_vm ret
    wait_for_boot 280
  fi

  msg_info "Setting root password"
  send_key_to_vm ret
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  wait_for_boot 10

  msg_info "Completing installation"
  send_key_to_vm down
  send_key_to_vm ret
  wait_for_boot 5
  send_key_to_vm down
  send_key_to_vm ret

  msg_info "Detaching installation ISO"
  qm set $VMID -delete ide2 >/dev/null
  msg_ok "Installation ISO detached"
  wait_for_boot 20

  msg_info "Starting VM on installed disk"
  qm start $VMID >/dev/null
  wait_for_boot 85

  msg_info "Waking console before login"
  send_key_to_vm ret
  wait_for_boot 2
  send_key_to_vm ret
  wait_for_boot 2

  configure_lan_ip_after_login

  # Leave the console menu
  send_line_to_vm "0"
  msg_ok "Automatic install flow sent to guest"
}

vm_start_script "Use Default Settings?\n\nDefaults:\n• 4 CPU Cores\n• 8 GB RAM\n• 20 GB Disk\n• Official OPNsense ${var_version} ISO" 14 58
post_to_api_vm

vm_select_storage "$HN"
vm_select_iso_storage "$ISO_RAW_FILENAME" "$HN" || exit 119

ensure_opnsense_iso

vm_claim_vmid
msg_info "Creating a OPNsense VM"
# A firewall VM filters itself: Proxmox's per-NIC firewall off, and virtio
# multiqueue matched to the cores so routing scales past one vCPU.
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE -balloon 0 \
  -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC,firewall=0,queues=$CORE_COUNT$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null
vm_mark_created

msg_info "Allocating system disk"
# "<storage>:<GiB>" lets Proxmox allocate on any storage type
SCSI0_OPTS="${STORAGE}:${DISK_SIZE%G}"
DISK_EXTRA="${DISK_CACHE}${THIN}"
[[ -n "$DISK_EXTRA" ]] && SCSI0_OPTS+=",${DISK_EXTRA%,}"
qm set $VMID \
  -efidisk0 "${STORAGE}:1${EFI_OPTS}" \
  -scsi0 "$SCSI0_OPTS" \
  -ide2 "${ISO_VOLUME},media=cdrom" \
  -boot order='ide2;scsi0' \
  -serial0 socket >/dev/null
msg_ok "Disk and boot media configured"
set_description

if [ -n "$WAN_BRG" ]; then
  msg_info "Adding WAN interface"
  qm set $VMID \
    -net1 virtio,bridge=${WAN_BRG},macaddr=${WAN_MAC},firewall=0,queues=${CORE_COUNT} >/dev/null
  msg_ok "WAN interface added"
fi

msg_ok "Created a OPNsense VM ${CL}${BL}(${HN})"
msg_info "Starting OPNsense VM"
qm start $VMID >/dev/null
msg_ok "Started OPNsense VM, do not close the terminal, or the installation will fail."

automate_installer

if [[ "$START_VM" == "no" ]]; then
  msg_info "Shutting down OPNsense as requested"
  $STD qm shutdown "$VMID" --timeout 120
  msg_ok "OPNsense VM shut down"
else
  msg_ok "OPNsense VM is running"
fi

if [ "$IP_ADDR" != "" ]; then
  LAN_URL="https://${IP_ADDR}"
else
  LAN_URL="DHCP - check the OPNsense console or your leases"
fi
LAN_MODE_LABEL="$LAN_IP_MODE"
[ "$ENABLE_LAN_DHCP_SERVER" = "y" ] && LAN_MODE_LABEL+=" (DHCP server ${LAN_DHCP_RANGE_START}-${LAN_DHCP_RANGE_END})"

vm_print_summary \
  "LAN URL=${LAN_URL}" \
  "LAN Mode=${LAN_MODE_LABEL}" \
  "LAN Bridge=${BRG}" \
  "WAN Bridge=${WAN_BRG:-single-interface mode}" \
  "OPNsense Version=${var_version} (official ISO)" \
  "Filesystem=${FILESYSTEM_MODE^^}" \
  "Installer Keymap=${KEYMAP_MODE}"
vm_next_steps \
  "Verify the installation and network configuration in the OPNsense console." \
  "Login as root with password ${INSTALL_ROOT_PASSWORD}, then change the password immediately." \
  "This automation depends on the exact installer screens and may need timing tweaks on your host."
vm_finish "VM creation completed; verify the installation and network configuration in the console."

#!/usr/bin/env bash

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/elenedeath/ProxmoxVE/main/misc/api.func)

function header_info {
  clear
  cat <<"EOT"
   ____  ____  _   __
  / __ \/ __ \/ | / /_______  ____  ________
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \\
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/
EOT
}

header_info
echo -e "Loading..."

RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="26.7"
ISO_TYPE="dvd"
ISO_ARCH="amd64"
ISO_FILENAME="OPNsense-${var_version}-${ISO_TYPE}-${ISO_ARCH}.iso.bz2"
ISO_RAW_FILENAME="OPNsense-${var_version}-${ISO_TYPE}-${ISO_ARCH}.iso"
INSTALL_ROOT_PASSWORD="opnsense"

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\r\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  post_update_to_api "failed" "$exit_code"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null || true
    qm destroy $VMID &>/dev/null || true
  fi
}

function cleanup() {
  local exit_code=$?
  popd >/dev/null || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none"
    else
      post_update_to_api "failed" "$exit_code"
    fi
  fi
  rm -rf "$TEMP_DIR"
}

function check_disk_space() {
  local path="$1"
  local required_gb="$2"
  local available_kb
  available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  [ "$available_gb" -ge "$required_gb" ]
}

if [ -d "/var/tmp" ] && check_disk_space "/var/tmp" 4; then
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
elif [ -d "/tmp" ] && check_disk_space "/tmp" 4; then
  TEMP_DIR=$(mktemp -d)
else
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
fi
pushd "$TEMP_DIR" >/dev/null

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function send_line_to_vm() {
  local input="$1"
  echo -e "${DGN}Sending line: ${YW}$input${CL}"
  for ((i = 0; i < ${#input}; i++)); do
    character=${input:i:1}
    case $character in
      " ") character="spc" ;;
      "-") character="minus" ;;
      "=") character="equal" ;;
      ",") character="comma" ;;
      ".") character="dot" ;;
      "/") character="slash" ;;
      "'") character="apostrophe" ;;
      ";") character="semicolon" ;;
      '\\') character="backslash" ;;
      '`') character="grave_accent" ;;
      "[") character="bracket_left" ;;
      "]") character="bracket_right" ;;
      "_") character="shift-minus" ;;
      "+") character="shift-equal" ;;
      "?") character="shift-slash" ;;
      "<") character="shift-comma" ;;
      ">") character="shift-dot" ;;
      '"') character="shift-apostrophe" ;;
      ":") character="shift-semicolon" ;;
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

pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    return 0
  fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR <= 2)); then
      return 0
    fi
  fi
  msg_error "This version of Proxmox VE is not supported."
  exit 105
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${CROSS} This script will not work with PiMox! \n"
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1 && [ -n "${SSH_CLIENT:+x}" ]; then
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62; then
      clear
      exit
    fi
  fi
}

function exit_script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}

function get_available_bridges() {
  ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort
}

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m,pre-enrolled-keys=0"
  MACHINE=""
  HN="opnsense"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="4096"
  DISK_SIZE="20"
  BRG="vmbr0"
  VLAN=""
  MAC=$GEN_MAC
  WAN_MAC=$GEN_MAC_LAN
  WAN_BRG=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  local AVAILABLE_BRIDGES
  AVAILABLE_BRIDGES=$(get_available_bridges)
  local BRIDGE_COUNT
  BRIDGE_COUNT=$(echo "$AVAILABLE_BRIDGES" | wc -l)

  if ! ip link show "${BRG}" &>/dev/null; then
    msg_error "Bridge '${BRG}' does not exist"
    exit 1
  fi

  local DEFAULT_WAN_BRG
  DEFAULT_WAN_BRG=$(echo "$AVAILABLE_BRIDGES" | grep -v "^${BRG}$" | head -n1 || true)
  if [ "$BRIDGE_COUNT" -ge 2 ]; then
    if NETWORK_MODE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "NETWORK CONFIGURATION" --radiolist --cancel-button Exit-Script "Choose network setup mode for OPNsense:" 14 70 2 "dual" "Dual Interface (Firewall/Router) - uses ${DEFAULT_WAN_BRG}" ON "single" "Single Interface (Lab/Test only)" OFF 3>&1 1>&2 2>&3); then
      if [ "$NETWORK_MODE" = "dual" ]; then
        WAN_BRG="$DEFAULT_WAN_BRG"
      fi
    else
      exit_script
    fi
  fi
}

function start_script() {
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Exit 10 58; then
    header_info
    default_settings
  else
    exit_script
  fi
}

function find_opnsense_iso_url() {
  local mirror url
  for mirror in \
    "https://mirrors.vraphim.com/opnsense/releases/" \
    "https://pkg.opnsense.org/releases/"; do
    url="${mirror}${ISO_FILENAME}"
    if curl -fsI "$url" >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
  done
  return 1
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

  msg_info "Accepting default keymap"
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Choosing Quick/Easy install"
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Selecting UFS"
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Confirming target disk"
  send_key_to_vm spc
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Confirming destructive install"
  send_key_to_vm left
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Accepting recommended swap"
  send_key_to_vm ret
  wait_for_boot 15

  msg_info "Setting root password"
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  wait_for_boot 2

  msg_info "Completing installation and reboot request"
  send_key_to_vm ret
  wait_for_boot 35

  msg_info "Switching boot order to disk"
  qm set $VMID -boot order='scsi0;ide2' >/dev/null
  msg_ok "Disk boot order configured"

  msg_info "Rebooting VM from installed disk"
  qm reset $VMID >/dev/null
  wait_for_boot 70

  msg_info "Skipping manual VLAN assignment and accepting defaults"
  s

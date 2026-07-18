#!/usr/bin/env bash

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

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
FORCE_ISO_DOWNLOAD="no"
LAN_IP_MODE="dhcp"
LAN_STATIC_IP="192.168.1.1"
LAN_STATIC_MASK="24"
LAN_STATIC_GW=""
ENABLE_LAN_DHCP_SERVER="n"
LAN_DHCP_RANGE_START=""
LAN_DHCP_RANGE_END=""

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

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "ISO CACHE" --yesno "Reuse local OPNsense ISO if already present?" 10 62; then
    FORCE_ISO_DOWNLOAD="no"
  else
    FORCE_ISO_DOWNLOAD="yes"
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

function resolve_iso_storage_dir() {
  case "$ISO_STORAGE" in
    local) echo "/var/lib/vz/template/iso" ;;
    *) echo "/var/lib/vz/template/iso" ;;
  esac
}

function ensure_opnsense_iso() {
  local iso_dir
  iso_dir="$(resolve_iso_storage_dir)"
  local cached_iso="${iso_dir}/${ISO_RAW_FILENAME}"

  if [ "$FORCE_ISO_DOWNLOAD" != "yes" ] && [ -f "$cached_iso" ]; then
    msg_ok "Reusing existing ISO ${CL}${BL}${cached_iso}${CL}"
    return 0
  fi

  msg_info "Downloading official OPNsense ISO archive"
  curl -f#SL -o "${ISO_FILENAME}" "$ISO_URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${CL}${BL}${ISO_FILENAME}${CL}"

  msg_info "Decompressing ISO archive"
  bzip2 -df "${ISO_FILENAME}"
  msg_ok "Decompressed ${CL}${BL}${ISO_RAW_FILENAME}${CL}"

  msg_info "Copying ISO into Proxmox ISO storage"
  mkdir -p "$iso_dir"
  cp -f "${ISO_RAW_FILENAME}" "$cached_iso"
  msg_ok "ISO copied to ${CL}${BL}${cached_iso}${CL}"
}

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
    send_line_to_vm "${LAN_STATIC_IP}"
    send_line_to_vm "${LAN_STATIC_MASK}"
    send_line_to_vm "${LAN_STATIC_GW}"
    send_line_to_vm "n"
    send_line_to_vm " "
    send_line_to_vm "n"
    send_line_to_vm "${ENABLE_LAN_DHCP_SERVER}"
    if [ "$ENABLE_LAN_DHCP_SERVER" = "y" ]; then
      send_line_to_vm "${LAN_DHCP_RANGE_START}"
      send_line_to_vm "${LAN_DHCP_RANGE_END}"
    fi
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
    send_line_to_vm "n"
  fi
  wait_for_boot 15
  msg_ok "LAN configuration sent"
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

  msg_info "Selecting filesystem option"
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Selecting target disk"
  send_key_to_vm spc
  send_key_to_vm ret
  wait_for_boot 2

  msg_info "Confirming destructive install"
  send_key_to_vm left
  send_key_to_vm ret
  wait_for_boot 180

  msg_info "Accepting recommended swap if shown"
  send_key_to_vm ret
  wait_for_boot 8

  msg_info "Setting root password"
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  send_line_to_vm "${INSTALL_ROOT_PASSWORD}"
  wait_for_boot 6

  msg_info "Completing installation"
  send_key_to_vm ret
  wait_for_boot 15

  msg_info "Switching boot order to disk"
  qm set $VMID -boot order='scsi0;ide2' >/dev/null
  msg_ok "Disk boot order configured"

  msg_info "Rebooting VM from installed disk"
  qm reset $VMID >/dev/null
  wait_for_boot 85

  msg_info "Waking console before login"
  send_key_to_vm ret
  wait_for_boot 2
  send_key_to_vm ret
  wait_for_boot 2

  configure_lan_ip_after_login

  msg_ok "Automatic install flow sent to guest"
}

arch_check
pve_check
ssh_check
start_script
post_to_api_vm

msg_info "Validating Storage"
STORAGE=$(pvesm status -content images | awk 'NR==2 {print $1}')
if [ -z "$STORAGE" ]; then
  msg_error "Unable to detect a valid storage location."
  exit 1
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for VM disks."

msg_info "Validating ISO storage"
ISO_STORAGE=$(pvesm status -content iso | awk 'NR==2 {print $1}')
if [ -z "${ISO_STORAGE:-}" ]; then
  msg_error "No storage with ISO content enabled was found."
  exit 116
fi
msg_ok "Using ${CL}${BL}${ISO_STORAGE}${CL} ${GN}for ISO storage."

msg_info "Locating official OPNsense ISO"
ISO_URL=$(find_opnsense_iso_url) || {
  msg_error "Unable to locate ${ISO_FILENAME} on known OPNsense mirrors."
  exit 117
}
msg_ok "Download URL: ${CL}${BL}${ISO_URL}${CL}"

ensure_opnsense_iso

msg_info "Creating OPNsense VM"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE -name $HN -tags community-script -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null
msg_ok "VM created"

msg_info "Allocating system disk"
qm set $VMID -scsi0 ${STORAGE}:${DISK_SIZE},discard=on,ssd=1 >/dev/null
msg_ok "Disk attached"

msg_info "Configuring boot media"
qm set $VMID -efidisk0 ${STORAGE}:1${FORMAT} >/dev/null
qm set $VMID -ide2 ${ISO_STORAGE}:iso/${ISO_RAW_FILENAME},media=cdrom >/dev/null
qm set $VMID -boot order='ide2;scsi0' >/dev/null
qm set $VMID -serial0 socket >/dev/null
msg_ok "Boot media configured"

msg_info "Adding LAN interface"
qm set $VMID -net0 virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU} >/dev/null
msg_ok "LAN interface added"

if [ -n "$WAN_BRG" ]; then
  msg_info "Adding WAN interface"
  qm set $VMID -net1 virtio,bridge=${WAN_BRG},macaddr=${WAN_MAC} >/dev/null
  msg_ok "WAN interface added"
fi

DESCRIPTION=$(
cat <<EOF
<div align='center'>
<a href='https://community-scripts.org' target='_blank' rel='noopener noreferrer'>
<img src='https://raw.githubusercontent.com/michelroegl-brunner/ProxmoxVE/refs/heads/develop/misc/images/logo-81x112.png' alt='Logo' style='width:81px;height:112px;'/>
</a>

<h2 style='font-size: 24px; margin: 20px 0;'>OPNsense ${var_version} VM (Official ISO)</h2>

<p style='margin: 16px 0;'>
<a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
<img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />
</a>
</p>

<span style='margin: 0 10px;'>
<i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
<a href='https://github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
</span>
<span style='margin: 0 10px;'>
<i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
<a href='https://github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
</span>
<span style='margin: 0 10px;'>
<i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
<a href='https://github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
</span>
</div>
EOF
)
qm set $VMID -description "$DESCRIPTION" >/dev/null

msg_info "Starting VM"
qm start $VMID >/dev/null
msg_ok "VM started"

automate_installer

msg_ok "Completed successfully!"
echo -e "${YW}Expected result:${CL}"
echo -e " - OPNsense installed on disk"
echo -e " - Guest rebooted on system disk"
echo -e " - Default LAN configuration kept during automated setup"
echo -e " - Web UI should answer on https://192.168.1.1 unless interface naming/order differs"
echo -e "${RD}Warning:${CL} This automation depends on the exact installer screens and may need timing tweaks on your host."

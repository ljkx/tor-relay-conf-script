#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
case "$SCRIPT_NAME" in
  bash|sh|dash|bash.exe|sh.exe|dash.exe)
    SCRIPT_NAME="setup-tor-guard-relay.sh"
    ;;
esac
VERSION="1.0.4"
DRY_RUN=0

TMP_DIR=""
TIMESTAMP=""
BACKUPS_CREATED=()

OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""
ARCHITECTURE=""

CHANGE_HOSTNAME=0
CURRENT_HOSTNAME=""
NEW_HOSTNAME=""

RELAY_NICKNAME=""
CONTACT_INFO=""
OR_PORT="9001"
ENABLE_IPV6=0
IPV6_ADDRESS=""
CONFIGURE_RELAY_BANDWIDTH=0
RELAY_BANDWIDTH_RATE_MBITS=""
RELAY_BANDWIDTH_BURST_MBITS=""
CONFIGURE_ACCOUNTING=0
ACCOUNTING_MAX_GBYTES=""
ENABLE_AUTO_UPDATES=1
ENABLE_FIREWALL=0
FIREWALL_KIND="none"
FIREWALL_STATE="unavailable"
ENABLE_TOR_SANDBOX=1

TORRC_PATH="/etc/tor/torrc"
TOR_SOURCES_PATH="/etc/apt/sources.list.d/tor.sources"
TOR_KEYRING_PATH="/usr/share/keyrings/deb.torproject.org-keyring.gpg"
UNATTENDED_TOR_PATH="/etc/apt/apt.conf.d/52tor-relay-unattended-upgrades"
AUTO_UPGRADES_PATH="/etc/apt/apt.conf.d/20auto-upgrades"
TOR_SERVICE="tor@default"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  RESET=""
fi

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    case "$TMP_DIR" in
      /tmp/*|/var/tmp/*)
        rm -rf -- "$TMP_DIR"
        ;;
      *)
        warn "Refusing to remove unexpected temporary directory: ${TMP_DIR}"
        ;;
    esac
  fi
}

on_error() {
  local exit_code=$?
  local line_number=${1:-unknown}
  printf '\n%b[ERROR]%b %s failed near line %s (exit %s).\n' "$RED" "$RESET" "$SCRIPT_NAME" "$line_number" "$exit_code" >&2
  printf '%b       Review the message above, fix the issue, and re-run the script.%b\n' "$DIM" "$RESET" >&2
  exit "$exit_code"
}

on_interrupt() {
  printf '\n%b[STOP]%b Interrupted. No further changes will be made.\n' "$YELLOW" "$RESET" >&2
  exit 130
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR
trap on_interrupt INT TERM

print_help() {
  cat <<EOF
${SCRIPT_NAME} ${VERSION}

Interactively configure a non-exit Tor Guard / middle relay on a fresh
Debian or Ubuntu VPS.

Usage:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} --dry-run
  ./${SCRIPT_NAME} --help

Options:
  --dry-run   Prompt normally and print the system changes that would be made,
              without installing packages or writing system files.
  --help      Show this help text and exit.
  --version   Show the script version and exit.

Supported targets:
  Debian 12 (bookworm), Debian 13 (trixie)
  Ubuntu 22.04 LTS (jammy), Ubuntu 24.04 LTS (noble)

This script configures a non-exit relay only. It writes ExitRelay 0 and
SocksPort 0, and it never enables exit relay behavior.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
        exit 0
        ;;
      *)
        printf '%b[ERROR]%b Unknown option: %s\n\n' "$RED" "$RESET" "$1" >&2
        print_help >&2
        exit 2
        ;;
    esac
    shift
  done
}

banner() {
  printf '%b\n' "$CYAN"
  cat <<'EOF'
  ============================================================
       Tor Guard / Middle Relay Setup
  ============================================================
EOF
  printf '%b' "$RESET"
  printf '%s\n' "  This installer configures a public non-exit Tor relay."
  printf '%s\n\n' "  It will show a summary before making privileged changes."
}

section() {
  printf '\n%b== %s ==%b\n' "$BOLD$BLUE" "$1" "$RESET"
}

info() {
  printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"
}

success() {
  printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_command() {
  printf '    +'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  local description=$1
  local exit_code
  shift

  info "$description"
  if ((DRY_RUN)); then
    print_command "$@"
    return 0
  fi

  set +e
  "$@"
  exit_code=$?
  set -e

  if ((exit_code != 0)); then
    printf '%b[ERROR]%b Command failed with exit %s:' "$RED" "$RESET" "$exit_code" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return "$exit_code"
  fi
}

trim() {
  local value=$*
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_line() {
  local prompt=$1
  local default_value=${2:-}
  local reply

  if [[ -n "$default_value" ]]; then
    prompt_printf '%b%s%b [%s]: ' "$BOLD" "$prompt" "$RESET" "$default_value"
  else
    prompt_printf '%b%s%b: ' "$BOLD" "$prompt" "$RESET"
  fi

  read_reply reply
  if [[ -z "$reply" && -n "$default_value" ]]; then
    reply=$default_value
  fi
  trim "$reply"
}

prompt_printf() {
  local format=$1
  shift

  if [[ -w /dev/tty ]]; then
    # shellcheck disable=SC2059
    printf "$format" "$@" > /dev/tty
  else
    # shellcheck disable=SC2059
    printf "$format" "$@" >&2
  fi
}

read_reply() {
  local variable_name=$1

  if [[ -r /dev/tty ]]; then
    if ! IFS= read -r "$variable_name" < /dev/tty; then
      die "No input received from the terminal."
    fi
  elif [[ -t 0 ]]; then
    if ! IFS= read -r "$variable_name"; then
      die "No input received from stdin."
    fi
  else
    die "Interactive input is required. Run from a terminal, or use --help for noninteractive usage."
  fi
}

ask_yes_no() {
  local prompt=$1
  local default_answer=${2:-}
  local suffix
  local reply

  case "$default_answer" in
    yes) suffix="[Y/n]" ;;
    no) suffix="[y/N]" ;;
    *) suffix="[y/n]" ;;
  esac

  while true; do
    prompt_printf '%b%s%b %s: ' "$BOLD" "$prompt" "$RESET" "$suffix"
    read_reply reply
    reply=$(trim "$reply")
    reply=${reply,,}

    if [[ -z "$reply" && -n "$default_answer" ]]; then
      reply=$default_answer
    fi

    case "$reply" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

valid_integer() {
  [[ $1 =~ ^[0-9]+$ ]]
}

valid_port() {
  local value=$1
  valid_integer "$value" || return 1
  local number=$((10#$value))
  ((number >= 1 && number <= 65535))
}

valid_nickname() {
  [[ $1 =~ ^[A-Za-z0-9]{1,19}$ ]]
}

valid_contact_info() {
  local value=$1
  [[ -n "$value" ]] || return 1
  [[ ${#value} -le 250 ]] || return 1
  [[ "$value" != *$'\n'* ]] || return 1
  [[ "$value" != *"#"* ]] || return 1
}

valid_system_hostname() {
  local value=$1
  local label
  local lower_value=${value,,}
  local -a labels

  [[ -n "$value" && ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  [[ "$lower_value" != "localhost" && "$lower_value" != "localhost.localdomain" ]] || return 1

  IFS='.' read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

valid_ipv6_address() {
  local value=$1
  [[ "$value" == *:* ]] || return 1
  [[ "$value" != *" "* ]] || return 1
  [[ "$value" != *"["* && "$value" != *"]"* ]] || return 1
  [[ "$value" != */* ]] || return 1
}

torrc_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

require_supported_system() {
  section "System Check"

  [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux targets only."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"

  if [[ -z "$OS_CODENAME" ]] && command_exists lsb_release; then
    OS_CODENAME=$(lsb_release -cs)
  fi

  local expected_codename=""
  case "${OS_ID}:${OS_VERSION_ID}" in
    debian:12) expected_codename="bookworm" ;;
    debian:13) expected_codename="trixie" ;;
    ubuntu:22.04) expected_codename="jammy" ;;
    ubuntu:24.04) expected_codename="noble" ;;
    *)
      die "Unsupported OS: ${OS_PRETTY_NAME}. Supported: Debian 12/13, Ubuntu 22.04/24.04."
      ;;
  esac

  if [[ -n "$OS_CODENAME" && "$OS_CODENAME" != "$expected_codename" ]]; then
    die "Detected ${OS_PRETTY_NAME}, but codename '${OS_CODENAME}' does not match expected '${expected_codename}'."
  fi
  OS_CODENAME=$expected_codename

  command_exists apt-get || die "apt-get is required."
  command_exists dpkg || die "dpkg is required."
  command_exists systemctl || die "systemd/systemctl is required."

  ARCHITECTURE=$(dpkg --print-architecture)
  case "$ARCHITECTURE" in
    amd64|arm64) ;;
    *)
      die "Unsupported CPU architecture '${ARCHITECTURE}'. The Tor Project apt repository currently offers amd64 and arm64 packages."
      ;;
  esac

  success "Supported target: ${OS_PRETTY_NAME} (${OS_CODENAME}, ${ARCHITECTURE})"

  if ((DRY_RUN)); then
    warn "Dry-run mode is active. No packages or system files will be changed."
  elif ((EUID != 0)); then
    die "Run this script as root, for example: sudo ./${SCRIPT_NAME}"
  fi
}

detect_firewall() {
  FIREWALL_KIND="none"
  FIREWALL_STATE="unavailable"

  if command_exists ufw; then
    FIREWALL_KIND="ufw"
    local ufw_status=""
    ufw_status=$(ufw status 2>/dev/null | head -n 1 || true)
    case "${ufw_status,,}" in
      *active*) FIREWALL_STATE="active" ;;
      *inactive*) FIREWALL_STATE="inactive" ;;
      *) FIREWALL_STATE="installed" ;;
    esac
    return 0
  fi

  if command_exists firewall-cmd; then
    FIREWALL_KIND="firewalld"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      FIREWALL_STATE="active"
    else
      FIREWALL_STATE="inactive"
    fi
    return 0
  fi

  if command_exists nft; then
    if nft list chain inet filter input >/dev/null 2>&1; then
      FIREWALL_KIND="nftables"
      FIREWALL_STATE="inet filter input chain found"
    else
      FIREWALL_KIND="nftables"
      FIREWALL_STATE="no supported inet filter input chain"
    fi
  fi
}

collect_system_hostname() {
  section "System Hostname"

  if command_exists hostnamectl; then
    CURRENT_HOSTNAME=$(hostnamectl --static 2>/dev/null || true)
  fi
  if [[ -z "$CURRENT_HOSTNAME" ]] && command_exists hostname; then
    CURRENT_HOSTNAME=$(hostname 2>/dev/null || true)
  fi
  CURRENT_HOSTNAME=${CURRENT_HOSTNAME:-unknown}

  info "Current system hostname: ${CURRENT_HOSTNAME}"
  info "This is the Linux server name, not your public Tor relay nickname."

  if ! command_exists hostnamectl; then
    warn "hostnamectl is not available, so this installer will not change the system hostname."
    CHANGE_HOSTNAME=0
    return 0
  fi

  if ! ask_yes_no "Change the system hostname before configuring Tor?" "no"; then
    CHANGE_HOSTNAME=0
    return 0
  fi

  while true; do
    NEW_HOSTNAME=$(prompt_line "New system hostname" "$CURRENT_HOSTNAME")
    if valid_system_hostname "$NEW_HOSTNAME"; then
      break
    fi
    warn "Use DNS-style hostname labels: letters, numbers, hyphens, and dots; no spaces or underscores."
  done

  if [[ "$NEW_HOSTNAME" == "$CURRENT_HOSTNAME" ]]; then
    success "System hostname will stay unchanged."
    CHANGE_HOSTNAME=0
  else
    CHANGE_HOSTNAME=1
  fi
}

list_ipv6_candidates() {
  if ! command_exists ip; then
    return 0
  fi

  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ { sub(/\/.*/, "", $2); print $2 }' \
    | grep -v '^fe80:' || true
}

ipv6_connectivity_ok() {
  local authorities=(
    "2001:858:2:2:aabb:0:563b:1526"
    "2620:13:4000:6000::1000:118"
    "2001:67c:289c::9"
    "2001:678:558:1000::244"
    "2001:638:a000:4140::ffff:189"
  )
  local ping_cmd=()
  local address

  if command_exists ping6; then
    ping_cmd=(ping6 -c 2 -W 3)
  elif command_exists ping; then
    ping_cmd=(ping -6 -c 2 -W 3)
  else
    return 2
  fi

  for address in "${authorities[@]}"; do
    "${ping_cmd[@]}" "$address" >/dev/null 2>&1 || return 1
  done

  return 0
}

collect_relay_identity() {
  section "Relay Identity"
  info "Your nickname and ContactInfo will be public in Tor relay directories."

  while true; do
    RELAY_NICKNAME=$(prompt_line "Relay nickname (1-19 letters/numbers)")
    if valid_nickname "$RELAY_NICKNAME"; then
      break
    fi
    warn "Use 1 to 19 characters, letters and numbers only."
  done

  while true; do
    CONTACT_INFO=$(prompt_line "ContactInfo email or contact string")
    if valid_contact_info "$CONTACT_INFO"; then
      break
    fi
    warn "ContactInfo must be non-empty, under 250 characters, and cannot contain '#'."
  done

  while true; do
    OR_PORT=$(prompt_line "ORPort for incoming Tor connections" "9001")
    if valid_port "$OR_PORT"; then
      break
    fi
    warn "Enter a TCP port from 1 through 65535."
  done

  if ((10#$OR_PORT < 1024)); then
    warn "Ports below 1024 can require extra privileges. The official guide often recommends 443 when it is available, but 9001 is common and simpler."
  fi

  printf '\n'
  warn "This installer is for a Guard / middle relay only. It will not configure an exit relay."
  if ! ask_yes_no "Do you confirm this server is NOT intended to be an exit relay?" "no"; then
    die "Aborted because exit relay intent was not rejected."
  fi
}

collect_ipv6() {
  section "IPv6"
  info "Tor encourages IPv6 on relays, but only when IPv6 connectivity actually works."

  if ! ask_yes_no "Configure an additional IPv6 ORPort?" "no"; then
    ENABLE_IPV6=0
    return 0
  fi

  local candidates
  local candidate
  local default_ipv6=""
  candidates=$(list_ipv6_candidates)
  if [[ -n "$candidates" ]]; then
    default_ipv6=$(printf '%s\n' "$candidates" | head -n 1)
    printf '%s\n' "Detected global IPv6 candidates:"
    while IFS= read -r candidate; do
      printf '  - %s\n' "$candidate"
    done <<< "$candidates"
    info "Press Enter at the IPv6 prompt to use ${default_ipv6}; type '-' to skip IPv6."
  else
    warn "No global IPv6 address was auto-detected. You can still enter one manually."
  fi

  while true; do
    if [[ -n "$default_ipv6" ]]; then
      IPV6_ADDRESS=$(prompt_line "IPv6 address to advertise (without brackets, '-' to skip)" "$default_ipv6")
    else
      IPV6_ADDRESS=$(prompt_line "IPv6 address to advertise (without brackets, blank to skip)")
    fi
    if [[ -z "$IPV6_ADDRESS" ]]; then
      ENABLE_IPV6=0
      return 0
    fi
    if [[ "$IPV6_ADDRESS" == "-" || "${IPV6_ADDRESS,,}" == "skip" ]]; then
      ENABLE_IPV6=0
      IPV6_ADDRESS=""
      return 0
    fi
    if valid_ipv6_address "$IPV6_ADDRESS"; then
      ENABLE_IPV6=1
      break
    fi
    warn "Enter a plain global IPv6 address, without brackets or CIDR suffix."
  done

  info "This early IPv6 check is outbound-only; inbound ORPort reachability is checked after the firewall rule and Tor restart."
  if ask_yes_no "Run the Tor-recommended outbound IPv6 connectivity check now?" "yes"; then
    info "Pinging Tor directory authority IPv6 addresses. This does not require TCP ${OR_PORT} to be open."
    if ipv6_connectivity_ok; then
      success "Outbound IPv6 connectivity check passed."
    else
      warn "Outbound IPv6 connectivity check failed or could not complete."
      warn "Tor warns that enabling a broken IPv6 ORPort can leave the relay unused."
      if ask_yes_no "Disable IPv6 ORPort for safety?" "yes"; then
        ENABLE_IPV6=0
        IPV6_ADDRESS=""
      fi
    fi
  else
    warn "Skipped outbound IPv6 connectivity check. Only keep IPv6 enabled if you know it works."
  fi
}

available_kib_for_path() {
  local path=$1
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

available_inodes_for_path() {
  local path=$1
  df -Pi "$path" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

check_path_capacity() {
  local path=$1
  local min_kib=$2
  local min_inodes=$3
  local available_kib
  local available_inodes

  [[ -e "$path" ]] || return 0

  available_kib=$(available_kib_for_path "$path")
  available_inodes=$(available_inodes_for_path "$path")

  if [[ -n "$available_kib" && "$available_kib" =~ ^[0-9]+$ && ((available_kib < min_kib)) ]]; then
    die "Not enough free disk space for apt under ${path}. Need at least $((min_kib / 1024)) MiB free; found $((available_kib / 1024)) MiB. Run: df -h"
  fi

  if [[ -n "$available_inodes" && "$available_inodes" =~ ^[0-9]+$ && ((available_inodes < min_inodes)) ]]; then
    die "Not enough free inodes for apt under ${path}. Need at least ${min_inodes}; found ${available_inodes}. Run: df -ih"
  fi
}

check_apt_capacity() {
  section "Preflight"

  if ((DRY_RUN)); then
    info "Dry run: skipping apt disk-space preflight."
    return 0
  fi

  command_exists df || die "df is required for the apt disk-space preflight."

  check_path_capacity /var/lib/apt/lists 512000 2048
  check_path_capacity /var/cache/apt/archives 512000 2048
  check_path_capacity /var 512000 2048
  check_path_capacity /tmp 65536 512
  success "apt has enough free disk space and inodes for package operations."
}

collect_bandwidth() {
  section "Bandwidth and Traffic"
  info "Without limits, Tor will not set a relay-specific bandwidth cap."

  if ask_yes_no "Set RelayBandwidthRate and RelayBandwidthBurst?" "yes"; then
    CONFIGURE_RELAY_BANDWIDTH=1
    while true; do
      RELAY_BANDWIDTH_RATE_MBITS=$(prompt_line "Average relay bandwidth in Mbit/s" "16")
      if valid_integer "$RELAY_BANDWIDTH_RATE_MBITS" && ((10#$RELAY_BANDWIDTH_RATE_MBITS >= 1)); then
        break
      fi
      warn "Enter a positive whole number."
    done

    if ((10#$RELAY_BANDWIDTH_RATE_MBITS < 10)); then
      warn "Tor relay requirements say 10 Mbit/s is the practical minimum; 16 Mbit/s or more is recommended."
      if ! ask_yes_no "Continue with ${RELAY_BANDWIDTH_RATE_MBITS} Mbit/s anyway?" "no"; then
        collect_bandwidth
        return 0
      fi
    elif ((10#$RELAY_BANDWIDTH_RATE_MBITS < 16)); then
      warn "16 Mbit/s or more is recommended when available."
    fi

    local default_burst=$((10#$RELAY_BANDWIDTH_RATE_MBITS * 2))
    while true; do
      RELAY_BANDWIDTH_BURST_MBITS=$(prompt_line "Burst bandwidth in Mbit/s" "$default_burst")
      if valid_integer "$RELAY_BANDWIDTH_BURST_MBITS" && ((10#$RELAY_BANDWIDTH_BURST_MBITS >= 10#$RELAY_BANDWIDTH_RATE_MBITS)); then
        break
      fi
      warn "Enter a whole number greater than or equal to the average rate."
    done
  else
    CONFIGURE_RELAY_BANDWIDTH=0
  fi

  if ask_yes_no "Set a monthly AccountingMax traffic cap?" "no"; then
    CONFIGURE_ACCOUNTING=1
    while true; do
      ACCOUNTING_MAX_GBYTES=$(prompt_line "Monthly cap in GBytes, per direction" "2000")
      if valid_integer "$ACCOUNTING_MAX_GBYTES" && ((10#$ACCOUNTING_MAX_GBYTES >= 1)); then
        break
      fi
      warn "Enter a positive whole number of GBytes."
    done

    if ((10#$ACCOUNTING_MAX_GBYTES < 100)); then
      warn "Tor relay requirements say relays need at least 100 GBytes outbound and 100 GBytes inbound per month."
      if ! ask_yes_no "Continue with ${ACCOUNTING_MAX_GBYTES} GBytes anyway?" "no"; then
        CONFIGURE_ACCOUNTING=0
        ACCOUNTING_MAX_GBYTES=""
      fi
    fi
  else
    CONFIGURE_ACCOUNTING=0
  fi
}

collect_maintenance_options() {
  section "Maintenance Options"

  info "Automatic security updates are strongly recommended for relay operators."
  if ask_yes_no "Configure unattended upgrades for security and Tor packages?" "yes"; then
    ENABLE_AUTO_UPDATES=1
  else
    ENABLE_AUTO_UPDATES=0
    warn "You chose not to configure automatic updates. Keep Tor and the OS updated manually."
  fi

  detect_firewall
  printf '%s\n' "Detected firewall: ${FIREWALL_KIND} (${FIREWALL_STATE})"
  case "$FIREWALL_KIND:$FIREWALL_STATE" in
    none:*)
      ENABLE_FIREWALL=0
      warn "No supported firewall manager was detected. You may need to open TCP ${OR_PORT} in your VPS/cloud firewall."
      ;;
    nftables:"no supported inet filter input chain")
      ENABLE_FIREWALL=0
      warn "nftables is present, but no 'inet filter input' chain was found. The script will not guess a ruleset."
      ;;
    ufw:inactive|firewalld:inactive)
      if ask_yes_no "Add an ORPort rule anyway? The script will not enable the inactive firewall." "no"; then
        ENABLE_FIREWALL=1
      else
        ENABLE_FIREWALL=0
      fi
      ;;
    *)
      if ask_yes_no "Open TCP ${OR_PORT} in ${FIREWALL_KIND}?" "yes"; then
        ENABLE_FIREWALL=1
      else
        ENABLE_FIREWALL=0
      fi
      ;;
  esac

  info "SafeLogging stays enabled. The optional Tor syscall sandbox adds Linux hardening."
  if ask_yes_no "Enable Tor's syscall Sandbox option?" "yes"; then
    ENABLE_TOR_SANDBOX=1
  else
    ENABLE_TOR_SANDBOX=0
  fi
}

build_torrc() {
  local output=$1
  {
    printf '# Generated by %s on %s UTC.\n' "$SCRIPT_NAME" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '# Non-exit Tor Guard / middle relay configuration.\n'
    printf '# Review Tor Project relay documentation before making manual changes.\n'
    printf '\n'
    printf 'Nickname %s\n' "$RELAY_NICKNAME"
    printf 'ContactInfo %s\n' "$(torrc_quote "$CONTACT_INFO")"
    printf 'ORPort %s\n' "$OR_PORT"
    if ((ENABLE_IPV6)); then
      printf 'ORPort [%s]:%s\n' "$IPV6_ADDRESS" "$OR_PORT"
    fi
    printf '\n'
    printf '# This script configures a non-exit relay only.\n'
    printf 'ExitRelay 0\n'
    printf 'SocksPort 0\n'
    printf '\n'
    printf '# Keep potentially sensitive log details scrubbed.\n'
    printf 'SafeLogging 1\n'
    if ((ENABLE_TOR_SANDBOX)); then
      printf 'Sandbox 1\n'
    fi
    if ((CONFIGURE_RELAY_BANDWIDTH)); then
      printf '\n'
      printf '# Relay-specific bandwidth limits. Units are bits per second here.\n'
      printf 'RelayBandwidthRate %s MBits\n' "$RELAY_BANDWIDTH_RATE_MBITS"
      printf 'RelayBandwidthBurst %s MBits\n' "$RELAY_BANDWIDTH_BURST_MBITS"
    fi
    if ((CONFIGURE_ACCOUNTING)); then
      printf '\n'
      printf '# Monthly accounting cap. AccountingMax applies per direction.\n'
      printf 'AccountingStart month 1 00:00\n'
      printf 'AccountingMax %s GBytes\n' "$ACCOUNTING_MAX_GBYTES"
    fi
  } > "$output"
}

build_tor_sources() {
  local output=$1
  {
    printf 'Types: deb deb-src\n'
    printf 'URIs: https://deb.torproject.org/torproject.org/\n'
    printf 'Suites: %s\n' "$OS_CODENAME"
    printf 'Components: main\n'
    printf 'Signed-By: %s\n' "$TOR_KEYRING_PATH"
  } > "$output"
}

build_unattended_tor_config() {
  local output=$1
  {
    printf '// Managed by %s. Enables unattended upgrades for Tor Project packages.\n' "$SCRIPT_NAME"
    if [[ "$OS_ID" == "debian" ]]; then
      printf 'Unattended-Upgrade::Origins-Pattern {\n'
      printf '    "origin=Debian,codename=${distro_codename},label=Debian-Security";\n'
      printf '    "origin=TorProject";\n'
      printf '};\n'
    else
      printf 'Unattended-Upgrade::Allowed-Origins {\n'
      printf '    "${distro_id}:${distro_codename}-security";\n'
      printf '    "TorProject:${distro_codename}";\n'
      printf '};\n'
    fi
    printf 'Unattended-Upgrade::Package-Blacklist {\n'
    printf '};\n'
  } > "$output"
}

build_auto_upgrades_config() {
  local output=$1
  {
    printf 'APT::Periodic::Update-Package-Lists "1";\n'
    printf 'APT::Periodic::AutocleanInterval "5";\n'
    printf 'APT::Periodic::Unattended-Upgrade "1";\n'
    printf 'APT::Periodic::Verbose "1";\n'
  } > "$output"
}

build_hosts_file() {
  local output=$1
  local hosts_entry=$NEW_HOSTNAME

  if [[ "$NEW_HOSTNAME" == *.* ]]; then
    hosts_entry="${NEW_HOSTNAME} ${NEW_HOSTNAME%%.*}"
  fi

  if [[ -r /etc/hosts ]]; then
    awk -v hosts_entry="$hosts_entry" '
      BEGIN { updated = 0 }
      $1 == "127.0.1.1" && updated == 0 {
        print "127.0.1.1\t" hosts_entry
        updated = 1
        next
      }
      $1 == "127.0.1.1" { next }
      { print }
      END {
        if (updated == 0) {
          print "127.0.1.1\t" hosts_entry
        }
      }
    ' /etc/hosts > "$output"
  else
    {
      printf '127.0.0.1\tlocalhost\n'
      printf '127.0.1.1\t%s\n' "$hosts_entry"
      printf '::1\tlocalhost ip6-localhost ip6-loopback\n'
    } > "$output"
  fi
}

backup_file() {
  local target=$1
  local backup

  [[ -e "$target" || -L "$target" ]] || return 0

  backup="${target}.bak.${TIMESTAMP}"
  if ((DRY_RUN)); then
    info "Would back up ${target} to ${backup}"
  else
    cp -a -- "$target" "$backup"
    BACKUPS_CREATED+=("$backup")
    success "Backed up ${target} to ${backup}"
  fi
}

install_file_if_changed() {
  local source=$1
  local target=$2
  local mode=${3:-0644}

  if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
    success "Already current: ${target}"
    return 0
  fi

  backup_file "$target"
  if ((DRY_RUN)); then
    info "Would install ${target}"
    print_command install -D -m "$mode" "$source" "$target"
  else
    install -D -m "$mode" "$source" "$target"
    success "Installed ${target}"
  fi
}

show_summary() {
  local torrc_preview="$TMP_DIR/torrc.preview"
  build_torrc "$torrc_preview"

  section "Review Before Applying"
  printf '%bTarget%b: %s (%s, %s)\n' "$BOLD" "$RESET" "$OS_PRETTY_NAME" "$OS_CODENAME" "$ARCHITECTURE"
  if ((CHANGE_HOSTNAME)); then
    printf '%bSystem hostname%b: %s -> %s\n' "$BOLD" "$RESET" "$CURRENT_HOSTNAME" "$NEW_HOSTNAME"
  else
    printf '%bSystem hostname%b: unchanged (%s)\n' "$BOLD" "$RESET" "$CURRENT_HOSTNAME"
  fi
  printf '%bRelay%b: %s on ORPort %s\n' "$BOLD" "$RESET" "$RELAY_NICKNAME" "$OR_PORT"
  printf '%bContactInfo%b: %s\n' "$BOLD" "$RESET" "$CONTACT_INFO"
  if ((ENABLE_IPV6)); then
    printf '%bIPv6 ORPort%b: [%s]:%s\n' "$BOLD" "$RESET" "$IPV6_ADDRESS" "$OR_PORT"
  else
    printf '%bIPv6 ORPort%b: disabled\n' "$BOLD" "$RESET"
  fi
  if ((CONFIGURE_RELAY_BANDWIDTH)); then
    printf '%bBandwidth%b: %s MBits average, %s MBits burst\n' "$BOLD" "$RESET" "$RELAY_BANDWIDTH_RATE_MBITS" "$RELAY_BANDWIDTH_BURST_MBITS"
  else
    printf '%bBandwidth%b: no relay-specific cap\n' "$BOLD" "$RESET"
  fi
  if ((CONFIGURE_ACCOUNTING)); then
    printf '%bAccountingMax%b: %s GBytes per direction, monthly reset\n' "$BOLD" "$RESET" "$ACCOUNTING_MAX_GBYTES"
  else
    printf '%bAccountingMax%b: not configured\n' "$BOLD" "$RESET"
  fi
  printf '%bAutomatic updates%b: %s\n' "$BOLD" "$RESET" "$([[ $ENABLE_AUTO_UPDATES -eq 1 ]] && printf yes || printf no)"
  printf '%bFirewall change%b: %s (%s)\n' "$BOLD" "$RESET" "$([[ $ENABLE_FIREWALL -eq 1 ]] && printf yes || printf no)" "$FIREWALL_KIND"
  printf '%bTor Sandbox%b: %s\n' "$BOLD" "$RESET" "$([[ $ENABLE_TOR_SANDBOX -eq 1 ]] && printf yes || printf no)"

  printf '\n%s\n' "torrc preview:"
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < "$torrc_preview"

  printf '\n%s\n' "Planned privileged changes:"
  if ((CHANGE_HOSTNAME)); then
    printf '  - Set the system hostname to %s and update /etc/hosts.\n' "$NEW_HOSTNAME"
  fi
  printf '  - Configure the official Tor Project apt repository for %s.\n' "$OS_CODENAME"
  printf '  - Install tor and deb.torproject.org-keyring.\n'
  printf '  - Back up and update %s.\n' "$TORRC_PATH"
  if ((ENABLE_AUTO_UPDATES)); then
    printf '  - Configure unattended upgrades for security and Tor packages.\n'
  fi
  if ((ENABLE_FIREWALL)); then
    printf '  - Add a TCP %s allow rule using %s.\n' "$OR_PORT" "$FIREWALL_KIND"
  fi
  printf '  - Enable and restart %s.\n' "$TOR_SERVICE"
}

confirm_apply() {
  printf '\n'
  if ! ask_yes_no "Apply these changes now?" "no"; then
    die "Aborted before making changes."
  fi

  prompt_printf '%bType NON-EXIT to confirm this must remain a non-exit relay%b: ' "$BOLD" "$RESET"
  local confirmation
  read_reply confirmation
  if [[ "$confirmation" != "NON-EXIT" ]]; then
    die "Confirmation did not match NON-EXIT. Aborted."
  fi
}

install_repository_prerequisites() {
  run "Updating apt package lists" env DEBIAN_FRONTEND=noninteractive apt-get update
  run "Installing apt repository prerequisites" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates gnupg wget
}

configure_tor_repository() {
  local source_file="$TMP_DIR/tor.sources"
  local ascii_key="$TMP_DIR/torproject.asc"
  local binary_key="$TMP_DIR/deb.torproject.org-keyring.gpg"

  build_tor_sources "$source_file"

  if ((DRY_RUN)); then
    info "Would fetch and install the Tor Project package signing key"
    print_command wget -qO- "https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
    print_command gpg --dearmor --output "$TOR_KEYRING_PATH"
  else
    wget -qO "$ascii_key" "https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
    gpg --dearmor --yes --output "$binary_key" "$ascii_key"
  fi

  install_file_if_changed "$binary_key" "$TOR_KEYRING_PATH" "0644"
  install_file_if_changed "$source_file" "$TOR_SOURCES_PATH" "0644"

  if [[ -e /etc/apt/sources.list.d/tor.list ]]; then
    warn "Existing /etc/apt/sources.list.d/tor.list was found. Review it later to avoid duplicate Tor repositories."
  fi
}

install_tor_package() {
  run "Updating apt package lists" env DEBIAN_FRONTEND=noninteractive apt-get update
  run "Installing Tor from the Tor Project repository" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y tor deb.torproject.org-keyring
}

configure_unattended_upgrades() {
  local unattended_file="$TMP_DIR/52tor-relay-unattended-upgrades"
  local auto_file="$TMP_DIR/20auto-upgrades"

  build_unattended_tor_config "$unattended_file"
  build_auto_upgrades_config "$auto_file"

  run "Installing unattended-upgrades packages" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges

  install_file_if_changed "$unattended_file" "$UNATTENDED_TOR_PATH" "0644"
  install_file_if_changed "$auto_file" "$AUTO_UPGRADES_PATH" "0644"
}

configure_torrc() {
  local torrc_file="$TMP_DIR/torrc"
  build_torrc "$torrc_file"
  install_file_if_changed "$torrc_file" "$TORRC_PATH" "0644"
}

configure_hostname() {
  local hosts_file="$TMP_DIR/hosts"

  ((CHANGE_HOSTNAME)) || return 0

  build_hosts_file "$hosts_file"
  backup_file /etc/hostname
  run "Setting system hostname to ${NEW_HOSTNAME}" hostnamectl set-hostname "$NEW_HOSTNAME"
  install_file_if_changed "$hosts_file" /etc/hosts "0644"
  success "System hostname configured. New SSH sessions should show ${NEW_HOSTNAME}."
}

nft_rule_exists() {
  nft list chain inet filter input 2>/dev/null | grep -Fq "Tor relay ORPort ${OR_PORT}"
}

configure_firewall() {
  ((ENABLE_FIREWALL)) || return 0

  case "$FIREWALL_KIND" in
    ufw)
      run "Allowing TCP ${OR_PORT} through UFW" ufw allow "${OR_PORT}/tcp" comment "Tor relay ORPort"
      if [[ "$FIREWALL_STATE" == "inactive" ]]; then
        warn "UFW is inactive. The rule was added, but UFW was not enabled."
      fi
      ;;
    firewalld)
      if [[ "$FIREWALL_STATE" != "active" ]]; then
        warn "firewalld is inactive. Skipping firewall change."
        return 0
      fi
      run "Allowing TCP ${OR_PORT} through firewalld" firewall-cmd --permanent --add-port="${OR_PORT}/tcp"
      run "Reloading firewalld" firewall-cmd --reload
      ;;
    nftables)
      if ! nft list chain inet filter input >/dev/null 2>&1; then
        warn "nftables chain inet filter input is not available. Skipping firewall change."
        return 0
      fi
      if ((DRY_RUN)); then
        info "Would add nftables allow rule for TCP ${OR_PORT}"
        print_command nft add rule inet filter input tcp dport "$OR_PORT" accept comment "Tor relay ORPort ${OR_PORT}"
      elif nft_rule_exists; then
        success "nftables rule already present for TCP ${OR_PORT}"
      else
        run "Allowing TCP ${OR_PORT} through nftables" \
          nft add rule inet filter input tcp dport "$OR_PORT" accept comment "Tor relay ORPort ${OR_PORT}"
      fi
      ;;
    *)
      warn "No supported firewall manager selected. Skipping firewall change."
      ;;
  esac
}

verify_tor_config() {
  if command_exists tor; then
    run "Verifying Tor configuration syntax" tor --verify-config -f "$TORRC_PATH"
  else
    warn "tor command not found yet; cannot verify torrc syntax."
  fi
}

check_tor_orport_self_test() {
  local deadline
  local log_output
  local since_time

  since_time=${1:-"5 minutes ago"}

  command_exists journalctl || {
    warn "journalctl not found; skipped Tor ORPort self-test log check."
    return 0
  }

  info "Checking Tor ORPort reachability self-test logs for up to 90 seconds."
  deadline=$((SECONDS + 90))

  while ((SECONDS < deadline)); do
    log_output=$(journalctl -u "$TOR_SERVICE" --since "$since_time" --no-pager 2>/dev/null || true)

    if grep -Fq "Self-testing indicates your ORPort is reachable from the outside. Excellent." <<< "$log_output"; then
      success "Tor reports the ORPort is reachable from outside."
      return 0
    fi

    if grep -Fq "Your server has not managed to confirm that its ORPort is reachable" <<< "$log_output"; then
      warn "Tor has not confirmed external ORPort reachability yet."
      warn "Check local/cloud firewall rules for TCP ${OR_PORT}, then watch: journalctl -u ${TOR_SERVICE} -f"
      return 0
    fi

    sleep 5
  done

  warn "Tor did not report ORPort self-test success within 90 seconds."
  warn "This can take longer. Watch logs with: journalctl -u ${TOR_SERVICE} -f"
}

restart_and_verify_tor() {
  local restart_since

  verify_tor_config

  restart_since=$(date '+%Y-%m-%d %H:%M:%S')
  run "Enabling ${TOR_SERVICE}" systemctl enable "$TOR_SERVICE"
  run "Restarting ${TOR_SERVICE}" systemctl restart "$TOR_SERVICE"

  if ((DRY_RUN)); then
    info "Would verify ${TOR_SERVICE} status, ORPort listener, and Tor ORPort self-test logs."
    return 0
  fi

  if systemctl is-active --quiet "$TOR_SERVICE"; then
    success "${TOR_SERVICE} is active."
  else
    die "${TOR_SERVICE} is not active. Check: journalctl -u ${TOR_SERVICE} -n 100 --no-pager"
  fi

  if command_exists ss; then
    if ss -H -ltn | awk '{ print $4 }' | grep -Eq "(^|:|\\])${OR_PORT}$"; then
      success "Tor appears to be listening on TCP ${OR_PORT}."
    else
      warn "Could not confirm a listener on TCP ${OR_PORT}. Check firewall/NAT and Tor logs."
    fi
  else
    warn "ss command not found; skipped listener verification."
  fi

  check_tor_orport_self_test "$restart_since"
}

apply_changes() {
  section "Applying Changes"
  TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')

  configure_hostname
  check_apt_capacity
  install_repository_prerequisites
  configure_tor_repository
  install_tor_package

  if ((ENABLE_AUTO_UPDATES)); then
    configure_unattended_upgrades
  fi

  configure_torrc
  configure_firewall
  restart_and_verify_tor
}

print_next_steps() {
  section "Next Steps"

  if ((DRY_RUN)); then
    printf '%s\n' "Dry run complete. Re-run without --dry-run to apply these changes:"
    printf '  sudo ./%s\n' "$SCRIPT_NAME"
    return 0
  fi

  success "Relay setup commands completed."
  printf '\n%s\n' "Useful checks:"
  printf '  systemctl status %s --no-pager\n' "$TOR_SERVICE"
  printf '  journalctl -u %s -f\n' "$TOR_SERVICE"
  printf '  journalctl -u %s --since "1 hour ago" | grep -F "Self-testing indicates"\n' "$TOR_SERVICE"
  printf '  ss -ltn | grep ":%s"\n' "$OR_PORT"
  printf '\n%s\n' "Relay Search usually shows a new relay after about 3 hours:"
  printf '  https://metrics.torproject.org/rs.html#search/%s\n' "$RELAY_NICKNAME"
  printf '\n%s\n' "Remember:"
  printf '  - Keep inbound TCP %s open in any VPS provider/cloud firewall.\n' "$OR_PORT"
  printf '  - New relays ramp up gradually; Guard usage can take time and stable uptime.\n'
  printf '  - If you run multiple relays, configure MyFamily manually after you know their fingerprints.\n'
  printf '  - Consider backing up /var/lib/tor/keys after the relay is running.\n'

  if ((${#BACKUPS_CREATED[@]})); then
    printf '\n%s\n' "Backups created:"
    local backup
    for backup in "${BACKUPS_CREATED[@]}"; do
      printf '  %s\n' "$backup"
    done
  fi
}

main() {
  parse_args "$@"
  TMP_DIR=$(mktemp -d)

  banner
  require_supported_system
  collect_system_hostname
  collect_relay_identity
  collect_ipv6
  collect_bandwidth
  collect_maintenance_options
  show_summary
  confirm_apply
  apply_changes
  print_next_steps
}

main "$@"

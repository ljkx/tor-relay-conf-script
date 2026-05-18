#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
case "$SCRIPT_NAME" in
  bash|sh|dash|bash.exe|sh.exe|dash.exe)
    SCRIPT_NAME="setup-tor-guard-relay.sh"
    ;;
esac
VERSION="1.2.2"
DRY_RUN=0

TMP_DIR=""
TIMESTAMP=""
BACKUPS_CREATED=()
STEP_NUMBER=0
CURRENT_STEP_LABEL=""

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
RELAY_MODE="guard"
EXIT_POLICY_MODE="reduced"
EXIT_ALLOW_IPV6=0
CONFIGURE_UNBOUND=0
LOCK_RESOLV_CONF=0
CONFIGURE_RELAY_BANDWIDTH=0
RELAY_BANDWIDTH_RATE_VALUE=""
RELAY_BANDWIDTH_RATE_UNIT="MBits"
RELAY_BANDWIDTH_BURST_VALUE=""
RELAY_BANDWIDTH_BURST_UNIT="MBits"
CONFIGURE_ACCOUNTING=0
ACCOUNTING_MAX_GBYTES=""
ACCOUNTING_RULE="max"
BANDWIDTH_MODE="none"
MONTHLY_TRAFFIC_INPUT=""
MONTHLY_TRAFFIC_GBYTES=""
MONTHLY_TRAFFIC_USABLE_GBYTES=""
MONTHLY_TRAFFIC_HEADROOM_PERCENT=10
MONTHLY_TRAFFIC_BILLING_RULE="sum"
STEADY_PER_DIRECTION_GBYTES=""
ENABLE_AUTO_UPDATES=1
INSTALL_NYX=1
ENABLE_FIREWALL=0
FIREWALL_KIND="none"
FIREWALL_STATE="unavailable"
ENABLE_TOR_SANDBOX=1

TORRC_PATH="/etc/tor/torrc"
TOR_APT_BASE_URL="https://deb.torproject.org/torproject.org"
TOR_SOURCES_PATH="/etc/apt/sources.list.d/tor.sources"
TOR_KEYRING_PATH="/usr/share/keyrings/deb.torproject.org-keyring.gpg"
UNATTENDED_TOR_PATH="/etc/apt/apt.conf.d/52tor-relay-unattended-upgrades"
AUTO_UPGRADES_PATH="/etc/apt/apt.conf.d/20auto-upgrades"
TOR_SERVICE="tor@default"
RESOLV_CONF_PATH="/etc/resolv.conf"

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

Interactively configure a Tor relay on a fresh Debian or Ubuntu VPS.

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
  Debian and Ubuntu releases whose codenames are published by the
  official Tor Project apt repository.

This script can configure either a Guard/middle relay or an exit relay.
It shows the generated torrc and asks for confirmation before applying.
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
  printf '\n%bTor Relay Setup%b %s\n' "$BOLD$CYAN" "$RESET" "$VERSION"
  printf '%s\n' "Guided installer for public Guard/middle and exit relays."
  printf '%s\n\n' "It will show a summary before making privileged changes."
}

section() {
  STEP_NUMBER=$((STEP_NUMBER + 1))
  CURRENT_STEP_LABEL=$(printf '%02d' "$STEP_NUMBER")
  printf '\n%b[%s]%b %b+--%b %b%s%b\n' "$CYAN" "$CURRENT_STEP_LABEL" "$RESET" "$DIM" "$RESET" "$BOLD$BLUE" "$1" "$RESET"
}

step_prefix() {
  if [[ -n "${CURRENT_STEP_LABEL:-}" ]]; then
    printf '%b[%s]%b %b|%b ' "$CYAN" "$CURRENT_STEP_LABEL" "$RESET" "$DIM" "$RESET"
  fi
}

prompt_step_prefix() {
  if [[ -z "${CURRENT_STEP_LABEL:-}" ]]; then
    return 0
  fi

  if [[ -w /dev/tty ]]; then
    step_prefix > /dev/tty
  else
    step_prefix >&2
  fi
}

info() {
  step_prefix
  printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"
}

success() {
  step_prefix
  printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  step_prefix >&2
  printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  step_prefix >&2
  printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

apt_package_available() {
  local package=$1
  local candidate

  command_exists apt-cache || return 1
  candidate=$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

tor_project_suite_url() {
  printf '%s/dists/%s/Release' "$TOR_APT_BASE_URL" "$OS_CODENAME"
}

check_tor_project_suite() {
  local mode=${1:-required}
  local url
  local status

  url=$(tor_project_suite_url)

  if ((DRY_RUN)); then
    info "Would verify official Tor Project apt suite: ${url}"
    return 0
  fi

  if command_exists curl; then
    status=$(curl -L -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || true)
    status=${status:-000}
    case "$status" in
      200)
        success "Official Tor Project apt suite found for '${OS_CODENAME}'."
        return 0
        ;;
      404)
        die "The official Tor Project apt repository does not publish suite '${OS_CODENAME}' yet. Check ${TOR_APT_BASE_URL}/dists/ or use a supported Debian/Ubuntu release."
        ;;
      000)
        if [[ "$mode" == "optional" ]]; then
          warn "Could not verify the Tor Project apt suite yet; will retry before adding the Tor repository."
          return 0
        fi
        die "Could not reach ${url}. Check DNS/network connectivity and retry."
        ;;
      *)
        if [[ "$mode" == "optional" ]]; then
          warn "Tor Project apt suite check returned HTTP ${status}; will retry before adding the Tor repository."
          return 0
        fi
        die "Tor Project apt suite check returned unexpected HTTP ${status} for ${url}."
        ;;
    esac
  fi

  if command_exists wget; then
    if wget -q --spider "$url"; then
      success "Official Tor Project apt suite found for '${OS_CODENAME}'."
      return 0
    fi

    if [[ "$mode" == "optional" ]]; then
      warn "Could not verify the Tor Project apt suite yet; will retry before adding the Tor repository."
      return 0
    fi
    die "Could not verify ${url}. Check whether the Tor Project apt repository publishes suite '${OS_CODENAME}'."
  fi

  if [[ "$mode" == "optional" ]]; then
    warn "curl/wget is not available yet, so Tor Project apt suite verification is deferred."
    return 0
  fi

  die "curl or wget is required to verify the Tor Project apt repository suite."
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

sanitize_reply() {
  local value=$1

  value=${value//$'\e[200~'/}
  value=${value//$'\e[201~'/}
  value=${value//$'\r'/}
  value=${value//$'\e'/}
  printf '%s' "$value"
}

prompt_line() {
  local prompt=$1
  local default_value=${2:-}
  local reply

  prompt_step_prefix
  if [[ -n "$default_value" ]]; then
    prompt_printf '%b%s%b [%s]: ' "$BOLD" "$prompt" "$RESET" "$default_value"
  else
    prompt_printf '%b%s%b: ' "$BOLD" "$prompt" "$RESET"
  fi

  read_reply reply
  reply=$(sanitize_reply "$reply")
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
    prompt_step_prefix
    prompt_printf '%b%s%b %s: ' "$BOLD" "$prompt" "$RESET" "$suffix"
    read_reply reply
    reply=$(sanitize_reply "$reply")
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

valid_percent() {
  local value=$1
  valid_integer "$value" || return 1
  ((10#$value >= 0 && 10#$value <= 50))
}

parse_traffic_to_gbytes() {
  local raw=$1
  local compact
  local number
  local unit

  compact=$(trim "$raw")
  compact=${compact//[[:space:]]/}
  compact=${compact^^}

  [[ "$compact" =~ ^([0-9]+([.][0-9]+)?)(K|KB|KIB|KBYTE|KBYTES|M|MB|MIB|MBYTE|MBYTES|G|GB|GIB|GBYTE|GBYTES|T|TB|TIB|TBYTE|TBYTES)$ ]] || return 1
  number=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[3]}

  awk -v number="$number" -v unit="$unit" '
    BEGIN {
      multiplier = 0
      if (unit ~ /^K/) multiplier = 1 / (1024 * 1024)
      else if (unit ~ /^M/) multiplier = 1 / 1024
      else if (unit ~ /^G/) multiplier = 1
      else if (unit ~ /^T/) multiplier = 1024
      value = number * multiplier
      if (value < 1) exit 1
      printf "%d", value
    }'
}

format_mbits_from_kbytes() {
  local kbytes=$1
  local tenths
  tenths=$((10#$kbytes * 8192 / 100000))
  printf '%d.%d' "$((tenths / 10))" "$((tenths % 10))"
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

  case "$OS_ID" in
    debian|ubuntu) ;;
    *)
      die "Unsupported OS: ${OS_PRETTY_NAME}. This installer currently supports Debian and Ubuntu releases with a Tor Project apt repository suite."
      ;;
  esac

  [[ -n "$OS_CODENAME" ]] || die "Could not detect the Debian/Ubuntu codename for ${OS_PRETTY_NAME}."

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

  success "Accepted target: ${OS_PRETTY_NAME} (${OS_CODENAME}, ${ARCHITECTURE})"
  check_tor_project_suite optional

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

collect_relay_mode() {
  section "Relay Mode"
  info "Guard/middle relays forward traffic inside the Tor network."
  info "Exit relays also connect Tor traffic to destinations on the public Internet, according to an exit policy."

  if ask_yes_no "Configure this relay as an exit relay?" "no"; then
    RELAY_MODE="exit"
  else
    RELAY_MODE="guard"
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

check_ipv6_connectivity() {
  local authorities=(
    "2001:858:2:2:aabb:0:563b:1526"
    "2620:13:4000:6000::1000:118"
    "2001:67c:289c::9"
    "2001:678:558:1000::244"
    "2001:638:a000:4140::ffff:189"
  )
  local ping_cmd=()
  local address
  local failed=0

  if command_exists ping6; then
    ping_cmd=(ping6 -c 2)
  elif command_exists ping; then
    ping_cmd=(ping -6 -c 2)
  else
    warn "Neither ping6 nor ping is available; cannot run the Tor-documented IPv6 ping check."
    return 2
  fi

  printf '%s\n' "Tor-documented check: ping each Tor directory authority IPv6 address from this server."
  for address in "${authorities[@]}"; do
    if "${ping_cmd[@]}" "$address" >/dev/null 2>&1; then
      success "IPv6 ping succeeded: ${address}"
    else
      warn "IPv6 ping failed: ${address}"
      failed=1
    fi
  done

  return "$failed"
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
    if check_ipv6_connectivity; then
      success "Outbound IPv6 connectivity check passed."
    else
      warn "Outbound IPv6 connectivity check failed or could not complete."
      warn "This test is ICMPv6/ping-based. It can fail even when inbound IPv6 ORPort reachability looks fine."
      warn "Tor still warns that enabling IPv6 without working IPv6 connectivity can leave the relay unused."
      if ask_yes_no "Keep IPv6 ORPort anyway because you verified IPv6 manually?" "no"; then
        warn "Keeping IPv6 ORPort enabled by explicit operator override."
      else
        ENABLE_IPV6=0
        IPV6_ADDRESS=""
      fi
    fi
  else
    warn "Skipped outbound IPv6 connectivity check. Only keep IPv6 enabled if you know it works."
  fi
}

collect_exit_options() {
  [[ "$RELAY_MODE" == "exit" ]] || return 0

  section "Exit Relay Options"
  info "Exit relay setup follows Tor's exit relay guidance: choose an exit policy and provide reliable local DNS resolution."
  info "A dedicated server, provider permission, clear abuse contact handling, and useful reverse DNS/WHOIS notes are recommended for exit operators."

  if ! ask_yes_no "Have you confirmed this provider allows Tor exit traffic and that abuse handling is planned?" "no"; then
    if ! ask_yes_no "Continue configuring exit mode anyway?" "no"; then
      die "Exit relay setup aborted. Re-run and choose Guard/middle mode if that is what you want."
    fi
  fi

  if ask_yes_no "Use Tor's ReducedExitPolicy for a first exit relay?" "yes"; then
    EXIT_POLICY_MODE="reduced"
  else
    EXIT_POLICY_MODE="default"
    warn "Tor's default exit policy is broader than ReducedExitPolicy. Make sure it matches your provider and operations plan."
  fi

  if ((ENABLE_IPV6)); then
    if ask_yes_no "Allow IPv6 exit traffic with IPv6Exit 1?" "yes"; then
      EXIT_ALLOW_IPV6=1
    else
      EXIT_ALLOW_IPV6=0
    fi
  else
    EXIT_ALLOW_IPV6=0
  fi

  info "Exit relays perform DNS resolution for Tor clients."
  info "Tor recommends a local caching, DNSSEC-validating resolver such as Unbound, without public DNS forwarders."
  if ask_yes_no "Install Unbound and use it as the local resolver for exit DNS?" "yes"; then
    CONFIGURE_UNBOUND=1
    if ask_yes_no "Lock /etc/resolv.conf with chattr +i after switching to Unbound?" "no"; then
      LOCK_RESOLV_CONF=1
    else
      LOCK_RESOLV_CONF=0
    fi
  else
    CONFIGURE_UNBOUND=0
    warn "You chose not to configure Unbound. Make sure DNS resolution is reliable and not using a large public resolver."
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

  if [[ -n "$available_kib" && "$available_kib" =~ ^[0-9]+$ ]]; then
    if ((available_kib < min_kib)); then
      die "Not enough free disk space for apt under ${path}. Need at least $((min_kib / 1024)) MiB free; found $((available_kib / 1024)) MiB. Run: df -h"
    fi
  else
    warn "Could not read free disk space for ${path}; continuing."
  fi

  if [[ -n "$available_inodes" && "$available_inodes" =~ ^[0-9]+$ ]]; then
    if ((available_inodes < min_inodes)); then
      die "Not enough free inodes for apt under ${path}. Need at least ${min_inodes}; found ${available_inodes}. Run: df -ih"
    fi
  else
    warn "Could not read free inodes for ${path}; continuing."
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

reset_bandwidth_config() {
  CONFIGURE_RELAY_BANDWIDTH=0
  RELAY_BANDWIDTH_RATE_VALUE=""
  RELAY_BANDWIDTH_RATE_UNIT="MBits"
  RELAY_BANDWIDTH_BURST_VALUE=""
  RELAY_BANDWIDTH_BURST_UNIT="MBits"
  CONFIGURE_ACCOUNTING=0
  ACCOUNTING_MAX_GBYTES=""
  ACCOUNTING_RULE="max"
  BANDWIDTH_MODE="none"
  MONTHLY_TRAFFIC_INPUT=""
  MONTHLY_TRAFFIC_GBYTES=""
  MONTHLY_TRAFFIC_USABLE_GBYTES=""
  MONTHLY_TRAFFIC_HEADROOM_PERCENT=10
  MONTHLY_TRAFFIC_BILLING_RULE="sum"
  STEADY_PER_DIRECTION_GBYTES=""
}

collect_traffic_budget() {
  local prompt=${1:-"Maximum monthly traffic budget"}
  local parsed

  while true; do
    MONTHLY_TRAFFIC_INPUT=$(prompt_line "$prompt (examples: 10TB, 5000GB)")
    if parsed=$(parse_traffic_to_gbytes "$MONTHLY_TRAFFIC_INPUT"); then
      MONTHLY_TRAFFIC_GBYTES=$parsed
      break
    fi
    warn "Enter a traffic amount with units, for example 10TB, 2.5TB, or 5000GB."
  done
}

collect_traffic_headroom() {
  while true; do
    MONTHLY_TRAFFIC_HEADROOM_PERCENT=$(prompt_line "Safety headroom percentage for provider overhead" "10")
    if valid_percent "$MONTHLY_TRAFFIC_HEADROOM_PERCENT"; then
      break
    fi
    warn "Enter a whole percentage from 0 to 50."
  done

  MONTHLY_TRAFFIC_USABLE_GBYTES=$((10#$MONTHLY_TRAFFIC_GBYTES * (100 - 10#$MONTHLY_TRAFFIC_HEADROOM_PERCENT) / 100))
  if ((MONTHLY_TRAFFIC_USABLE_GBYTES < 1)); then
    die "The usable traffic budget is below 1 GByte after headroom."
  fi
}

collect_traffic_billing_rule() {
  info "Provider traffic quotas are counted differently. Choose the closest match."
  step_prefix
  printf '%s\n' "  1) Combined inbound + outbound traffic (conservative default)"
  step_prefix
  printf '%s\n' "  2) Outbound traffic only"
  step_prefix
  printf '%s\n' "  3) Per-direction / Tor default max(in,out)"

  while true; do
    local choice
    choice=$(prompt_line "Traffic quota style" "1")
    case "${choice,,}" in
      1|sum|combined|total|in+out)
        MONTHLY_TRAFFIC_BILLING_RULE="sum"
        ACCOUNTING_RULE="sum"
        return 0
        ;;
      2|out|outbound|egress)
        MONTHLY_TRAFFIC_BILLING_RULE="out"
        ACCOUNTING_RULE="out"
        return 0
        ;;
      3|max|direction|per-direction|perdirection)
        MONTHLY_TRAFFIC_BILLING_RULE="max"
        ACCOUNTING_RULE="max"
        return 0
        ;;
      *)
        warn "Choose 1, 2, or 3."
        ;;
    esac
  done
}

calculate_steady_monthly_limits() {
  local per_direction_gbytes
  local rate_kbytes
  local burst_kbytes

  case "$MONTHLY_TRAFFIC_BILLING_RULE" in
    sum)
      per_direction_gbytes=$((10#$MONTHLY_TRAFFIC_USABLE_GBYTES / 2))
      ;;
    out|max)
      per_direction_gbytes=$((10#$MONTHLY_TRAFFIC_USABLE_GBYTES))
      ;;
    *)
      die "Unknown traffic billing rule: ${MONTHLY_TRAFFIC_BILLING_RULE}"
      ;;
  esac

  if ((per_direction_gbytes < 1)); then
    die "The monthly budget is too small after headroom and accounting style."
  fi

  rate_kbytes=$((per_direction_gbytes * 1024 * 1024 / 2592000))
  if ((rate_kbytes < 75)); then
    warn "That budget calculates to ${rate_kbytes} KBytes/s, below Tor's relay minimum of 75 KBytes/s."
    return 1
  fi

  burst_kbytes=$((rate_kbytes * 5))

  CONFIGURE_RELAY_BANDWIDTH=1
  RELAY_BANDWIDTH_RATE_VALUE=$rate_kbytes
  RELAY_BANDWIDTH_RATE_UNIT="KBytes"
  RELAY_BANDWIDTH_BURST_VALUE=$burst_kbytes
  RELAY_BANDWIDTH_BURST_UNIT="KBytes"
  CONFIGURE_ACCOUNTING=1
  ACCOUNTING_MAX_GBYTES=$MONTHLY_TRAFFIC_USABLE_GBYTES
  STEADY_PER_DIRECTION_GBYTES=$per_direction_gbytes
}

collect_steady_monthly_bandwidth() {
  BANDWIDTH_MODE="steady"

  while true; do
    collect_traffic_budget "Maximum monthly traffic allowed by your provider"
    collect_traffic_headroom
    collect_traffic_billing_rule
    if calculate_steady_monthly_limits; then
      break
    fi
    if ! ask_yes_no "Enter a larger monthly budget?" "yes"; then
      die "Monthly budget is too small for a steady public Tor relay."
    fi
  done

  success "Calculated steady rate: ${RELAY_BANDWIDTH_RATE_VALUE} ${RELAY_BANDWIDTH_RATE_UNIT}/s (~$(format_mbits_from_kbytes "$RELAY_BANDWIDTH_RATE_VALUE") Mbit/s)."
  success "Calculated burst: ${RELAY_BANDWIDTH_BURST_VALUE} ${RELAY_BANDWIDTH_BURST_UNIT}/s."
  info "AccountingMax is kept as a safety fuse at ${ACCOUNTING_MAX_GBYTES} GBytes with AccountingRule ${ACCOUNTING_RULE}."
}

collect_manual_relay_bandwidth() {
  local default_burst

  BANDWIDTH_MODE="manual"
  CONFIGURE_RELAY_BANDWIDTH=1
  RELAY_BANDWIDTH_RATE_UNIT="MBits"
  RELAY_BANDWIDTH_BURST_UNIT="MBits"

  while true; do
    RELAY_BANDWIDTH_RATE_VALUE=$(prompt_line "Average relay bandwidth in Mbit/s" "16")
    if valid_integer "$RELAY_BANDWIDTH_RATE_VALUE" && ((10#$RELAY_BANDWIDTH_RATE_VALUE >= 1)); then
      break
    fi
    warn "Enter a positive whole number."
  done

  if ((10#$RELAY_BANDWIDTH_RATE_VALUE < 10)); then
    warn "Tor relay requirements say 10 Mbit/s is the practical minimum; 16 Mbit/s or more is recommended."
    if ! ask_yes_no "Continue with ${RELAY_BANDWIDTH_RATE_VALUE} Mbit/s anyway?" "no"; then
      reset_bandwidth_config
      collect_bandwidth
      return 0
    fi
  elif ((10#$RELAY_BANDWIDTH_RATE_VALUE < 16)); then
    warn "16 Mbit/s or more is recommended when available."
  fi

  default_burst=$((10#$RELAY_BANDWIDTH_RATE_VALUE * 2))
  while true; do
    RELAY_BANDWIDTH_BURST_VALUE=$(prompt_line "Burst bandwidth in Mbit/s" "$default_burst")
    if valid_integer "$RELAY_BANDWIDTH_BURST_VALUE" && ((10#$RELAY_BANDWIDTH_BURST_VALUE >= 10#$RELAY_BANDWIDTH_RATE_VALUE)); then
      break
    fi
    warn "Enter a whole number greater than or equal to the average rate."
  done
}

collect_hard_accounting_cap() {
  BANDWIDTH_MODE="accounting"
  CONFIGURE_ACCOUNTING=1

  collect_traffic_budget "Monthly AccountingMax traffic cap"
  collect_traffic_headroom
  collect_traffic_billing_rule
  ACCOUNTING_MAX_GBYTES=$MONTHLY_TRAFFIC_USABLE_GBYTES

  warn "AccountingMax is a hard cap. Tor may hibernate after the cap is reached."
}

collect_bandwidth() {
  section "Bandwidth and Traffic"
  reset_bandwidth_config

  info "Tor AccountingMax is a hard quota and can hibernate the relay when exhausted."
  info "Steady monthly mode calculates RelayBandwidthRate and RelayBandwidthBurst from your VPS traffic budget."
  step_prefix
  printf '%s\n' "  1) Steady monthly budget (recommended if your VPS has a traffic cap)"
  step_prefix
  printf '%s\n' "  2) Manual RelayBandwidthRate / RelayBandwidthBurst"
  step_prefix
  printf '%s\n' "  3) Hard monthly AccountingMax only"
  step_prefix
  printf '%s\n' "  4) No relay-specific bandwidth cap"

  while true; do
    local choice
    choice=$(prompt_line "Bandwidth mode" "1")
    case "${choice,,}" in
      1|steady|budget|monthly)
        collect_steady_monthly_bandwidth
        return 0
        ;;
      2|manual|rate)
        collect_manual_relay_bandwidth
        return 0
        ;;
      3|accounting|cap|hard)
        collect_hard_accounting_cap
        return 0
        ;;
      4|none|no)
        BANDWIDTH_MODE="none"
        info "No relay-specific bandwidth cap will be written."
        return 0
        ;;
      *)
        warn "Choose 1, 2, 3, or 4."
        ;;
    esac
  done
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

  info "Nyx is the Tor terminal monitor. It is handy for relay operators, but not required."
  if ask_yes_no "Install Nyx for terminal relay monitoring?" "yes"; then
    INSTALL_NYX=1
  else
    INSTALL_NYX=0
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
    printf '# Tor relay configuration.\n'
    printf '# Review Tor Project relay documentation before making manual changes.\n'
    printf '\n'
    printf 'Nickname %s\n' "$RELAY_NICKNAME"
    printf 'ContactInfo %s\n' "$(torrc_quote "$CONTACT_INFO")"
    printf 'ORPort %s\n' "$OR_PORT"
    if ((ENABLE_IPV6)); then
      printf 'ORPort [%s]:%s\n' "$IPV6_ADDRESS" "$OR_PORT"
    fi
    printf '\n'
    printf '# Disable local SOCKS listener on this relay-only server.\n'
    printf 'SocksPort 0\n'
    printf '\n'
    if [[ "$RELAY_MODE" == "exit" ]]; then
      printf '# Exit relay mode.\n'
      printf 'ExitRelay 1\n'
      if [[ "$EXIT_POLICY_MODE" == "reduced" ]]; then
        printf 'ReducedExitPolicy 1\n'
      fi
      if ((EXIT_ALLOW_IPV6)); then
        printf 'IPv6Exit 1\n'
      fi
    else
      printf '# Guard / middle relay mode.\n'
      printf 'ExitRelay 0\n'
    fi
    printf '\n'
    printf '# Keep potentially sensitive log details scrubbed.\n'
    printf 'SafeLogging 1\n'
    if ((ENABLE_TOR_SANDBOX)); then
      printf 'Sandbox 1\n'
    fi
    if ((CONFIGURE_RELAY_BANDWIDTH)); then
      printf '\n'
      printf '# Relay-specific bandwidth limits. Tor applies these per second.\n'
      printf 'RelayBandwidthRate %s %s\n' "$RELAY_BANDWIDTH_RATE_VALUE" "$RELAY_BANDWIDTH_RATE_UNIT"
      printf 'RelayBandwidthBurst %s %s\n' "$RELAY_BANDWIDTH_BURST_VALUE" "$RELAY_BANDWIDTH_BURST_UNIT"
    fi
    if ((CONFIGURE_ACCOUNTING)); then
      printf '\n'
      printf '# Monthly accounting safety cap. Tor hibernates if this is exhausted.\n'
      printf 'AccountingStart month 1 00:00\n'
      if [[ "$ACCOUNTING_RULE" != "max" ]]; then
        printf 'AccountingRule %s\n' "$ACCOUNTING_RULE"
      fi
      printf 'AccountingMax %s GBytes\n' "$ACCOUNTING_MAX_GBYTES"
    fi
  } > "$output"
}

build_tor_sources() {
  local output=$1
  {
    printf 'Types: deb deb-src\n'
    printf 'URIs: %s/\n' "$TOR_APT_BASE_URL"
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

build_resolv_conf() {
  local output=$1
  {
    printf '# Managed by %s for Tor exit relay DNS.\n' "$SCRIPT_NAME"
    printf 'nameserver 127.0.0.1\n'
  } > "$output"
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
  if [[ "$RELAY_MODE" == "exit" ]]; then
    printf '%bRelay mode%b: Exit\n' "$BOLD" "$RESET"
    printf '%bExit policy%b: %s\n' "$BOLD" "$RESET" "$EXIT_POLICY_MODE"
    printf '%bIPv6 exit traffic%b: %s\n' "$BOLD" "$RESET" "$([[ $EXIT_ALLOW_IPV6 -eq 1 ]] && printf yes || printf no)"
    printf '%bLocal Unbound resolver%b: %s\n' "$BOLD" "$RESET" "$([[ $CONFIGURE_UNBOUND -eq 1 ]] && printf yes || printf no)"
    if ((CONFIGURE_UNBOUND)); then
      printf '%bLock %s%b: %s\n' "$BOLD" "$RESOLV_CONF_PATH" "$RESET" "$([[ $LOCK_RESOLV_CONF -eq 1 ]] && printf yes || printf no)"
    fi
  else
    printf '%bRelay mode%b: Guard / middle\n' "$BOLD" "$RESET"
  fi
  printf '%bRelay%b: %s on ORPort %s\n' "$BOLD" "$RESET" "$RELAY_NICKNAME" "$OR_PORT"
  printf '%bContactInfo%b: %s\n' "$BOLD" "$RESET" "$CONTACT_INFO"
  if ((ENABLE_IPV6)); then
    printf '%bIPv6 ORPort%b: [%s]:%s\n' "$BOLD" "$RESET" "$IPV6_ADDRESS" "$OR_PORT"
  else
    printf '%bIPv6 ORPort%b: disabled\n' "$BOLD" "$RESET"
  fi
  if ((CONFIGURE_RELAY_BANDWIDTH)); then
    printf '%bBandwidth%b: %s %s/s average, %s %s/s burst\n' "$BOLD" "$RESET" "$RELAY_BANDWIDTH_RATE_VALUE" "$RELAY_BANDWIDTH_RATE_UNIT" "$RELAY_BANDWIDTH_BURST_VALUE" "$RELAY_BANDWIDTH_BURST_UNIT"
    if [[ "$BANDWIDTH_MODE" == "steady" ]]; then
      printf '%bEstimated average%b: ~%s Mbit/s, based on %s usable GBytes/month per relay direction\n' "$BOLD" "$RESET" "$(format_mbits_from_kbytes "$RELAY_BANDWIDTH_RATE_VALUE")" "$STEADY_PER_DIRECTION_GBYTES"
    fi
  else
    printf '%bBandwidth%b: no relay-specific cap\n' "$BOLD" "$RESET"
  fi
  if ((CONFIGURE_ACCOUNTING)); then
    printf '%bAccountingMax%b: %s GBytes, monthly reset, AccountingRule %s\n' "$BOLD" "$RESET" "$ACCOUNTING_MAX_GBYTES" "$ACCOUNTING_RULE"
    if [[ "$BANDWIDTH_MODE" == "steady" || "$BANDWIDTH_MODE" == "accounting" ]]; then
      printf '%bTraffic budget%b: %s raw, %s%% headroom\n' "$BOLD" "$RESET" "$MONTHLY_TRAFFIC_INPUT" "$MONTHLY_TRAFFIC_HEADROOM_PERCENT"
    fi
  else
    printf '%bAccountingMax%b: not configured\n' "$BOLD" "$RESET"
  fi
  printf '%bAutomatic updates%b: %s\n' "$BOLD" "$RESET" "$([[ $ENABLE_AUTO_UPDATES -eq 1 ]] && printf yes || printf no)"
  printf '%bInstall Nyx%b: %s\n' "$BOLD" "$RESET" "$([[ $INSTALL_NYX -eq 1 ]] && printf yes || printf no)"
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
  printf '  - Install tor from apt.\n'
  printf '  - Install deb.torproject.org-keyring if apt publishes it for %s.\n' "$OS_CODENAME"
  if ((INSTALL_NYX)); then
    printf '  - Install nyx for terminal relay monitoring.\n'
  fi
  if [[ "$RELAY_MODE" == "exit" && "$CONFIGURE_UNBOUND" -eq 1 ]]; then
    printf '  - Install Unbound and switch %s to the local resolver.\n' "$RESOLV_CONF_PATH"
    if ((LOCK_RESOLV_CONF)); then
      printf '  - Lock %s with chattr +i.\n' "$RESOLV_CONF_PATH"
    fi
  fi
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

  check_tor_project_suite required
  build_tor_sources "$source_file"

  if ((DRY_RUN)); then
    info "Would fetch and install the Tor Project package signing key"
    print_command wget -qO- "${TOR_APT_BASE_URL}/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
    print_command gpg --dearmor --output "$TOR_KEYRING_PATH"
  else
    wget -qO "$ascii_key" "${TOR_APT_BASE_URL}/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
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

  if ! apt_package_available tor; then
    die "The tor package is not available from apt after adding the Tor Project repository."
  fi

  run "Installing Tor from apt" env DEBIAN_FRONTEND=noninteractive apt-get install -y tor

  if apt_package_available deb.torproject.org-keyring; then
    run "Installing Tor Project keyring package" \
      env DEBIAN_FRONTEND=noninteractive apt-get install -y deb.torproject.org-keyring
  else
    warn "deb.torproject.org-keyring is not available for '${OS_CODENAME}' yet."
    warn "Continuing because the Tor Project signing key was already installed at ${TOR_KEYRING_PATH}."
  fi
}

install_nyx_package() {
  ((INSTALL_NYX)) || return 0

  run "Installing Nyx relay monitor" env DEBIAN_FRONTEND=noninteractive apt-get install -y nyx
}

configure_exit_dns() {
  local resolv_file="$TMP_DIR/resolv.conf"
  local resolv_backup="${RESOLV_CONF_PATH}.bak.${TIMESTAMP}"

  [[ "$RELAY_MODE" == "exit" && "$CONFIGURE_UNBOUND" -eq 1 ]] || return 0

  build_resolv_conf "$resolv_file"

  run "Installing Unbound local resolver" env DEBIAN_FRONTEND=noninteractive apt-get install -y unbound
  run "Enabling and starting Unbound" systemctl enable --now unbound

  if ((DRY_RUN)); then
    info "Would verify Unbound service state and switch ${RESOLV_CONF_PATH} to nameserver 127.0.0.1"
    return 0
  fi

  if systemctl is-active --quiet unbound; then
    success "Unbound is active."
  else
    die "Unbound is not active. Check: journalctl -u unbound -n 100 --no-pager"
  fi

  backup_file "$RESOLV_CONF_PATH"
  if [[ -L "$RESOLV_CONF_PATH" ]]; then
    unlink "$RESOLV_CONF_PATH"
  fi
  install -m 0644 "$resolv_file" "$RESOLV_CONF_PATH"
  success "Configured ${RESOLV_CONF_PATH} to use local Unbound."

  if getent hosts deb.torproject.org >/dev/null 2>&1; then
    success "DNS resolution works through local resolver."
  else
    warn "DNS resolution failed after switching to local Unbound."
    if [[ -e "$resolv_backup" || -L "$resolv_backup" ]]; then
      rm -f -- "$RESOLV_CONF_PATH"
      cp -a -- "$resolv_backup" "$RESOLV_CONF_PATH"
      warn "Restored ${RESOLV_CONF_PATH} from ${resolv_backup}."
    fi
    die "Fix Unbound/DNS before running an exit relay."
  fi

  if ((LOCK_RESOLV_CONF)); then
    if command_exists chattr; then
      run "Locking ${RESOLV_CONF_PATH} with chattr +i" chattr +i "$RESOLV_CONF_PATH"
    else
      warn "chattr is not available; ${RESOLV_CONF_PATH} was not locked."
    fi
  fi
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

  check_apt_capacity
  configure_hostname
  install_repository_prerequisites
  configure_tor_repository
  install_tor_package
  install_nyx_package
  configure_exit_dns

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
  if ((INSTALL_NYX)); then
    printf '  sudo -u debian-tor nyx\n'
  fi
  if [[ "$RELAY_MODE" == "exit" && "$CONFIGURE_UNBOUND" -eq 1 ]]; then
    printf '  systemctl status unbound --no-pager\n'
    printf '  getent hosts deb.torproject.org\n'
  fi
  printf '\n%s\n' "Relay Search usually shows a new relay after about 3 hours:"
  printf '  https://metrics.torproject.org/rs.html#search/%s\n' "$RELAY_NICKNAME"
  printf '\n%s\n' "Remember:"
  printf '  - Keep inbound TCP %s open in any VPS provider/cloud firewall.\n' "$OR_PORT"
  printf '  - New relays ramp up gradually; Guard usage can take time and stable uptime.\n'
  printf '  - If you run multiple relays, configure MyFamily manually after you know their fingerprints.\n'
  printf '  - Consider backing up /var/lib/tor/keys after the relay is running.\n'
  if [[ "$RELAY_MODE" == "exit" ]]; then
    printf '  - Keep provider, reverse DNS/WHOIS, and abuse-contact handling aligned with exit operation.\n'
  fi

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
  collect_relay_mode
  collect_relay_identity
  collect_ipv6
  collect_exit_options
  collect_bandwidth
  collect_maintenance_options
  show_summary
  confirm_apply
  apply_changes
  print_next_steps
}

main "$@"

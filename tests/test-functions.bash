#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC2034

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

export TOR_RELAY_SETUP_SOURCE_ONLY=1
# shellcheck source=../setup-tor-guard-relay.sh
source "${ROOT_DIR}/setup-tor-guard-relay.sh"
trap - ERR INT TERM EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ "$actual" == "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local needle=$1
  local file=$2
  local label=$3
  grep -Fq -- "$needle" "$file" || fail "${label}: missing '${needle}'"
}

test_version() {
  assert_eq "1.0.0-beta.4" "$VERSION" "script version"
}

test_traffic_parser_and_steady_budget() {
  assert_eq "10240" "$(parse_traffic_to_gbytes 10TB)" "10TB parser"
  assert_eq "2560" "$(parse_traffic_to_gbytes 2.5TB)" "decimal TB parser"
  if parse_traffic_to_gbytes "10 bananas" >/dev/null 2>&1; then
    fail "invalid traffic unit was accepted"
  fi

  reset_bandwidth_config
  MONTHLY_TRAFFIC_GBYTES=10240
  MONTHLY_TRAFFIC_USABLE_GBYTES=9216
  MONTHLY_TRAFFIC_BILLING_RULE="sum"
  calculate_steady_monthly_limits

  assert_eq "1864" "$RELAY_BANDWIDTH_RATE_VALUE" "steady rate for 10TB sum"
  assert_eq "9320" "$RELAY_BANDWIDTH_BURST_VALUE" "steady burst for 10TB sum"
  assert_eq "9216" "$ACCOUNTING_MAX_GBYTES" "steady AccountingMax"
  assert_eq "4608" "$STEADY_PER_DIRECTION_GBYTES" "steady per-direction budget"

  reset_bandwidth_config
  MONTHLY_TRAFFIC_GBYTES=1024
  MONTHLY_TRAFFIC_USABLE_GBYTES=921
  MONTHLY_TRAFFIC_BILLING_RULE="sum"
  if calculate_steady_monthly_limits >/dev/null 2>&1; then
    fail "sub-10Mbit steady budget was accepted"
  fi
}

test_myfamily_helpers() {
  local -a family=()
  append_unique_fingerprint family "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  append_unique_fingerprint family '$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  append_unique_fingerprint family "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  assert_eq "2" "${#family[@]}" "duplicate MyFamily prevention"
  assert_eq '$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,$BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "$(format_myfamily_csv "${family[@]}")" "MyFamily CSV format"
}

test_ipv6_validation() {
  valid_ipv6_address "2001:db8::1" || fail "valid IPv6 address was rejected"
  if valid_ipv6_address "hello:world" >/dev/null 2>&1; then
    fail "invalid IPv6 address was accepted"
  fi
  if valid_ipv6_address "fe80::1" >/dev/null 2>&1; then
    fail "link-local IPv6 address was accepted"
  fi
}

test_torrc_generation() {
  local temp_file
  temp_file=$(mktemp)
  RELAY_NICKNAME="TestRelay"
  CONTACT_INFO="operator@example.org"
  OR_PORT="9001"
  ENABLE_IPV6=0
  RELAY_MODE="guard"
  ENABLE_TOR_SANDBOX=1
  reset_bandwidth_config

  build_torrc "$temp_file"
  assert_contains "Nickname TestRelay" "$temp_file" "torrc nickname"
  assert_contains 'ContactInfo "operator@example.org"' "$temp_file" "torrc ContactInfo"
  assert_contains "SocksPort 0" "$temp_file" "torrc SocksPort"
  assert_contains "ExitRelay 0" "$temp_file" "torrc non-exit"
  assert_contains "Sandbox 1" "$temp_file" "torrc Sandbox"
  rm -f -- "$temp_file"
}

test_ufw_inactive_detection() {
  local stub_dir old_path
  stub_dir=$(mktemp -d)
  old_path=$PATH
  cat > "${stub_dir}/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'Status: inactive\n'
EOF
  chmod +x "${stub_dir}/ufw"
  PATH="${stub_dir}:${PATH}"

  detect_firewall
  assert_eq "ufw" "$FIREWALL_KIND" "ufw detection"
  assert_eq "inactive" "$FIREWALL_STATE" "ufw inactive parsing"

  PATH=$old_path
  rm -rf -- "$stub_dir"
}

test_version
test_traffic_parser_and_steady_budget
test_myfamily_helpers
test_ipv6_validation
test_torrc_generation
test_ufw_inactive_detection

printf 'ok - function tests passed\n'

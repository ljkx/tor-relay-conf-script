# Tor Guard / Middle Relay Configuration Script

A polished interactive Bash installer for configuring a public **non-exit** Tor Guard / middle relay on a fresh Debian or Ubuntu VPS.

This repository intentionally does **not** configure an exit relay. The generated `torrc` writes `ExitRelay 0` and `SocksPort 0`, and the script never enables exit behavior.

## Read This First

Always review privileged scripts before running them on a server:

```bash
less setup-tor-guard-relay.sh
```

Then run:

```bash
sudo ./setup-tor-guard-relay.sh
```

Download and start it in one line:

```bash
curl -fsSLo setup-tor-guard-relay.sh https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh && chmod +x setup-tor-guard-relay.sh && sudo ./setup-tor-guard-relay.sh
```

With `wget` instead:

```bash
wget -O setup-tor-guard-relay.sh https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh && chmod +x setup-tor-guard-relay.sh && sudo ./setup-tor-guard-relay.sh
```

Direct one-liner, useful on fresh VPSes after you have reviewed the script:

```bash
curl -fsSL https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh | sudo bash
```

With `wget` instead:

```bash
wget -qO- https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh | sudo bash
```

Preview the flow without making system changes:

```bash
./setup-tor-guard-relay.sh --dry-run
```

Dry-run from the remote script:

```bash
curl -fsSL https://raw.githubusercontent.com/ljkx/tor-relay-conf-script/main/setup-tor-guard-relay.sh | bash -s -- --dry-run
```

Show noninteractive help:

```bash
./setup-tor-guard-relay.sh --help
```

## Supported Systems

Primary targets:

- Debian 12 `bookworm`
- Ubuntu 22.04 LTS `jammy`
- Ubuntu 24.04 LTS `noble`

Optional supported target:

- Debian 13 `trixie`

The script expects a systemd-based Debian-family VPS with `apt`, `dpkg`, and either `amd64` or `arm64`, matching the architectures currently provided by the Tor Project Debian package repository.

## What You Need To Know

The script guides you through:

- Relay nickname
- Public `ContactInfo` email or contact string
- ORPort, default `9001`
- Optional IPv6 ORPort
- Optional `RelayBandwidthRate` / `RelayBandwidthBurst`
- Optional monthly `AccountingMax`
- Automatic package updates
- Firewall rule management when a supported firewall is detected
- Basic hardening via Tor `SafeLogging 1` and optional `Sandbox 1`
- Explicit confirmation that this is **not** an exit relay

## What The Script Changes

When confirmed, the script:

- Detects Debian/Ubuntu version and CPU architecture.
- Configures the official Tor Project apt repository in `/etc/apt/sources.list.d/tor.sources`.
- Installs the Tor Project signing key at `/usr/share/keyrings/deb.torproject.org-keyring.gpg`.
- Installs `tor` and `deb.torproject.org-keyring`.
- Backs up `/etc/tor/torrc` before replacing it with a non-exit relay configuration.
- Optionally installs and configures `unattended-upgrades` for security and Tor updates.
- Optionally opens the selected ORPort using detected `ufw`, active `firewalld`, or a supported `nftables` chain.
- Enables and restarts `tor@default`.
- Verifies Tor config syntax, service status, and the ORPort listener when possible.
- Checks apt-related disk space and inode availability before package operations.

Backups are timestamped, for example:

```text
/etc/tor/torrc.bak.20260518T120000Z
```

## Generated torrc Shape

The generated configuration follows the Tor Project's Middle/Guard relay guidance:

```torrc
Nickname MyRelay
ContactInfo "operator@example.org"
ORPort 9001
ExitRelay 0
SocksPort 0
SafeLogging 1
```

Optional settings are added only when selected, such as:

```torrc
ORPort [2001:db8::1234]:9001
RelayBandwidthRate 16 MBits
RelayBandwidthBurst 32 MBits
AccountingStart month 1 00:00
AccountingMax 2000 GBytes
Sandbox 1
```

## Security Notes

- `ContactInfo` is public. Use an address or contact string you are comfortable publishing.
- This is a non-exit relay installer. It does not configure DNS resolver changes, exit policies, `IPv6Exit`, or `ExitRelay 1`.
- Keep SSH access open. The script only adds an ORPort firewall allow rule; it does not enable an inactive firewall or change default policies.
- Cloud firewalls are outside the VPS. Open the ORPort in your provider panel if required.
- Tor relay operators should keep Tor and the operating system updated.
- Leave Tor logs at notice level and keep `SafeLogging` enabled unless debugging a specific issue.
- Do not publish real-time relay/system metrics. Tor recommends aggregation windows of at least a day when publishing statistics.
- If you operate multiple relays, configure `MyFamily` manually after you know each relay fingerprint.
- After the relay is running, consider securely backing up `/var/lib/tor/keys`. Those identity keys are sensitive.
- The script collects no secrets and implements no telemetry.

## Relay Lifecycle

New relays do not receive full traffic immediately.

- Tor's post-install guidance says a new relay should appear in Relay Search after about 3 hours.
- Traffic can be low for the first few days while bandwidth authorities measure the relay.
- Guard behavior depends on stable uptime and sufficient bandwidth; it can take time to receive and fully ramp into Guard usage.

Relay Search:

```text
https://metrics.torproject.org/rs.html
```

## Troubleshooting

Check service state:

```bash
systemctl status tor@default --no-pager
```

Follow logs:

```bash
journalctl -u tor@default -f
```

Look for the expected ORPort self-test:

```bash
journalctl -u tor@default --since "1 hour ago" | grep -F "Self-testing indicates"
```

Check the listener:

```bash
ss -ltn | grep ':9001'
```

Verify the Tor config manually:

```bash
tor --verify-config -f /etc/tor/torrc
```

Common issues:

- `apt` reports `No space left on device`: the VPS filesystem or inode table is full. Check `df -h` and `df -ih`, then free space before re-running.
- Provider firewall or security group does not allow inbound TCP ORPort.
- Local firewall did not have a supported manager or ruleset.
- IPv6 was enabled without working IPv6 connectivity.
- Port is already in use.
- VPS does not have a public IPv4 address.

If an earlier package operation was interrupted by a full disk, clear the apt cache and retry after freeing space:

```bash
sudo apt clean
sudo rm -rf /var/lib/apt/lists/partial/*
sudo apt update
```

## Updating

If unattended upgrades were enabled, security and Tor package updates should be applied automatically.

Manual update:

```bash
sudo apt update
sudo apt install --only-upgrade tor deb.torproject.org-keyring
sudo systemctl restart tor@default
```

## Uninstalling

Stop and disable Tor:

```bash
sudo systemctl disable --now tor@default
```

Remove packages if you no longer want Tor installed:

```bash
sudo apt remove tor
```

Optional cleanup:

```bash
sudo rm /etc/apt/sources.list.d/tor.sources
sudo rm /usr/share/keyrings/deb.torproject.org-keyring.gpg
sudo apt update
```

Remove `/var/lib/tor` only if you intentionally want to delete relay identity keys and lose relay reputation:

```bash
sudo rm -rf /var/lib/tor
```

## Official Tor Sources

This script was built from current official Tor documentation, including:

- [Tor relay technical setup](https://community.torproject.org/relay/setup/)
- [Debian/Ubuntu Middle/Guard relay setup](https://community.torproject.org/relay/setup/guard/debian-ubuntu/)
- [Tor Debian/Ubuntu package installation](https://support.torproject.org/little-t-tor/getting-started/installing/)
- [Relay post-install and good practices](https://community.torproject.org/relay/setup/post-install/)
- [Relay requirements](https://community.torproject.org/relay/relays-requirements/)
- [Technical considerations](https://community.torproject.org/relay/technical-considerations/)
- [Bandwidth limits](https://support.torproject.org/relays/performance/bandwidth-limits/)
- [Expectations for relay operators](https://community.torproject.org/policies/relays/expectations-for-relay-operators/)
- [Lifecycle of a new relay](https://blog.torproject.org/lifecycle-of-a-new-relay/)

When in doubt, prefer Tor Project documentation over third-party guides.
